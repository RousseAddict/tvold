import AudioToolbox
import AVFoundation

// PCM -> AAC, the second half of the AC-3 transcode path.
//
// This was written as the risky component, before the rest of the pipeline, on
// the assumption that iOS 6 had no *software* AAC encoder and that a 4S would
// therefore have to share the one hardware codec with the video decoder already
// using it. **That assumption was wrong**: the device reports two encoders,
// software and hardware, and the software one works (6.9x realtime on an A5).
//
// What the probe did find is the reverse of what it was looking for: the
// *hardware* codec is the unusable one. It hangs — twice, in two different
// places, reporting no error either time. So the encoder ships software-only.
final class AACEncoder {

    // 1024 PCM frames per AAC packet, fixed by the format.
    static let framesPerPacket = 1024

    // Returned by the input callback when this call's PCM is used up but the
    // *stream* is not over. Returning noErr with zero packets is how the API is
    // told the input has ended, and the converter finalizes itself when it hears
    // that — after which every later encode() yields nothing. This encoder is
    // fed one segment at a time and has to survive the gap between them, so it
    // reports a sentinel error instead; AudioConverterFillComplexBuffer passes
    // it straight back and encode() reads it as "done for now".
    // 'nmor' is the classic kNoMoreDataError, which this SDK does not define.
    static let needMoreInput: OSStatus = 0x6E6D6F72

    private var converter: AudioConverterRef?
    private let channels: UInt32

    // Frames of encoder delay at the head of the output. An AAC encoder emits
    // packets before it has seen enough input to fill them, so the first ones
    // carry priming rather than audio; the remuxer shifts the new track back by
    // this much instead of laying priming over the video's opening frames.
    // Asked of the converter rather than inferred from the packet count — that
    // only ever gave leading and trailing padding added together (96 packets
    // where 93 were expected) with no way to separate them.
    private(set) var primeFrames = 0

    // Input is handed to the converter through a C callback, so the PCM has to
    // live at a stable address for the length of the call — a Swift Array's
    // buffer does not qualify.
    fileprivate final class Input {
        var pcm: UnsafeMutablePointer<Int16>?
        var frames = 0
        var offset = 0
        var channels: UInt32 = 2
        deinit { pcm?.deallocate() }
    }
    private let input = Input()

    // MARK: - Setup

    // Always asks for a specific codec rather than letting CoreAudio choose,
    // because CoreAudio choosing means CoreAudio possibly choosing the hardware
    // one — and on this device that hangs. Measured twice, differently each
    // time: once `AudioConverterNewSpecific` never returned, once it returned
    // and then `AudioConverterFillComplexBuffer` never returned. Neither
    // reports an error, so there is nothing to time out on or recover from.
    // `preferHardware` therefore defaults to false and exists only so the probe
    // can keep measuring the thing we refuse to ship.
    init?(sampleRate: Double, channels: UInt32, preferHardware: Bool = false) {
        self.channels = channels
        input.channels = channels

        var src = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0)

        var dst = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(AACEncoder.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0)

        var conv: AudioConverterRef?
        var status: OSStatus
        let wanted: UInt32 = preferHardware ? kAppleHardwareAudioCodecManufacturer
                                            : kAppleSoftwareAudioCodecManufacturer
        var descs = AACEncoder.encoderDescriptions()
        if let match = descs.firstIndex(where: { $0.mManufacturer == wanted }) {
            var one = descs[match]
            status = AudioConverterNewSpecific(&src, &dst, 1, &one, &conv)
        } else {
            // Deliberately no `AudioConverterNew` fallback: letting CoreAudio
            // pick is how the hardware codec gets selected, and that hangs with
            // no error and no timeout. Failing here is recoverable; hanging is
            // not.
            DebugLog.shared.log("AAC", "no \(preferHardware ? "hardware" : "software")"
                                + " AAC encoder among \(descs.count) codec(s)")
            return nil
        }
        guard status == noErr, let c = conv else {
            DebugLog.shared.log("AAC", "converter creation failed: \(AACEncoder.fourCC(status))")
            return nil
        }
        converter = c

        // Not fatal if it fails: a zero prime offset costs at most ~45ms of
        // audio arriving early, which is bad but is not a reason to refuse to
        // play the stream at all.
        var prime = AudioConverterPrimeInfo()
        var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(c, kAudioConverterPrimeInfo,
                                     &primeSize, &prime) == noErr {
            primeFrames = Int(prime.leadingFrames)
        } else {
            DebugLog.shared.log("AAC", "prime info unavailable — assuming 0")
        }
    }

    deinit {
        if let c = converter { AudioConverterDispose(c) }
    }

    // Every AAC encoder CoreAudio knows about on this device.
    static func encoderDescriptions() -> [AudioClassDescription] {
        var format = kAudioFormatMPEG4AAC
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders,
                                         UInt32(MemoryLayout.size(ofValue: format)),
                                         &format, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioClassDescription>.size
        var out = [AudioClassDescription](repeating: AudioClassDescription(), count: count)
        guard AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                                     UInt32(MemoryLayout.size(ofValue: format)),
                                     &format, &size, &out) == noErr else { return [] }
        return out
    }

    // MARK: - Encoding

    // Interleaved signed-16 PCM in, raw AAC packets out (no ADTS header — that
    // is added at mux time, where the sample rate and channel config that go in
    // its header are already at hand).
    // `trace` is set only by the probe. It drops a breadcrumb every few packets
    // so that a run which never returns still says how far it got — the first
    // probe on device wedged somewhere inside this function and the single
    // breadcrumb outside it could not narrow that down at all.
    func encode(_ pcm: [Int16], trace: String? = nil) -> [Data] {
        guard let converter = converter, !pcm.isEmpty else { return [] }

        input.pcm?.deallocate()
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: pcm.count)
        // `assign(from:)` and not `update(from:)`: the latter is the 5.8 rename
        // and does not exist in the 5.6.3 compiler this is built with.
        pcm.withUnsafeBufferPointer { buf.assign(from: $0.baseAddress!, count: pcm.count) }
        input.pcm = buf
        input.frames = pcm.count / Int(channels)
        input.offset = 0

        var out: [Data] = []
        // 768 bytes per channel is the worst case AAC will emit for one packet.
        let capacity = 768 * Int(channels)
        var scratch = [UInt8](repeating: 0, count: capacity)
        let ctx = Unmanaged.passUnretained(input).toOpaque()

        // One AAC packet per 1024 frames, so the packet count is known in
        // advance. The cap is the backstop against a converter that keeps
        // handing back packets forever; hitting it is a bug, not an end state.
        let maxIterations = input.frames / AACEncoder.framesPerPacket + 8
        var iteration = 0

        while iteration < maxIterations {
            if let trace = trace, iteration % 8 == 0 {
                CrashReport.stage("\(trace)-pkt\(iteration)")
            }
            iteration += 1
            var packets: UInt32 = 1
            var desc = AudioStreamPacketDescription()
            var filled = false
            let status: OSStatus = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: channels,
                                          mDataByteSize: UInt32(capacity),
                                          mData: raw.baseAddress))
                let s = AudioConverterFillComplexBuffer(converter, aacInputProc, ctx,
                                                        &packets, &list, &desc)
                filled = packets > 0
                if filled {
                    out.append(Data(bytes: list.mBuffers.mData!,
                                    count: Int(list.mBuffers.mDataByteSize)))
                }
                return s
            }
            // packets == 0 means the callback ran dry, which is the clean end of
            // this call's input rather than a failure. `needMoreInput` comes
            // back through the status the same way; either alongside a packet,
            // in which case that packet is the last one and is kept, or on its
            // own. Any other non-zero status is a real error and also stops.
            if !filled { break }
            if status != noErr { break }
        }
        return out
    }

    // MARK: - Probe

    // Runs on the device and reports, in order: which encoders exist, whether a
    // converter can be created, and whether it actually produces bytes and how
    // fast. Run it once idle and once with video playing — the second is the
    // answer that decides the whole AC-3 transcode approach.
    static func probe(seconds: Double = 2.0, sampleRate: Double = 48000,
                      channels: UInt32 = 2) -> String {
        CrashReport.stage("aac-probe-start")
        var out = ["AAC encoder probe", "=================", ""]

        let descs = encoderDescriptions()
        out.append("encoders visible: \(descs.count)")
        for d in descs {
            let kind: String
            switch d.mManufacturer {
            case kAppleHardwareAudioCodecManufacturer: kind = "HARDWARE"
            case kAppleSoftwareAudioCodecManufacturer: kind = "software"
            default: kind = "other"
            }
            out.append("  \(kind)  type=\(fourCC(OSStatus(bitPattern: d.mType)))"
                       + " sub=\(fourCC(OSStatus(bitPattern: d.mSubType)))")
        }
        if descs.isEmpty {
            out.append("  none — AudioFormatGetProperty returned nothing")
        }
        out.append("")
        // Logged here and not only in the final report: which encoders exist is
        // useful even when the run never reaches the end to print one.
        DebugLog.shared.logNow("AAC", out.joined(separator: "\n"))

        // The session category matters: QA1663 warns that letting the session
        // mix with other audio can take the hardware encoder away.
        // Split in two: activation measured 5.6s on device, which is slow enough
        // to be worth knowing about on its own and slow enough that lumping the
        // two calls together hides which one paid for it.
        let session = AVAudioSession.sharedInstance()
        do {
            CrashReport.stage("aac-probe-session-category")
            try session.setCategory(AVAudioSession.Category.playback)
            CrashReport.stage("aac-probe-session-active")
            let t = CFAbsoluteTimeGetCurrent()
            try session.setActive(true)
            out.append("audio session: playback, active in "
                       + String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t) + "s")
        } catch {
            out.append("audio session: FAILED \(error)")
        }
        CrashReport.stage("aac-probe-session-done")
        out.append("")

        // A 440Hz tone, not silence — an encoder handed pure zeroes can emit
        // near-empty packets and look like it worked when it did not.
        let frames = Int(seconds * sampleRate)
        var pcm = [Int16](repeating: 0, count: frames * Int(channels))
        for i in 0..<frames {
            let v = Int16(sin(Double(i) * 2.0 * Double.pi * 440.0 / sampleRate) * 8000.0)
            for c in 0..<Int(channels) { pcm[i * Int(channels) + c] = v }
        }
        out.append("input: \(seconds)s @ \(Int(sampleRate))Hz x\(channels) "
                   + "= \(pcm.count * 2) bytes PCM")
        out.append("")

        // Software FIRST. `AudioConverterNewSpecific` for the hardware codec
        // does not return on this device — it neither succeeds nor reports an
        // OSStatus, it simply blocks — so a hardware-first order guarantees the
        // software result is never reached. The software encoder is the one that
        // matters anyway: it cannot be taken away by the video decoder.
        for hardware in [false, true] {
            let label = hardware ? "hardware-preferred" : "software-preferred"
            let tag = "aac-probe-\(hardware ? "hw" : "sw")"
            // Each phase gets its own breadcrumb *and* its own log line, written
            // synchronously. A wedged run produces no report at the end, so the
            // only evidence it can leave is what it wrote on the way in.
            CrashReport.stage("\(tag)-new")
            DebugLog.shared.logNow("AAC", "\(label): creating converter")
            guard let enc = AACEncoder(sampleRate: sampleRate, channels: channels,
                                       preferHardware: hardware) else {
                out.append("\(label): converter FAILED to create")
                continue
            }
            CrashReport.stage("\(tag)-ready")
            DebugLog.shared.logNow("AAC", "\(label): converter created, encoding")
            let t0 = CFAbsoluteTimeGetCurrent()
            let packets = enc.encode(pcm, trace: tag)
            let dt = CFAbsoluteTimeGetCurrent() - t0
            CrashReport.stage("\(tag)-encoded")
            DebugLog.shared.logNow("AAC", "\(label): encode returned "
                                   + "\(packets.count) packet(s) in "
                                   + String(format: "%.2f", dt) + "s")
            let bytes = packets.reduce(0) { $0 + $1.count }
            let expected = frames / framesPerPacket
            let summary = "\(label): \(packets.count) packets (expected ~\(expected)), "
                        + "\(bytes) bytes in \(String(format: "%.2f", dt))s "
                        + "= \(String(format: "%.1f", seconds / max(dt, 0.001)))x realtime"
            out.append(summary)
            // Also logged per-flavour, so a later flavour that blocks forever
            // cannot take this one's verdict down with it.
            DebugLog.shared.logNow("AAC", summary)
            if packets.isEmpty {
                out.append("  -> NO OUTPUT. This flavour is unusable here.")
            }
        }

        out.append("")
        out.append("resident: \(DebugLog.residentMB())MB")
        CrashReport.stage("aac-probe-done")
        let text = out.joined(separator: "\n")
        DebugLog.shared.logNow("AAC", "probe:\n" + text)
        return text
    }

    static func fourCC(_ v: OSStatus) -> String {
        let n = UInt32(bitPattern: v)
        let chars = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                     UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(bytes: chars, encoding: .isoLatin1)! + "'"
        }
        return "\(v)"
    }
}

// Hands the converter the next slice of PCM. When this call's PCM runs out it
// reports `needMoreInput` rather than zero-packets-and-noErr, which would end
// the stream permanently — see the comment on that constant.
private let aacInputProc: AudioConverterComplexInputDataProc = {
    _, ioNumberDataPackets, ioData, outPacketDescription, userData in

    guard let userData = userData else {
        ioNumberDataPackets.pointee = 0
        return AACEncoder.needMoreInput
    }
    let box = Unmanaged<AACEncoder.Input>.fromOpaque(userData).takeUnretainedValue()
    let remaining = box.frames - box.offset
    guard remaining > 0, let pcm = box.pcm else {
        ioNumberDataPackets.pointee = 0
        return AACEncoder.needMoreInput
    }
    let frames = min(Int(ioNumberDataPackets.pointee), remaining)
    let channels = Int(box.channels)
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = box.channels
    ioData.pointee.mBuffers.mDataByteSize = UInt32(frames * channels * 2)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(pcm + box.offset * channels)
    ioNumberDataPackets.pointee = UInt32(frames)
    outPacketDescription?.pointee = nil
    box.offset += frames
    return noErr
}

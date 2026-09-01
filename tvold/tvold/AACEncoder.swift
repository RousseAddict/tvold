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
// Probing found the reverse of what it was looking for: the *hardware* codec is
// the unusable one. It hangs — twice, in two different places, reporting no
// error either time. So the encoder asks for the software codec by name and
// never lets CoreAudio choose. (That probe has since been deleted; the finding
// is why the code looks like this.)
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

    // Always asks for the *software* codec by name rather than letting CoreAudio
    // choose, because CoreAudio choosing means CoreAudio possibly choosing the
    // hardware one — and on this device that hangs. Measured twice, differently
    // each time: once `AudioConverterNewSpecific` never returned, once it
    // returned and then `AudioConverterFillComplexBuffer` never returned.
    // Neither reports an error, so there is nothing to time out on or recover
    // from.
    init?(sampleRate: Double, channels: UInt32) {
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
        var descs = AACEncoder.encoderDescriptions()
        let software = kAppleSoftwareAudioCodecManufacturer
        if let match = descs.firstIndex(where: { $0.mManufacturer == software }) {
            var one = descs[match]
            status = AudioConverterNewSpecific(&src, &dst, 1, &one, &conv)
        } else {
            // Deliberately no `AudioConverterNew` fallback: letting CoreAudio
            // pick is how the hardware codec gets selected, and that hangs with
            // no error and no timeout. Failing here is recoverable; hanging is
            // not.
            DebugLog.shared.log("AAC", "no software AAC encoder among \(descs.count) codec(s)")
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
    private static func encoderDescriptions() -> [AudioClassDescription] {
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
    func encode(_ pcm: [Int16]) -> [Data] {
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

    private static func fourCC(_ v: OSStatus) -> String {
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

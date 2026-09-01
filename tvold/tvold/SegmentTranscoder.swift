import Foundation

// One playing stream's AC-3 -> AAC conversion, sitting between the proxy's
// segment fetch and the client socket.
//
// The stream decides its own fate: the first segment that carries a PMT is
// inspected, and if its audio is AC-3 every segment from then on is converted.
// A stream that turns out to be AAC already pays exactly one demux and is then
// relayed byte for byte as before, which is why this can be on by default for
// the whole catalogue rather than driven off a list of known-bad channels.
//
// Decoder and encoder are kept alive across segments deliberately. AC-3 frames
// straddle segment boundaries, and a fresh AAC encoder would re-prime — 44ms of
// it — every six seconds.
final class SegmentTranscoder {

    enum Verdict: Equatable {
        case unknown       // no segment inspected yet
        case passthrough   // audio is already playable; relay untouched
        case transcode     // AC-3; convert every segment
    }

    private let lock = NSLock()
    private var _verdict: Verdict = .unknown
    private var decoder: AC3Decoder?
    private var encoder: AACEncoder?

    // Absolute position of the encoder's input and output. A segment's AAC
    // packets are numbered from the start of the *stream*, not of the segment,
    // so aligning them against the segment's own PTS needs both counts.
    private var samplesFed = 0
    private var packetsEmitted = 0
    private var converted = 0

    var verdict: Verdict {
        lock.lock(); defer { lock.unlock() }
        return _verdict
    }

    // The master playlist already declared AC-3, so there is nothing left for
    // the first segment to discover and the detour through detection is skipped.
    func declareAC3() {
        lock.lock(); defer { lock.unlock() }
        if case .unknown = _verdict {
            _verdict = .transcode
            DebugLog.shared.log("TX", "master playlist declares AC-3 — transcoding")
        }
    }

    // Decides the verdict from the opening bytes of a segment without
    // converting anything. The PMT sits within the first few KB of a segment,
    // so a prefix captured while the segment is being relayed is enough — which
    // means an unknown stream never has to be buffered just to find out that it
    // did not need to be. Silent when the prefix is too short or has no PMT in
    // it; the next segment gets another go.
    func inspect(_ prefix: Data) {
        lock.lock(); defer { lock.unlock() }
        guard case .unknown = _verdict else { return }
        let demuxer = TSDemuxer()
        _ = demuxer.demux(prefix)
        guard let audio = demuxer.streams.first(where: { $0.value.kind == .audio }) else { return }
        _verdict = SegmentTranscoder.isAC3(audio.value) ? .transcode : .passthrough
        DebugLog.shared.log("TX", String(format: "verdict from prefix: %@ (audio PID %d type=0x%02X)",
                                         "\(_verdict)", Int(audio.key),
                                         Int(audio.value.streamType)))
    }

    // Converts one segment, or hands it back unchanged when there is nothing to
    // do — including when conversion fails, since a segment that still carries
    // AC-3 plays no worse than it would have without us in the path.
    //
    // Serialized: the codec state is a single continuous stream, so two
    // segments cannot be run through it at once. This assumes the player
    // requests segments in order, which HLS clients do; the lock protects the
    // codec state either way, it cannot reorder what arrives out of order.
    func process(_ segment: Data) -> Data {
        lock.lock(); defer { lock.unlock() }

        let demuxer = TSDemuxer()
        let packets = demuxer.demux(segment)
        guard let audio = demuxer.streams.first(where: { $0.value.kind == .audio }) else {
            // No PMT in this segment, or no audio in it. Nothing to convert and
            // nothing to learn — the verdict is left alone so a later segment
            // that does carry a PMT can still decide.
            return segment
        }

        if case .unknown = _verdict {
            _verdict = SegmentTranscoder.isAC3(audio.value) ? .transcode : .passthrough
            DebugLog.shared.log("TX", String(format: "verdict: %@ (audio PID %d type=0x%02X)",
                                             "\(_verdict)", Int(audio.key),
                                             Int(audio.value.streamType)))
        }
        guard case .transcode = _verdict else { return segment }

        let t0 = CFAbsoluteTimeGetCurrent()
        guard let out = convert(segment, packets: packets, audioPID: audio.key,
                                pmtPID: demuxer.programMapPID ?? 0) else {
            // The first segment failing means the chain cannot serve this
            // stream at all. Paying for a demux, decode and encode on every
            // segment only to fail again would make playback worse than leaving
            // the stream alone, so stop trying.
            if converted == 0 {
                _verdict = .passthrough
                DebugLog.shared.log("TX", "first segment failed to convert — falling back to passthrough")
            } else {
                DebugLog.shared.log("TX", "segment failed to convert — relayed unchanged")
            }
            return segment
        }
        converted += 1
        DebugLog.shared.log("TX", "segment \(converted): \(segment.count)B -> \(out.count)B "
                            + "in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        return out
    }

    private func convert(_ segment: Data, packets: [TSDemuxer.PES],
                         audioPID: UInt16, pmtPID: UInt16) -> Data? {
        let audio = packets.filter { $0.kind == .audio }
        guard let firstPTS = audio.first(where: { $0.pts != nil })?.pts else {
            fail("no audio PES carries a PTS")
            return nil
        }

        var ac3: [UInt8] = []
        ac3.reserveCapacity(audio.reduce(0) { $0 + $1.payload.count })
        for p in audio { ac3.append(contentsOf: p.payload) }

        // ac3_fixed outputs S16P, so interleaving for the encoder is a copy
        // rather than a clamp and a scale per sample. Its decode time is within
        // noise of the float decoder's once compiled at -O.
        if decoder == nil { decoder = AC3Decoder(fixed: true) }
        guard let dec = decoder else {
            fail("AC3Decoder would not open")
            return nil
        }
        let pcm = dec.decode(ac3)
        guard !pcm.isEmpty, dec.channels > 0, dec.sampleRate > 0 else {
            fail("decode gave \(pcm.count) samples, \(dec.channels)ch @ \(dec.sampleRate)Hz "
                 + "from \(ac3.count)B AC-3")
            return nil
        }

        // Built on the first segment, once the decoder has said what the stream
        // actually is rather than what it was assumed to be.
        if encoder == nil {
            encoder = AACEncoder(sampleRate: Double(dec.sampleRate),
                                 channels: UInt32(dec.channels))
        }
        guard let enc = encoder else {
            fail("AACEncoder would not open at \(dec.sampleRate)Hz \(dec.channels)ch")
            return nil
        }
        let aac = enc.encode(pcm)
        guard !aac.isEmpty else {
            fail("encoder returned no packets for \(pcm.count / dec.channels) frames")
            return nil
        }

        // Packet 0 of this call is not sample 0 of this segment: the encoder
        // runs continuously, so its output lags its input by the priming frames
        // plus whatever it has not yet flushed. That gap is exactly the offset
        // TSRemuxer already subtracts, so it goes in through the same parameter.
        // Anchoring on each segment's own PTS means a rounding error cannot
        // accumulate over a long session.
        let carry = samplesFed - packetsEmitted * AACEncoder.framesPerPacket + enc.primeFrames
        samplesFed += pcm.count / dec.channels
        packetsEmitted += aac.count

        guard let out = TSRemuxer.remux(segment: segment, aac: aac, firstPTS: firstPTS,
                                        sampleRate: dec.sampleRate, channels: dec.channels,
                                        audioPID: audioPID, pmtPID: pmtPID,
                                        primeFrames: carry) else {
            fail("remux of \(aac.count) AAC packets failed")
            return nil
        }
        return out.data
    }

    // "segment failed to convert" on its own does not say which of four stages
    // gave up, and each has a different cause.
    private func fail(_ reason: String) {
        DebugLog.shared.log("TX", "convert failed: \(reason)")
    }

    // ATSC gives AC-3 a stream type of its own; DVB uses "private data" plus a
    // descriptor. M6 turned out to be ATSC despite being a French broadcaster,
    // so both spellings have to be accepted.
    static func isAC3(_ s: TSDemuxer.Stream) -> Bool {
        if s.streamType == 0x81 || s.streamType == 0x87 { return true }
        return s.streamType == 0x06 && (s.descriptorTag == 0x6A || s.descriptorTag == 0x7A)
    }

    // Replaces an AC-3 codec identifier in an #EXT-X-STREAM-INF CODECS list
    // with AAC-LC, since by the time the player sees a segment that is what it
    // will contain. Returns nil when the line declares no AC-3, which is the
    // case for all but a handful of streams.
    static func rewriteCodecs(_ line: String) -> String? {
        let s = line as NSString
        guard s.range(of: "CODECS=\"").location != NSNotFound else { return nil }
        var out = line
        var found = false
        for tag in ["ac-3", "ec-3"] where out.range(of: tag) != nil {
            out = out.replacingOccurrences(of: tag, with: "mp4a.40.2")
            found = true
        }
        return found ? out : nil
    }
}

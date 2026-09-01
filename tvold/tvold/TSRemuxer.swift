import Foundation

// AC-3 segment in, AAC segment out — the last stage of the transcode.
//
// Deliberately NOT a TS muxer. The video is 95% of a segment's bytes and does
// not change, so its transport packets are copied through byte for byte: their
// continuity counters, PCRs and adaptation fields are already correct and
// anything this code did to them could only make them less so. Only three
// things actually change:
//
//   - the PMT, whose audio entry becomes stream_type 0x0F (ADTS AAC)
//   - the audio PID's packets, dropped and regenerated from the encoded AAC
//   - nothing else
//
// The new audio reuses the original audio PID, so the PMT needs a new
// stream_type rather than a new stream, and the player sees one audio track
// appear where one audio track was.
enum TSRemuxer {

    struct Output {
        let data: Data
        let audioPESWritten: Int
        let audioPacketsDropped: Int   // pure encoder priming, before firstPTS
    }

    // `firstPTS` is the original audio's first PTS, in 90kHz units — the new
    // track is laid down against the video's own clock, not a fresh one.
    // `primeFrames` is the encoder's leading delay (see AACEncoder.primeFrames);
    // the first packets are priming, not audio, and are dropped rather than
    // played 40-odd milliseconds early.
    static func remux(segment: Data, aac: [Data], firstPTS: Int64,
                      sampleRate: Int, channels: Int,
                      audioPID: UInt16, pmtPID: UInt16,
                      primeFrames: Int = 0) -> Output? {
        guard !aac.isEmpty, sampleRate > 0 else { return nil }

        // PTS for every AAC frame up front. Frame i covers input frames
        // [i*1024 - primeFrames, ...), so the ones ending before zero are
        // priming and never had audio in them.
        let freqIndex = adtsFrequencyIndex(sampleRate)
        guard freqIndex >= 0 else { return nil }

        var pending: [(pts: Int64, payload: [UInt8])] = []
        pending.reserveCapacity(aac.count)
        var dropped = 0
        for (i, frame) in aac.enumerated() {
            let offset = i * AACEncoder.framesPerPacket - primeFrames
            if offset + AACEncoder.framesPerPacket <= 0 { dropped += 1; continue }
            let pts = firstPTS + Int64(offset) * 90000 / Int64(sampleRate)
            pending.append((pts, adtsFrame(frame, freqIndex: freqIndex,
                                           channels: channels)))
        }
        guard !pending.isEmpty else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(segment.count + pending.count * 400)
        var cursor = 0                 // next unwritten entry in `pending`
        var audioCC: UInt8 = 0
        var written = 0
        var bad = false

        segment.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { bad = true; return }
            let count = raw.count

            var i = 0
            while i + 188 <= count {
                guard base[i] == 0x47 else { i += 1; continue }
                let p = base + i
                i += 188

                let pid = (UInt16(p[1] & 0x1F) << 8) | UInt16(p[2])

                if pid == pmtPID {
                    if let patched = rewritePMT(p, audioPID: audioPID) {
                        out.append(contentsOf: patched)
                    } else {
                        // A PMT this code cannot parse is passed through
                        // untouched. The result is a segment whose audio is
                        // still declared AC-3, which plays no worse than the
                        // original did — unlike a PMT guessed at wrongly, which
                        // takes the video down with it.
                        out.append(contentsOf: UnsafeBufferPointer(start: p, count: 188))
                    }
                } else if pid == audioPID {
                    // Every original audio packet is dropped. On the ones that
                    // began a PES, the replacement audio due by that point in
                    // the stream is written instead, which keeps the new track
                    // interleaved roughly where the old one was. Placement does
                    // not set sync — PTS does — but audio that arrives far from
                    // its video makes the player buffer for no reason.
                    if p[1] & 0x40 != 0, let target = pesPTS(p) {
                        while cursor < pending.count && pending[cursor].pts <= target {
                            writePES(&out, pid: audioPID, cc: &audioCC,
                                     pts: pending[cursor].pts,
                                     payload: pending[cursor].payload)
                            cursor += 1
                            written += 1
                        }
                    }
                } else {
                    out.append(contentsOf: UnsafeBufferPointer(start: p, count: 188))
                }
            }
        }
        if bad { return nil }

        // Anything still queued belongs to this segment and would otherwise be
        // silently lost — the last original audio PES starts before the last
        // AAC frame's PTS.
        while cursor < pending.count {
            writePES(&out, pid: audioPID, cc: &audioCC,
                     pts: pending[cursor].pts, payload: pending[cursor].payload)
            cursor += 1
            written += 1
        }

        guard out.count % 188 == 0 else { return nil }
        return Output(data: Data(out), audioPESWritten: written,
                      audioPacketsDropped: dropped)
    }

    // MARK: - Validation

    // Cheap structural check: every 188th byte must be a sync byte. Does not
    // prove the segment decodes, only that it is still a transport stream —
    // enough to catch the packetiser mis-sizing a packet, which is the failure
    // that would otherwise surface as an unplayable stream with no explanation.
    static func validate(_ data: Data) -> String? {
        guard data.count % 188 == 0 else {
            return "length \(data.count) is not a multiple of 188"
        }
        var result: String?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let b = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { result = "unreadable"; return }
            var i = 0
            while i < raw.count {
                if b[i] != 0x47 {
                    result = "packet \(i / 188) does not start with 0x47"
                    return
                }
                i += 188
            }
        }
        return result
    }

    // MARK: - PES

    // PTS of the PES starting in this packet, or nil if it carries none.
    private static func pesPTS(_ p: UnsafePointer<UInt8>) -> Int64? {
        let adaptation = (p[3] & 0x30) >> 4
        guard adaptation == 1 || adaptation == 3 else { return nil }
        var off = 4
        if adaptation == 3 {
            off = 5 + Int(p[4])
            guard off < 188 else { return nil }
        }
        guard off + 14 <= 188,
              p[off] == 0, p[off + 1] == 0, p[off + 2] == 1,
              p[off + 7] & 0x80 != 0 else { return nil }
        let b = off + 9
        let a = Int64(p[b] & 0x0E) << 29
        let c = Int64(p[b + 1]) << 22
        let d = Int64(p[b + 2] & 0xFE) << 14
        let e = Int64(p[b + 3]) << 7
        let f = Int64(p[b + 4] & 0xFE) >> 1
        return a | c | d | e | f
    }

    // One PES packet split across as many TS packets as it needs. Audio PES are
    // small — an ADTS frame is a few hundred bytes — so there is no PCR and no
    // random-access flag here; the only adaptation field ever written is
    // stuffing to pad the final packet out to 188.
    private static func writePES(_ out: inout [UInt8], pid: UInt16, cc: inout UInt8,
                                 pts: Int64, payload: [UInt8]) {
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xC0]
        let ts = encodePTS(2, pts)
        let pesLen = 3 + ts.count + payload.count
        pes.append(UInt8((pesLen >> 8) & 0xFF))
        pes.append(UInt8(pesLen & 0xFF))
        pes.append(0x80)                     // '10', no scrambling, no priority
        pes.append(0x80)                     // PTS only
        pes.append(UInt8(ts.count))
        pes.append(contentsOf: ts)
        pes.append(contentsOf: payload)

        var off = 0
        var first = true
        while off < pes.count {
            let remaining = pes.count - off
            let pidHi = UInt8((first ? 0x40 : 0x00) | Int(pid >> 8))
            if remaining >= 184 {
                out.append(contentsOf: [0x47, pidHi, UInt8(pid & 0xFF), 0x10 | cc])
                out.append(contentsOf: pes[off ..< off + 184])
                off += 184
            } else {
                // Short tail: an adaptation field of pure stuffing makes up the
                // difference so the packet still lands on exactly 188 bytes.
                let gap = 184 - remaining
                out.append(contentsOf: [0x47, pidHi, UInt8(pid & 0xFF), 0x30 | cc])
                if gap == 1 {
                    // No room for the flags byte — a length of 0 is the legal
                    // way to spend exactly one byte.
                    out.append(0x00)
                } else {
                    out.append(UInt8(gap - 1))   // adaptation_field_length
                    out.append(0x00)             // no flags set
                    for _ in 0 ..< (gap - 2) { out.append(0xFF) }
                }
                out.append(contentsOf: pes[off...])
                off = pes.count
            }
            cc = (cc &+ 1) & 0x0F
            first = false
        }
    }

    private static func encodePTS(_ prefix: UInt8, _ ts: Int64) -> [UInt8] {
        let t = UInt64(bitPattern: ts) & 0x1_FFFF_FFFF
        return [
            UInt8(UInt64(prefix) << 4 | (t >> 30) << 1 | 1),
            UInt8((t >> 22) & 0xFF),
            UInt8(((t >> 14) & 0xFE) | 1),
            UInt8((t >> 7) & 0xFF),
            UInt8(((t << 1) & 0xFE) | 1),
        ]
    }

    // MARK: - ADTS

    static func adtsFrequencyIndex(_ rate: Int) -> Int {
        let table = [96000, 88200, 64000, 48000, 44100, 32000, 24000,
                     22050, 16000, 12000, 11025, 8000, 7350]
        return table.firstIndex(of: rate) ?? -1
    }

    private static func adtsFrame(_ frame: Data, freqIndex: Int, channels: Int) -> [UInt8] {
        let len = frame.count + 7
        var h = [UInt8](repeating: 0, count: 7)
        h[0] = 0xFF
        h[1] = 0xF1                                  // MPEG-4, layer 0, no CRC
        // Split into explicitly typed sub-expressions: the combined shift/or
        // expression makes the Swift 5.6 type-checker give up with "unable to
        // type-check in reasonable time".
        let b2: Int = (1 << 6) | ((freqIndex & 0xF) << 2) | ((channels >> 2) & 1)
        let b3: Int = ((channels & 3) << 6) | ((len >> 11) & 3)
        let b5: Int = ((len & 7) << 5) | 0x1F
        h[2] = UInt8(b2)                             // profile 1 = AAC-LC
        h[3] = UInt8(b3)
        h[4] = UInt8((len >> 3) & 0xFF)
        h[5] = UInt8(b5)
        h[6] = 0xFC
        return h + [UInt8](frame)
    }

    // MARK: - PMT

    // Returns a whole replacement 188-byte packet, or nil to pass the original
    // through unchanged.
    private static func rewritePMT(_ p: UnsafePointer<UInt8>,
                                   audioPID: UInt16) -> [UInt8]? {
        guard p[1] & 0x40 != 0 else { return nil }   // continuation, not a start
        let adaptation = (p[3] & 0x30) >> 4
        guard adaptation == 1 || adaptation == 3 else { return nil }
        var off = 4
        if adaptation == 3 {
            off = 5 + Int(p[4])
            guard off < 188 else { return nil }
        }
        let start = off + 1 + Int(p[off])            // skip pointer_field
        guard start + 12 <= 188, p[start] == 0x02 else { return nil }
        let length = (Int(p[start + 1] & 0x0F) << 8) | Int(p[start + 2])
        let end = start + 3 + length
        // Single-packet sections only, and one long enough to hold a header and
        // a CRC. A PMT spanning packets is legal but does not happen in the
        // single-program streams HLS segments are.
        guard length >= 13, end <= 188 else { return nil }

        func bytes(_ from: Int, _ n: Int) -> [UInt8] {
            [UInt8](UnsafeBufferPointer(start: p + from, count: n))
        }

        // Everything up to and including program_info_length, then the program
        // descriptors, both unchanged.
        var section = bytes(start, 12)
        let programInfoLength = (Int(p[start + 10] & 0x0F) << 8) | Int(p[start + 11])
        guard start + 12 + programInfoLength <= end - 4 else { return nil }
        section += bytes(start + 12, programInfoLength)

        var q = start + 12 + programInfoLength
        let esEnd = end - 4                          // stop before the CRC
        var sawAudio = false
        while q + 5 <= esEnd {
            let pid = (UInt16(p[q + 1] & 0x1F) << 8) | UInt16(p[q + 2])
            let esInfoLength = (Int(p[q + 3] & 0x0F) << 8) | Int(p[q + 4])
            guard q + 5 + esInfoLength <= esEnd else { return nil }
            if pid == audioPID {
                // 0x0F = ADTS AAC, and no descriptors: whatever was there
                // described AC-3 and is now a lie.
                section += [0x0F, p[q + 1], p[q + 2], 0xF0, 0x00]
                sawAudio = true
            } else {
                section += bytes(q, 5 + esInfoLength)
            }
            q += 5 + esInfoLength
        }
        guard sawAudio else { return nil }

        // section_length counts everything after itself, CRC included.
        let newLength = section.count - 3 + 4
        guard newLength <= 0x3FD else { return nil }
        section[1] = 0xB0 | UInt8((newLength >> 8) & 0x0F)
        section[2] = UInt8(newLength & 0xFF)
        let crc = mpegCRC32(section)
        section += [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
                    UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]

        // Original header and adaptation field, a zero pointer_field, the new
        // section, then 0xFF to the end of the packet.
        var packet = bytes(0, off)
        packet.append(0x00)
        packet += section
        guard packet.count <= 188 else { return nil }
        while packet.count < 188 { packet.append(0xFF) }
        return packet
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var crc = UInt32(i) << 24
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
            table[i] = crc
        }
        return table
    }()

    private static func mpegCRC32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF]
        }
        return crc
    }
}

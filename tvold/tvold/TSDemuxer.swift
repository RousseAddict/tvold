import Foundation

// MPEG-TS -> elementary streams, the first half of the AC-3 transcode path.
//
// Only what the transcode needs: find the video and audio PIDs, and hand back
// PES payloads with their timestamps. Video comes out to be written straight
// back unchanged; audio comes out to be decoded and re-encoded as AAC.
//
// Deliberately not a general demuxer. It assumes the single-program transport
// streams that HLS segments actually are, which is what lets the PSI handling
// stay this small.
final class TSDemuxer {

    static let packetSize = 188
    static let syncByte: UInt8 = 0x47

    enum Kind { case video, audio, other }

    struct Stream {
        let pid: UInt16
        let streamType: UInt8
        let kind: Kind
        // Set when the codec was identified from a PMT descriptor rather than
        // the stream type — DVB signals AC-3 as "private data" plus a tag.
        let descriptorTag: UInt8?
    }

    // One complete PES packet. `pts`/`dts` are in 90kHz units, nil when the
    // header did not carry them.
    struct PES {
        let pid: UInt16
        let kind: Kind
        let pts: Int64?
        let dts: Int64?
        let payload: [UInt8]
    }

    private(set) var streams: [UInt16: Stream] = [:]
    // The remuxer needs this: the PMT is the one table it has to rewrite, and
    // which PID carries it is only discoverable by having read the PAT.
    private(set) var programMapPID: UInt16?

    // Partial PES accumulation for one PID. A PES packet spans many TS packets
    // and ends only when the next one starts on that PID.
    //
    // A class, not a struct in a dictionary: `pending[pid]!.append(...)` on a
    // dictionary of arrays does a lookup plus a uniqueness check per TS packet,
    // and there are ~10,000 of those in a segment. Through a reference the
    // append is straightforwardly in place.
    private final class Accumulator {
        let stream: Stream
        var buf: [UInt8] = []
        // False until this PID's first payload_unit_start is seen. Payload
        // before that is the tail of a PES that began in an earlier segment and
        // cannot be decoded, so it is dropped rather than prepended to the
        // first real one.
        var started = false
        init(stream: Stream) { self.stream = stream }
    }

    // MARK: - Entry point

    // Returns PES packets in the order they completed. A segment that carries
    // no PMT yields nothing — the caller should treat that as "not a usable
    // segment" rather than "silence".
    func demux(_ data: Data) -> [PES] {
        var out: [PES] = []
        // Read straight out of the Data's own storage. The previous
        // `[UInt8](data)` copied the whole segment — ~2MB per 5s of media —
        // before looking at a single byte of it.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { return }
            scan(base, count: raw.count, into: &out)
        }
        return out
    }

    private func scan(_ bytes: UnsafePointer<UInt8>, count: Int, into out: inout [PES]) {
        var accumulators: [UInt16: Accumulator] = [:]

        var i = 0
        while i + TSDemuxer.packetSize <= count {
            guard bytes[i] == TSDemuxer.syncByte else {
                // Resynchronise rather than give up: a segment can begin mid
                // packet if the origin sliced it carelessly.
                i += 1
                continue
            }
            // Indexed in place. Slicing out a 188-byte Array per packet was the
            // single most expensive thing this loop did.
            let p = bytes + i
            i += TSDemuxer.packetSize

            // transport_error_indicator — the payload is known-corrupt.
            if p[1] & 0x80 != 0 { continue }

            let payloadStart = p[1] & 0x40 != 0
            let pid = (UInt16(p[1] & 0x1F) << 8) | UInt16(p[2])
            let adaptation = (p[3] & 0x30) >> 4

            // 0 is reserved, 2 is adaptation field only — neither carries payload.
            guard adaptation == 1 || adaptation == 3 else { continue }

            var offset = 4
            if adaptation == 3 {
                offset = 5 + Int(p[4])
                guard offset < TSDemuxer.packetSize else { continue }
            }
            let payload = UnsafeBufferPointer(start: p + offset,
                                              count: TSDemuxer.packetSize - offset)

            if pid == 0 {
                // PSI is a few dozen packets a segment against ~10,000 media
                // ones, so materialising an array here is not worth avoiding.
                parsePAT(Array(payload), payloadStart: payloadStart)
            } else if pid == programMapPID {
                parsePMT(Array(payload), payloadStart: payloadStart)
                for (spid, s) in streams where accumulators[spid] == nil {
                    accumulators[spid] = Accumulator(stream: s)
                }
            } else if let acc = accumulators[pid] {
                if payloadStart {
                    // A new PES begins, so whatever was accumulating is done.
                    if let pes = parsePES(acc.buf, stream: acc.stream) {
                        out.append(pes)
                    }
                    // Keeps the capacity: every PES on a PID is roughly the
                    // same size, so after the first one this stops reallocating.
                    acc.buf.removeAll(keepingCapacity: true)
                    acc.buf.append(contentsOf: payload)
                    acc.started = true
                } else if acc.started {
                    acc.buf.append(contentsOf: payload)
                }
            }
        }

        // Flush whatever was still accumulating at the end of the segment.
        for acc in accumulators.values {
            if let pes = parsePES(acc.buf, stream: acc.stream) { out.append(pes) }
        }
    }

    // MARK: - PSI

    // PAT and PMT are carried in "sections". Only the single-packet case is
    // handled: a transport stream with one program has a PAT of 16 bytes and a
    // PMT of a few dozen, both far inside one 184-byte payload. A section that
    // claims to be longer than the packet is skipped rather than guessed at.
    private func sectionBody(_ payload: [UInt8], payloadStart: Bool) -> [UInt8]? {
        guard payloadStart, !payload.isEmpty else { return nil }
        // pointer_field: how many bytes to skip before the section starts.
        let start = 1 + Int(payload[0])
        guard start + 3 <= payload.count else { return nil }
        let length = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let bodyStart = start + 3
        guard length >= 9, bodyStart + length <= payload.count else { return nil }
        // Trailing 4 bytes are the CRC, which is not checked — a corrupt PMT
        // shows up immediately as a stream that produces no PES packets.
        return Array(payload[bodyStart ..< bodyStart + length - 4])
    }

    private func parsePAT(_ payload: [UInt8], payloadStart: Bool) {
        guard programMapPID == nil, let body = sectionBody(payload, payloadStart: payloadStart)
        else { return }
        // Skip the 5 bytes between section_length and the program loop.
        var p = 5
        while p + 4 <= body.count {
            let programNumber = (UInt16(body[p]) << 8) | UInt16(body[p + 1])
            let pid = (UInt16(body[p + 2] & 0x1F) << 8) | UInt16(body[p + 3])
            // Program 0 is the network information table, not a program.
            if programNumber != 0 {
                programMapPID = pid
                return
            }
            p += 4
        }
    }

    private func parsePMT(_ payload: [UInt8], payloadStart: Bool) {
        guard streams.isEmpty, let body = sectionBody(payload, payloadStart: payloadStart)
        else { return }
        guard body.count >= 9 else { return }
        let programInfoLength = (Int(body[7] & 0x0F) << 8) | Int(body[8])
        var p = 9 + programInfoLength

        while p + 5 <= body.count {
            let streamType = body[p]
            let pid = (UInt16(body[p + 1] & 0x1F) << 8) | UInt16(body[p + 2])
            let esInfoLength = (Int(body[p + 3] & 0x0F) << 8) | Int(body[p + 4])
            let descStart = p + 5
            let descEnd = min(descStart + esInfoLength, body.count)

            var tag: UInt8?
            if descStart < descEnd {
                tag = findAudioDescriptor(Array(body[descStart ..< descEnd]))
            }
            let kind = TSDemuxer.classify(streamType: streamType, descriptorTag: tag)
            if kind != .other {
                streams[pid] = Stream(pid: pid, streamType: streamType,
                                      kind: kind, descriptorTag: tag)
            }
            p = descEnd
        }
    }

    // DVB does not have a stream type meaning "AC-3". It uses 0x06, "PES
    // carrying private data", and puts the actual codec in a descriptor — 0x6A
    // for AC-3, 0x7A for E-AC-3. ATSC instead defines stream types 0x81/0x87.
    // M6 is a French broadcaster, so the DVB spelling is the one that matters
    // here, but both are cheap to accept.
    private func findAudioDescriptor(_ descriptors: [UInt8]) -> UInt8? {
        var p = 0
        while p + 2 <= descriptors.count {
            let tag = descriptors[p]
            let length = Int(descriptors[p + 1])
            if tag == 0x6A || tag == 0x7A { return tag }
            p += 2 + length
        }
        return nil
    }

    static func classify(streamType: UInt8, descriptorTag: UInt8?) -> Kind {
        switch streamType {
        case 0x1B, 0x24, 0x02: return .video          // H.264, HEVC, MPEG-2
        case 0x0F, 0x11: return .audio                // AAC in ADTS / LATM
        case 0x81, 0x87: return .audio                // ATSC AC-3 / E-AC-3
        case 0x06:                                    // DVB private — ask the tag
            return (descriptorTag == 0x6A || descriptorTag == 0x7A) ? .audio : .other
        default: return .other
        }
    }

    // MARK: - PES

    private func parsePES(_ buf: [UInt8], stream: Stream) -> PES? {
        // start_code_prefix 0x000001, stream_id, then a 16-bit length.
        guard buf.count >= 9, buf[0] == 0, buf[1] == 0, buf[2] == 1 else { return nil }
        let headerDataLength = Int(buf[8])
        let payloadStart = 9 + headerDataLength
        guard payloadStart <= buf.count else { return nil }

        let flags = buf[7]
        var pts: Int64?
        var dts: Int64?
        // Top two bits: 0b10 = PTS only, 0b11 = PTS followed by DTS.
        if flags & 0x80 != 0, buf.count >= 14 {
            pts = TSDemuxer.timestamp(buf, at: 9)
            if flags & 0x40 != 0, buf.count >= 19 {
                dts = TSDemuxer.timestamp(buf, at: 14)
            }
        }
        return PES(pid: stream.pid, kind: stream.kind, pts: pts, dts: dts,
                   payload: Array(buf[payloadStart...]))
    }

    // A 33-bit value spread across 5 bytes, with a marker bit at the bottom of
    // each of the last four — hence the shifts rather than a plain big-endian
    // read.
    static func timestamp(_ b: [UInt8], at i: Int) -> Int64 {
        let a = Int64(b[i] & 0x0E) << 29
        let c = Int64(b[i + 1]) << 22
        let d = Int64(b[i + 2] & 0xFE) << 14
        let e = Int64(b[i + 3]) << 7
        let f = Int64(b[i + 4] & 0xFE) >> 1
        return a | c | d | e | f
    }
}

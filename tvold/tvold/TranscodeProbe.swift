import Foundation

// End-to-end measurement of the AC-3 transcode path against a real stream.
//
// The AAC encoder was measured on a synthetic tone; that proved the encoder
// exists and is fast, nothing more. This runs the actual chain — fetch a live
// M6 segment, demux it, decode its AC-3, re-encode to AAC — and reports the
// cost of each stage against the segment's own duration. Anything at or below
// 1x realtime for the whole chain means the transcode cannot keep up on an A5
// and the design has to change.
enum TranscodeProbe {

    // M6 is the worked example: HTTP, valid HLS, H.264 High@L4.0 well inside
    // the 4S's decoder spec, and AC-3 on every rendition with no AAC fallback.
    private static let source = "http://99.27.51.147:8080/M6/index.m3u8"

    // M6's origin refuses requests without a browser User-Agent.
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    ]

    static func run() -> String {
        CrashReport.stage("tx-probe-start")
        var out = ["AC-3 transcode probe", "====================", ""]

        // MARK: Fetch
        CrashReport.stage("tx-probe-fetch")
        guard let master = fetchText(source) else {
            return finish(out + ["FAILED: could not fetch master playlist"])
        }
        guard let variantURL = firstURI(in: master, base: source) else {
            return finish(out + ["FAILED: no variant URI in master playlist"])
        }
        guard let variant = fetchText(variantURL) else {
            return finish(out + ["FAILED: could not fetch variant playlist"])
        }
        guard let segmentURL = firstURI(in: variant, base: variantURL) else {
            return finish(out + ["FAILED: no segment URI in variant playlist"])
        }

        let duration = firstDuration(in: variant) ?? 0
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let segment = CurlFetcher.fetchSyncData(url: segmentURL,
                                                      headers: headers, timeout: 30) else {
            return finish(out + ["FAILED: could not fetch segment \(segmentURL)"])
        }
        let fetchTime = CFAbsoluteTimeGetCurrent() - t0
        out.append("segment: \(segment.count) bytes, \(fmt(duration))s declared, "
                   + "fetched in \(fmt(fetchTime))s")
        out.append("")
        DebugLog.shared.logNow("TX", out.joined(separator: "\n"))

        // MARK: Demux
        CrashReport.stage("tx-probe-demux")
        let demuxer = TSDemuxer()
        let t1 = CFAbsoluteTimeGetCurrent()
        let packets = demuxer.demux(segment)
        let demuxTime = CFAbsoluteTimeGetCurrent() - t1

        out.append("demux: \(packets.count) PES packets in \(fmt(demuxTime))s")
        for (pid, s) in demuxer.streams.sorted(by: { $0.key < $1.key }) {
            let tag = s.descriptorTag.map { String(format: " descriptor=0x%02X", $0) } ?? ""
            out.append(String(format: "  PID %d  type=0x%02X  %@%@",
                              Int(pid), Int(s.streamType), "\(s.kind)", tag))
        }
        if demuxer.streams.isEmpty {
            out.append("  no PMT found — cannot proceed")
            return finish(out)
        }

        let audio = packets.filter { $0.kind == .audio }
        let video = packets.filter { $0.kind == .video }
        let audioBytes = audio.reduce(0) { $0 + $1.payload.count }
        let videoBytes = video.reduce(0) { $0 + $1.payload.count }
        out.append("  audio: \(audio.count) PES, \(audioBytes) bytes")
        out.append("  video: \(video.count) PES, \(videoBytes) bytes")
        if let first = audio.first?.pts, let last = audio.last?.pts {
            // 90kHz clock, so a segment's worth of audio should span roughly
            // its declared duration. A wild number here means the PTS parsing
            // is wrong, which would silently wreck A/V sync later.
            out.append("  audio PTS span: \(fmt(Double(last - first) / 90000.0))s")
        }
        out.append("")
        DebugLog.shared.logNow("TX", "demux: \(packets.count) PES, "
                               + "\(audio.count) audio / \(video.count) video")
        guard !audio.isEmpty else { return finish(out + ["no audio PES — cannot decode"]) }

        // One contiguous AC-3 byte stream, which is what the parser expects.
        var ac3: [UInt8] = []
        ac3.reserveCapacity(audioBytes)
        for p in audio { ac3.append(contentsOf: p.payload) }

        // MARK: Decode — both decoders, so their cost can be compared.
        var best: (pcm: [Int16], rate: Int, channels: Int)?
        // Only the shipping decoder's time counts toward the verdict. ac3_fixed
        // measured 35% faster than the float one on device and hands back S16P,
        // which the encoder wants anyway, so that is the one being timed.
        var decodeTime = 0.0
        for fixed in [false, true] {
            let name = fixed ? "ac3_fixed" : "ac3"
            CrashReport.stage("tx-probe-decode-\(name)")
            guard let dec = AC3Decoder(fixed: fixed) else {
                out.append("decode \(name): decoder unavailable")
                continue
            }
            let t2 = CFAbsoluteTimeGetCurrent()
            let pcm = dec.decode(ac3)
            let dt = CFAbsoluteTimeGetCurrent() - t2
            let seconds = dec.channels > 0 && dec.sampleRate > 0
                ? Double(pcm.count / dec.channels) / Double(dec.sampleRate) : 0
            let line = "decode \(name): \(pcm.count) samples, \(dec.channels)ch @ "
                     + "\(dec.sampleRate)Hz = \(fmt(seconds))s audio in \(fmt(dt))s "
                     + "= \(fmt(seconds / max(dt, 0.001)))x realtime"
            out.append(line)
            DebugLog.shared.logNow("TX", line)
            if pcm.isEmpty {
                out.append("  -> NO PCM.")
            } else {
                if best == nil { best = (pcm, dec.sampleRate, dec.channels) }
                if fixed { decodeTime = dt }
            }
        }
        out.append("")

        // MARK: Encode
        guard let decoded = best else { return finish(out + ["no PCM to encode"]) }
        CrashReport.stage("tx-probe-encode")
        guard let enc = AACEncoder(sampleRate: Double(decoded.rate),
                                   channels: UInt32(decoded.channels)) else {
            return finish(out + ["encode: AAC encoder unavailable"])
        }
        let t3 = CFAbsoluteTimeGetCurrent()
        let aac = enc.encode(decoded.pcm)
        let encodeTime = CFAbsoluteTimeGetCurrent() - t3
        let aacBytes = aac.reduce(0) { $0 + $1.count }
        let audioSeconds = Double(decoded.pcm.count / max(decoded.channels, 1))
                         / Double(max(decoded.rate, 1))
        out.append("encode: \(aac.count) AAC packets, \(aacBytes) bytes in "
                   + "\(fmt(encodeTime))s = \(fmt(audioSeconds / max(encodeTime, 0.001)))x realtime")
        out.append("  encoder priming: \(enc.primeFrames) frames "
                   + "(\(fmt(Double(enc.primeFrames) / Double(decoded.rate) * 1000))ms)")
        out.append("")

        // MARK: Remux
        CrashReport.stage("tx-probe-remux")
        guard let audioPID = demuxer.streams.first(where: { $0.value.kind == .audio })?.key,
              let firstPTS = audio.first(where: { $0.pts != nil })?.pts else {
            return finish(out + ["remux: no audio PID or no audio PTS"])
        }
        let t4 = CFAbsoluteTimeGetCurrent()
        let remuxed = TSRemuxer.remux(segment: segment, aac: aac, firstPTS: firstPTS,
                                      sampleRate: decoded.rate, channels: decoded.channels,
                                      audioPID: audioPID, pmtPID: demuxer.programMapPID ?? 0,
                                      primeFrames: enc.primeFrames)
        let remuxTime = CFAbsoluteTimeGetCurrent() - t4
        guard let result = remuxed else {
            return finish(out + ["remux: FAILED — returned nil"])
        }
        out.append("remux: \(result.data.count) bytes "
                   + "(\(segment.count) in, \(result.data.count - segment.count) delta) "
                   + "in \(fmt(remuxTime))s")
        out.append("  \(result.audioPESWritten) audio PES written, "
                   + "\(result.audioPacketsDropped) priming packets dropped")
        if let problem = TSRemuxer.validate(result.data) {
            out.append("  INVALID: \(problem)")
        } else {
            out.append("  structurally valid: \(result.data.count / 188) TS packets")
        }
        // Re-demux the output with a fresh demuxer. If the PMT rewrite worked
        // the audio PID now reads as stream type 0x0F, and if the packetiser
        // worked its PES packets parse — which is a far stronger statement than
        // a sync-byte check, and the closest thing to "will it play" available
        // without a player.
        let check = TSDemuxer()
        let rt = CFAbsoluteTimeGetCurrent()
        let repacked = check.demux(result.data)
        out.append("  re-demux in \(fmt(CFAbsoluteTimeGetCurrent() - rt))s: "
                   + "\(repacked.count) PES")
        for (pid, s) in check.streams.sorted(by: { $0.key < $1.key }) {
            out.append(String(format: "    PID %d  type=0x%02X  %@",
                              Int(pid), Int(s.streamType), "\(s.kind)"))
        }
        let newAudio = repacked.filter { $0.kind == .audio }
        let newVideo = repacked.filter { $0.kind == .video }
        out.append("    audio: \(newAudio.count) PES, "
                   + "\(newAudio.reduce(0) { $0 + $1.payload.count }) bytes")
        out.append("    video: \(newVideo.count) PES, "
                   + "\(newVideo.reduce(0) { $0 + $1.payload.count }) bytes "
                   + "(was \(video.count) / \(videoBytes) — must match)")
        if let a = newAudio.first?.payload, a.count >= 2 {
            // Every ADTS frame starts 0xFF Fx. If the PES payload does not, the
            // player will not find a frame to decode.
            let syncOK = a[0] == 0xFF && (a[1] & 0xF0) == 0xF0
            out.append("    first audio payload: "
                       + String(format: "%02X %02X", Int(a[0]), Int(a[1]))
                       + (syncOK ? " — ADTS sync OK" : " — NOT an ADTS syncword"))
        }
        out.append("")

        // MARK: Verdict
        // Fetch is excluded: it overlaps with playback in the real pipeline and
        // is bounded by the network, not the CPU this probe is measuring.
        //
        // The float decoder's time is excluded too — it is measured for
        // comparison only and will not be in the shipping path. Everything the
        // shipping path *will* do is counted, because a verdict that leaves out
        // a stage it depends on is worse than no verdict: the first version of
        // this line omitted decode entirely and reported 5.41x for what was
        // really 4.03x.
        let cpu = demuxTime + decodeTime + encodeTime + remuxTime
        let wall = duration > 0 ? duration : audioSeconds
        out.append("CPU total (demux + ac3_fixed decode + encode + remux): "
                   + "\(fmt(cpu))s for \(fmt(wall))s of media")
        out.append("  demux \(fmt(demuxTime))s / decode \(fmt(decodeTime))s "
                   + "/ encode \(fmt(encodeTime))s / remux \(fmt(remuxTime))s")
        if wall > 0 {
            out.append("headroom: \(fmt(wall / max(cpu, 0.001)))x realtime")
        }
        out.append("resident: \(DebugLog.residentMB())MB")
        return finish(out)
    }

    // MARK: - Helpers

    private static func finish(_ lines: [String]) -> String {
        CrashReport.stage("tx-probe-done")
        let text = lines.joined(separator: "\n")
        DebugLog.shared.logNow("TX", "probe:\n" + text)
        return text
    }

    private static func fetchText(_ url: String) -> String? {
        guard let d = CurlFetcher.fetchSyncData(url: url, headers: headers, timeout: 20)
        else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // First non-comment line, resolved against the playlist it came from.
    private static func firstURI(in playlist: String, base: String) -> String? {
        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return URL(string: line, relativeTo: URL(string: base))?.absoluteString
        }
        return nil
    }

    private static func firstDuration(in playlist: String) -> Double? {
        for raw in playlist.components(separatedBy: .newlines) {
            guard raw.hasPrefix("#EXTINF:") else { continue }
            let value = raw.dropFirst("#EXTINF:".count)
                           .components(separatedBy: ",").first ?? ""
            if let d = Double(value.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

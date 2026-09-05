import Foundation

// Streams an extended M3U playlist, handing back one entry at a time.
//
// Same problem and same shape as JSONArrayStream: a provider playlist runs to
// tens of thousands of entries and tens of megabytes, and reading one whole —
// String(contentsOfFile:) then components(separatedBy:) — builds a graph
// several times the file size on a device with roughly a 40 MB budget before
// jetsam. So: read in fixed chunks, accumulate a single line, and emit an
// entry when its URL line arrives. Peak is then governed by the longest line
// rather than by the size of the file.
//
// Everything below the line level works on bytes. Strings are built only for
// the four or five field values actually kept, never for the line itself:
// Swift's Character iteration is grapheme-cluster based and is exactly what
// made LocalStreamProxy.rewritePlaylist cost 21 ms a line on an A5.
//
// Deliberately free of app dependencies so it can be compiled and verified
// standalone against real provider playlists. See tools/m3u_test.swift.
enum M3UParser {

    struct Entry {
        var name = ""
        var url = ""
        var quality = ""
        var group = ""
        var logo = ""
        var userAgent = ""
        var referrer = ""
    }

    struct Stats {
        // URL lines seen, whether or not they survived the filters.
        var urls = 0
        var kept = 0
        // Dropped because iOS 6 cannot play the transport, whatever the proxy
        // does — the same rule IndexBuilder applies to the catalogue.
        var droppedScheme = 0
        // A line longer than maxLineBytes, discarded rather than accumulated.
        // Untrusted input from a URL: without this, a file containing no
        // newline at all would be read entirely into the line buffer.
        var droppedLong = 0
    }

    enum Failure: Error, CustomStringConvertible {
        case cannotOpen
        case notAPlaylist
        case cancelled

        var description: String {
            switch self {
            case .cannotOpen: return "Could not open the playlist file"
            case .notAPlaylist: return "That URL did not return an M3U playlist"
            case .cancelled: return "Cancelled"
            }
        }
    }

    // `isCancelled` is consulted once per chunk rather than per entry: a 50k
    // list takes long enough on an A5 that a cancel has to land inside the
    // parse, and 64 KB is fine-grained enough to feel immediate without
    // costing a closure call per line.
    @discardableResult
    static func forEachEntry(inFileAt path: String,
                             chunkSize: Int = 64 * 1024,
                             maxLineBytes: Int = 64 * 1024,
                             isCancelled: () -> Bool = { false },
                             body: (Entry) -> Void) throws -> Stats {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw Failure.cannotOpen }
        defer { close(fd) }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buf.deallocate() }

        var line = [UInt8]()
        line.reserveCapacity(1024)
        var overlong = false
        var atFileStart = true
        var checkedHeader = false

        var stats = Stats()
        // Attributes seen since the last URL line. Carried across lines because
        // #EXTINF, #EXTGRP and #EXTVLCOPT all describe the entry that the next
        // URL line completes.
        var pending = Entry()

        let lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")

        func flushLine() throws {
            defer {
                line.removeAll(keepingCapacity: true)
                overlong = false
            }
            if overlong {
                stats.droppedLong += 1
                return
            }
            // A UTF-8 BOM would otherwise be glued to the leading '#' and stop
            // the header from matching.
            if atFileStart {
                atFileStart = false
                if line.count >= 3 && line[0] == 0xEF && line[1] == 0xBB && line[2] == 0xBF {
                    line.removeFirst(3)
                }
            }
            trim(&line)
            guard !line.isEmpty else { return }

            if !checkedHeader {
                checkedHeader = true
                // Cheap guard against a provider answering with an HTML error
                // page or a login form, which would otherwise parse to zero
                // entries and be reported as an empty playlist.
                guard hasPrefix(line, "#EXTM3U") || hasPrefix(line, "#EXT")
                        || isHTTP(line) else {
                    throw Failure.notAPlaylist
                }
            }

            if line[0] == UInt8(ascii: "#") {
                if hasPrefix(line, "#EXTINF:") {
                    // Anything left over from a previous #EXTINF that never got
                    // a URL line belongs to nothing.
                    pending = Entry()
                    parseExtInf(line, into: &pending)
                } else if hasPrefix(line, "#EXTGRP:") {
                    // The older way of saying group-title. Never overrides it.
                    if pending.group.isEmpty {
                        pending.group = decode(line, "#EXTGRP:".utf8.count..<line.count)
                    }
                } else if hasPrefix(line, "#EXTVLCOPT:") {
                    parseVLCOpt(line, into: &pending)
                }
                return
            }

            stats.urls += 1
            let url = decode(line, 0..<line.count)
            guard playable(url) else {
                stats.droppedScheme += 1
                pending = Entry()
                return
            }
            var e = pending
            pending = Entry()
            e.url = url
            if e.name.isEmpty { e.name = "Unknown" }
            e.quality = quality(of: e.name)
            stats.kept += 1
            // Drained per entry for the same reason JSONArrayStream drains per
            // object: the decoded values are autoreleased bridges, and without
            // a pool inside the loop every one of them stays alive until the
            // whole file has been read.
            autoreleasepool { body(e) }
        }

        while true {
            if isCancelled() { throw Failure.cancelled }
            let n = read(fd, buf, chunkSize)
            if n <= 0 { break }
            var i = 0
            while i < n {
                let b = buf[i]
                i += 1
                if b == lf {
                    try flushLine()
                } else if b == cr {
                    continue
                } else if line.count >= maxLineBytes {
                    overlong = true
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(b)
                }
            }
        }
        // A last line with no trailing newline is still an entry.
        try flushLine()

        guard checkedHeader else { throw Failure.notAPlaylist }
        return stats
    }

    // MARK: - Line parsing

    // #EXTINF:-1 tvg-id="x" tvg-name="Y" tvg-logo="Z" group-title="G",Display Name
    //
    // The display name is what every other player shows, so it wins over
    // tvg-name; provider lists routinely put an id-like string in tvg-name.
    private static func parseExtInf(_ buf: [UInt8], into e: inout Entry) {
        let start = "#EXTINF:".utf8.count
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ",")
        var inQuote = false
        var cut = buf.count
        var i = start
        while i < buf.count {
            let b = buf[i]
            if b == quote { inQuote = !inQuote }
            else if b == comma && !inQuote { cut = i; break }
            i += 1
        }
        parseAttrs(buf, start..<cut, into: &e)
        if cut < buf.count {
            let title = decode(buf, (cut + 1)..<buf.count)
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { e.name = title }
        }
    }

    // One pass over the attribute region, switching on each key as it is found,
    // rather than a scan per attribute.
    private static func parseAttrs(_ buf: [UInt8], _ region: Range<Int>, into e: inout Entry) {
        let quote = UInt8(ascii: "\""), eq = UInt8(ascii: "=")
        var i = region.lowerBound
        let end = region.upperBound
        while i < end {
            guard buf[i] == eq, i + 1 < end, buf[i + 1] == quote else {
                i += 1
                continue
            }
            var ks = i
            while ks > region.lowerBound && isKeyByte(buf[ks - 1]) { ks -= 1 }
            let key = ks..<i
            var ve = i + 2
            while ve < end && buf[ve] != quote { ve += 1 }
            let value = (i + 2)..<ve
            if matches(buf, key, "tvg-name") {
                if e.name.isEmpty { e.name = decode(buf, value) }
            } else if matches(buf, key, "tvg-logo") {
                e.logo = decode(buf, value)
            } else if matches(buf, key, "group-title") {
                e.group = decode(buf, value)
            } else if matches(buf, key, "http-user-agent") {
                e.userAgent = decode(buf, value)
            } else if matches(buf, key, "http-referrer") || matches(buf, key, "http-referer") {
                // iptv-org's own index.m3u carries these as #EXTINF attributes
                // as well as repeating them in #EXTVLCOPT, and plenty of
                // provider lists give only one of the two. Both spellings of
                // referrer are in the wild; the header itself is "Referer".
                e.referrer = decode(buf, value)
            }
            i = ve < end ? ve + 1 : end
        }
    }

    // #EXTVLCOPT:http-user-agent=Mozilla/5.0
    //
    // These two are the whole reason the option is worth reading: they are how
    // a playlist carries the headers that stop an origin returning 403, and
    // they map straight onto Channel.userAgent / .referrer, which the proxy
    // injects upstream.
    private static func parseVLCOpt(_ buf: [UInt8], into e: inout Entry) {
        let start = "#EXTVLCOPT:".utf8.count
        let eq = UInt8(ascii: "=")
        var i = start
        while i < buf.count && buf[i] != eq { i += 1 }
        guard i < buf.count else { return }
        let key = start..<i
        var value = decode(buf, (i + 1)..<buf.count)
            .trimmingCharacters(in: .whitespaces)
        if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return }
        if matches(buf, key, "http-user-agent") { e.userAgent = value }
        else if matches(buf, key, "http-referrer") || matches(buf, key, "http-referer") {
            e.referrer = value
        }
    }

    // MARK: - Filters

    // The rule IndexBuilder applies to the catalogue, restated here rather than
    // shared: this file has to compile on its own, away from the app.
    //
    // An allow-list rather than IndexBuilder's deny-list, because everything
    // here goes through LocalStreamProxy, which speaks HTTP and nothing else —
    // srt/rtmp/rtsp/mmsh fall out of that on their own, along with the file://
    // and plugin:// entries provider lists sometimes carry.
    private static func playable(_ url: String) -> Bool {
        guard let c = url.range(of: "://") else { return false }
        let scheme = String(url[url.startIndex..<c.lowerBound]).lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        return pathExtension(url) != "mpd"
    }

    private static func pathExtension(_ u: String) -> String {
        var s = u
        if let q = s.range(of: "?") { s = String(s[s.startIndex..<q.lowerBound]) }
        if let h = s.range(of: "#") { s = String(s[s.startIndex..<h.lowerBound]) }
        if let c = s.range(of: "://") {
            let rest = s[c.upperBound...]
            guard let slash = rest.range(of: "/") else { return "" }
            s = String(rest[slash.lowerBound...])
        }
        guard let dot = s.range(of: ".", options: .backwards) else { return "" }
        return String(s[dot.upperBound...]).lowercased()
    }

    // M3U has no quality field, but almost every provider puts it in the name.
    // Matched on whole tokens: a substring test finds "HD" inside "CHD" and
    // "SD" inside "SDF", and the grid would then be captioned wrongly for a
    // large slice of the list.
    private static func quality(of name: String) -> String {
        var token = ""
        var found = ""
        func consider(_ t: String) {
            guard !t.isEmpty, found.isEmpty else { return }
            switch t {
            case "UHD", "4K", "2160P", "2160": found = "2160p"
            case "FHD", "1080P", "1080": found = "1080p"
            case "HD", "720P", "720": found = "720p"
            case "SD", "480P", "480": found = "480p"
            default: break
            }
        }
        for ch in name.uppercased().unicodeScalars {
            if (ch.value >= 48 && ch.value <= 57) || (ch.value >= 65 && ch.value <= 90) {
                token.unicodeScalars.append(ch)
            } else {
                consider(token)
                token = ""
            }
        }
        consider(token)
        return found
    }

    // MARK: - Bytes

    private static func isKeyByte(_ b: UInt8) -> Bool {
        return (b >= 97 && b <= 122) || (b >= 65 && b <= 90)
            || (b >= 48 && b <= 57) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    private static func lower(_ b: UInt8) -> UInt8 {
        return (b >= 65 && b <= 90) ? b + 32 : b
    }

    private static func hasPrefix(_ buf: [UInt8], _ ascii: String) -> Bool {
        let p = Array(ascii.utf8)
        guard buf.count >= p.count else { return false }
        for i in 0..<p.count where lower(buf[i]) != lower(p[i]) { return false }
        return true
    }

    private static func matches(_ buf: [UInt8], _ range: Range<Int>, _ ascii: String) -> Bool {
        let p = Array(ascii.utf8)
        guard range.count == p.count else { return false }
        for i in 0..<p.count where lower(buf[range.lowerBound + i]) != lower(p[i]) {
            return false
        }
        return true
    }

    private static func isHTTP(_ buf: [UInt8]) -> Bool {
        return hasPrefix(buf, "http://") || hasPrefix(buf, "https://")
    }

    private static func trim(_ buf: inout [UInt8]) {
        while let last = buf.last, last == 0x20 || last == 0x09 { buf.removeLast() }
        var lead = 0
        while lead < buf.count && (buf[lead] == 0x20 || buf[lead] == 0x09) { lead += 1 }
        if lead > 0 { buf.removeFirst(lead) }
    }

    // Latin-1 as the fallback: plenty of provider lists are not UTF-8, and
    // returning nil there would silently drop whole entries rather than
    // mangling an accent.
    private static func decode(_ buf: [UInt8], _ range: Range<Int>) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        let slice = Array(buf[range])
        if let s = String(bytes: slice, encoding: .utf8) { return s }
        return String(bytes: slice, encoding: .isoLatin1) ?? ""
    }
}

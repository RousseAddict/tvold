import Foundation

// Turns a downloaded M3U into a playlist directory: one <slug>.json per group
// plus a groups.json manifest, in exactly the shape ChannelIndex uses for a
// country.
//
// The IndexBuilder of this feature, and split out for the same reason: kept
// free of UIKit and of the download machinery so it can be compiled and
// verified standalone against real provider playlists — see tools/m3u_test.swift,
// which builds this exact file rather than a copy of its algorithm.
//
// Where it has to differ from IndexBuilder is memory. IndexBuilder buckets the
// whole catalogue in a dictionary and writes at the end, peaking at 19 MB for
// ~17k entries. Provider playlists reach 50k and would not fit, so entries are
// appended to their group file as they are parsed and only a small shared
// buffer is held. Peak is then flat in the length of the playlist.
enum PlaylistBuilder {

    // Flushed whenever the buffered JSON passes this. Small next to the ~40 MB
    // budget, and large enough that a group file is written in a handful of
    // appends rather than once per entry.
    static let flushBytes = 512 * 1024

    struct Result {
        let channels: Int
        let groups: Int
        // Entries the parser refused: a transport iOS 6 cannot play, or a line
        // too long to be one. Reported rather than swallowed.
        let dropped: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case writeFailed
        case empty

        var description: String {
            switch self {
            case .writeFailed: return "Could not write the playlist to disk"
            case .empty: return "That playlist held no playable streams"
            }
        }
    }

    static func build(m3uPath: String, outDir: String,
                      isCancelled: () -> Bool = { false },
                      note: (Int) -> Void = { _ in }) throws -> Result {
        // Group identity is the order of first appearance, so a file is named
        // "g12" and never anything derived from group-title. That string comes
        // from a remote server and would otherwise be part of a path.
        var slugByGroup = [String: String]()
        var order: [(slug: String, name: String)] = []
        var counts = [String: Int]()
        var buffers = [String: [UInt8]]()
        var opened = Set<String>()
        var buffered = 0
        var total = 0
        // The parser's body closure cannot throw, so a failed write is recorded
        // and raised once the parse is over rather than aborting mid-file.
        var writeFailed = false

        func flush() {
            for (slug, bytes) in buffers where !bytes.isEmpty {
                var out = bytes
                if !opened.contains(slug) {
                    opened.insert(slug)
                    out.insert(UInt8(ascii: "["), at: 0)
                }
                if !append(out, to: outDir + "/\(slug).json") { writeFailed = true }
            }
            buffers.removeAll(keepingCapacity: true)
            buffered = 0
        }

        let stats = try M3UParser.forEachEntry(
            inFileAt: m3uPath,
            isCancelled: isCancelled,
            body: { e in
                // The short keys are the catalogue's, so a group file parses
                // with Channel(json:) exactly as a country file does.
                var d: [String: Any] = ["n": e.name, "u": e.url, "q": e.quality, "g": []]
                if !e.logo.isEmpty { d["l"] = e.logo }
                if !e.userAgent.isEmpty { d["ua"] = e.userAgent }
                if !e.referrer.isEmpty { d["rf"] = e.referrer }
                // The group is registered only once this has succeeded, so a
                // group that ends up with no entries never reaches the manifest.
                guard let data = try? JSONSerialization.data(withJSONObject: d, options: [])
                else { return }

                let group = e.group.isEmpty ? "Ungrouped" : e.group
                let slug: String
                if let s = slugByGroup[group] {
                    slug = s
                } else {
                    slug = "g\(order.count)"
                    slugByGroup[group] = slug
                    order.append((slug: slug, name: group))
                }

                var chunk = [UInt8]()
                chunk.reserveCapacity(data.count + 1)
                if counts[slug] != nil { chunk.append(UInt8(ascii: ",")) }
                chunk.append(contentsOf: data)
                buffers[slug, default: []].append(contentsOf: chunk)
                buffered += chunk.count
                counts[slug, default: 0] += 1
                total += 1

                if buffered >= flushBytes { flush() }
                if total % 2000 == 0 { note(total) }
            })

        flush()
        // Close every array, including groups small enough that their only
        // flush was the one above.
        for entry in order {
            if !append([UInt8(ascii: "]")], to: outDir + "/\(entry.slug).json") {
                writeFailed = true
            }
        }
        guard !writeFailed else { throw Failure.writeFailed }
        guard total > 0 else { throw Failure.empty }

        // Biggest group first, as the country manifest is ordered, with ties
        // broken on the name so the order is stable across re-imports — Swift's
        // sort is not.
        var manifest = order.map { e -> [String: Any] in
            return ["c": e.slug, "n": e.name, "k": counts[e.slug] ?? 0]
        }
        manifest.sort {
            let ak = $0["k"] as! Int, bk = $1["k"] as! Int
            if ak != bk { return ak > bk }
            return ($0["n"] as! String) < ($1["n"] as! String)
        }
        // Written last: PlaylistStore treats the presence of this file as the
        // signal that the playlist is complete.
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        guard writeFile(data, to: outDir + "/groups.json") else { throw Failure.writeFailed }

        return Result(channels: total, groups: order.count,
                      dropped: stats.droppedScheme + stats.droppedLong)
    }

    // MARK: - POSIX I/O
    //
    // Not FileHandle or Data.write(to:) — the Foundation file APIs kill the
    // process on the shipped 5.1.5 runtime.

    private static func append(_ bytes: [UInt8], to path: String) -> Bool {
        return withFD(path, O_WRONLY | O_CREAT | O_APPEND) { fd in
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBufferPointer { buf -> Int in
                    return write(fd, buf.baseAddress! + sent, bytes.count - sent)
                }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func writeFile(_ data: Data, to path: String) -> Bool {
        return withFD(path, O_WRONLY | O_CREAT | O_TRUNC) { fd in
            let written = data.withUnsafeBytes { raw in
                Foundation.write(fd, raw.baseAddress, raw.count)
            }
            return written == data.count
        }
    }

    private static func withFD(_ path: String, _ flags: Int32,
                               _ body: (Int32) -> Bool) -> Bool {
        let fd = open(path, flags, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return body(fd)
    }
}

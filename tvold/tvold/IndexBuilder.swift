import Foundation

// Turns the four raw iptv-org API files into the per-country index the app
// reads: one <cc>.json per country plus a countries.json manifest.
//
// The same job tools/build_index.py does on a desktop, and it must produce the
// same bytes — the bundled index and a refreshed one have to be
// interchangeable. Verified equivalent against the Python on all 179 files.
//
// Memory is the whole difficulty. The inputs are 20.7 MB and channels.json
// alone is 10.1 MB, against roughly a 40 MB budget before jetsam on an A5.
// Nothing here reads a whole file: everything goes through JSONArrayStream one
// object at a time. Measured peak for the entire rebuild is 19 MB.
//
// Kept free of UIKit and of the download machinery so it can be compiled and
// verified standalone against the real catalogue — see tools/json_stream_test.swift,
// which builds this exact file rather than a copy of its algorithm.
enum IndexBuilder {

    enum Failure: Error, CustomStringConvertible {
        case cancelled
        case noStreams

        var description: String {
            switch self {
            case .cancelled: return "Cancelled"
            case .noStreams: return "The downloaded catalogue held no usable streams"
            }
        }
    }

    // iOS 6 plays neither DASH nor these transports, whatever the proxy does.
    private static let badSchemes: Set<String> = ["srt", "rtmp", "rtsp", "mmsh"]
    private static let badExts: Set<String> = ["mpd"]
    // UIImage decodes these; the catalogue also carries .svg and .webp, which
    // it does not, and which would be a wasted fetch per cell.
    private static let logoExts: Set<String> = ["png", "jpg", "jpeg", "gif"]
    private static let unknown = "zz"

    private struct Meta {
        let name: String
        let cc: String
        let cats: [String]
    }

    static func build(dataDir: String, outDir: String,
                      isCancelled: () -> Bool,
                      note: (String) -> Void) throws -> (channels: Int, countries: Int) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: outDir)
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        func checkpoint(_ msg: String) throws {
            if isCancelled() { throw Failure.cancelled }
            DebugLog.shared.log("Refresh", "\(msg) — \(DebugLog.residentMB())MB resident")
            note(msg)
        }

        // Pass 0: which channels any playable stream actually refers to.
        //
        // Only about 10k of the catalogue's 40k channels are reachable from a
        // stream, so knowing the set first lets the next two passes discard
        // three quarters of what they read instead of retaining it. Worth a
        // second read of streams.json — it is the smallest of the three, and
        // this alone takes the rebuild from 35 MB peak to 22 MB.
        try checkpoint("Reading streams\u{2026}")
        var needed = Set<String>()
        try JSONArrayStream.forEachObject(inFileAt: dataDir + "/streams.json") { s in
            guard let url = s["url"] as? String, let cid = s["channel"] as? String,
                  playable(url) else { return }
            needed.insert(cid)
        }
        guard !needed.isEmpty else { throw Failure.noStreams }

        // Pass 1: logos. First usable one per channel wins.
        try checkpoint("Reading logos\u{2026}")
        var logos = [String: String]()
        try JSONArrayStream.forEachObject(inFileAt: dataDir + "/logos.json") { o in
            guard let cid = o["channel"] as? String, let url = o["url"] as? String,
                  needed.contains(cid), logos[cid] == nil,
                  logoExts.contains(pathExtension(url)) else { return }
            logos[cid] = url
        }

        // Pass 2: channel metadata.
        try checkpoint("Reading channels\u{2026}")
        var meta = [String: Meta]()
        try JSONArrayStream.forEachObject(inFileAt: dataDir + "/channels.json") { o in
            guard let id = o["id"] as? String, needed.contains(id) else { return }
            meta[id] = Meta(name: (o["name"] as? String) ?? "",
                            cc: ((o["country"] as? String) ?? "").lowercased(),
                            cats: (o["categories"] as? [String]) ?? [])
        }
        needed.removeAll()

        var countryNames = [String: String]()
        try JSONArrayStream.forEachObject(inFileAt: dataDir + "/countries.json") { o in
            guard let code = o["code"] as? String, let name = o["name"] as? String else { return }
            countryNames[code.lowercased()] = name
        }

        // Pass 3: join the streams onto that and bucket them by country.
        try checkpoint("Building index\u{2026}")
        var byCountry = [String: [[String: Any]]]()
        var total = 0
        try JSONArrayStream.forEachObject(inFileAt: dataDir + "/streams.json") { s in
            guard let url = s["url"] as? String, playable(url) else { return }
            let cid = s["channel"] as? String
            let m = cid.flatMap { meta[$0] }

            var name = m?.name ?? ""
            if name.isEmpty { name = (s["title"] as? String) ?? "" }
            if name.isEmpty { name = "Unknown" }

            var e: [String: Any] = ["n": name, "u": url,
                                    "q": (s["quality"] as? String) ?? "",
                                    "g": m?.cats ?? []]
            if let c = cid, let l = logos[c] { e["l"] = l }
            // The proxy injects these upstream; the player never sees them.
            if let ua = s["user_agent"] as? String, !ua.isEmpty { e["ua"] = ua }
            if let rf = s["referrer"] as? String, !rf.isEmpty { e["rf"] = rf }

            let cc = (m?.cc.isEmpty == false) ? m!.cc : unknown
            byCountry[cc, default: []].append(e)
            total += 1
        }
        guard total > 0 else { throw Failure.noStreams }
        meta.removeAll()
        logos.removeAll()

        try checkpoint("Writing \(byCountry.count) countries\u{2026}")
        var manifest = [[String: Any]]()
        for cc in byCountry.keys {
            if isCancelled() { throw Failure.cancelled }
            // Taken out of the table rather than read from it: once a country
            // is on disk its entries are dead weight, and holding all of them
            // through the sorted copy below is the peak of the whole rebuild.
            let items = byCountry.removeValue(forKey: cc)!
            try autoreleasepool { () throws -> Void in
                let sorted = items.sorted {
                    (($0["n"] as! String).lowercased()) < (($1["n"] as! String).lowercased())
                }
                let data = try JSONSerialization.data(withJSONObject: sorted, options: [])
                try write(data, to: outDir + "/\(cc).json")
            }
            manifest.append(["c": cc,
                             "n": cc == unknown ? "Other" : (countryNames[cc] ?? cc.uppercased()),
                             "k": items.count])
        }

        manifest.sort {
            let ac = $0["c"] as! String, bc = $1["c"] as! String
            let az = ac == unknown, bz = bc == unknown
            if az != bz { return !az }
            let ak = $0["k"] as! Int, bk = $1["k"] as! Int
            if ak != bk { return ak > bk }
            // Ties break on the code because Swift's sort is not stable, and
            // without this two countries with equal counts would land in a
            // different order here than in the bundled index — a refresh would
            // reshuffle the list for no reason. build_index.py matches.
            return ac < bc
        }
        // Written last: ChannelIndex treats the presence of this file as the
        // signal that a refreshed index exists and is complete.
        try write(try JSONSerialization.data(withJSONObject: manifest, options: []),
                  to: outDir + "/countries.json")

        return (channels: total, countries: manifest.count)
    }

    // MARK: - Helpers

    private static func playable(_ url: String) -> Bool {
        return !badSchemes.contains(scheme(of: url)) && !badExts.contains(pathExtension(url))
    }

    private static func scheme(of u: String) -> String {
        guard let c = u.range(of: "://") else { return "" }
        return String(u[u.startIndex..<c.lowerBound]).lowercased()
    }

    // The extension of the URL's path only. Query and fragment are cut first so
    // a `?fmt=x.mpd` style parameter cannot be mistaken for the real extension.
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

    // POSIX, not Data.write(to:) — the Foundation overlay's file write kills
    // the process on the shipped 5.1.5 runtime.
    private static func write(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { raw in
            Foundation.write(fd, raw.baseAddress, raw.count)
        }
        guard written == data.count else { throw POSIXError(.ENOSPC) }
    }
}

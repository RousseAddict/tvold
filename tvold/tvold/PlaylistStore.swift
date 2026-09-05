import Foundation

// User-supplied playlists, stored as mini-indexes with the same shape as the
// catalogue:
//
//   Documents/playlists/playlists.json     [{i,n,u,k,g,d}]  the list itself
//   Documents/playlists/<id>/groups.json   [{c,n,k}]        same shape as countries.json
//   Documents/playlists/<id>/<c>.json      [{n,u,q,g,l,ua,rf}]  same shape as fr.json
//
// The shape match is the point: a group file parses with Channel(json:), so
// the grid, Favorites (which persists whole channel dicts) and StreamStatus
// (which keys on URL) all work on playlist channels with no changes at all.
//
// Kept under Documents/playlists/ rather than beside the index, because
// CatalogRefresh removes ChannelIndex.refreshedDir wholesale when it swaps a
// rebuild in — a playlist living in there would vanish on the next refresh.

struct Playlist {
    let id: String
    var name: String
    let url: String
    var count: Int
    var groups: Int
    var refreshed: Date?

    init(id: String, name: String, url: String,
         count: Int = 0, groups: Int = 0, refreshed: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.count = count
        self.groups = groups
        self.refreshed = refreshed
    }

    init?(json: [String: Any]) {
        guard let i = json["i"] as? String, let n = json["n"] as? String,
              let u = json["u"] as? String else { return nil }
        id = i
        name = n
        url = u
        count = (json["k"] as? Int) ?? 0
        groups = (json["g"] as? Int) ?? 0
        refreshed = (json["d"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["i": id, "n": name, "u": url, "k": count, "g": groups]
        if let r = refreshed { d["d"] = r.timeIntervalSince1970 }
        return d
    }
}

// One bucket inside a playlist. Deliberately the same fields as Country, so
// the group screen is the country screen with a different data source.
struct PlaylistGroup {
    let code: String
    let name: String
    let count: Int
}

enum PlaylistStore {

    static var root: String {
        let dirs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let docs = dirs.first ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("playlists")
    }

    static func dir(for id: String) -> String {
        return (root as NSString).appendingPathComponent(id)
    }

    private static var manifestPath: String {
        return (root as NSString).appendingPathComponent("playlists.json")
    }

    // MARK: - The list

    static func all() -> [Playlist] {
        guard let data = NSData(contentsOfFile: manifestPath) as Data?,
              let arr = (try? JSONSerialization.jsonObject(with: data, options: []))
                as? [[String: Any]] else { return [] }
        return arr.compactMap { Playlist(json: $0) }
    }

    static func save(_ list: [Playlist]) {
        try? FileManager.default.createDirectory(atPath: root,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: list.map { $0.json },
                                                     options: []) else { return }
        writeFile(data, to: manifestPath)
    }

    // Replaces the entry with the same id, or appends it.
    static func upsert(_ p: Playlist) {
        var list = all()
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p }
        else { list.append(p) }
        save(list)
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
        try? FileManager.default.removeItem(atPath: dir(for: id))
        try? FileManager.default.removeItem(atPath: dir(for: id) + "-new")
        DebugLog.shared.log("Playlist", "removed \(id)")
    }

    // Minted from the clock rather than from the URL: two playlists may
    // legitimately share a URL, and the id is a directory name that must never
    // be derived from anything the remote server controls.
    static func newID() -> String {
        return "p\(Int(Date().timeIntervalSince1970))\(arc4random_uniform(1000))"
    }

    // MARK: - Contents

    static func groups(for id: String) -> [PlaylistGroup] {
        guard let data = NSData(contentsOfFile: dir(for: id) + "/groups.json") as Data?,
              let arr = (try? JSONSerialization.jsonObject(with: data, options: []))
                as? [[String: Any]] else {
            DebugLog.shared.log("Playlist", "groups.json missing or unparseable for \(id)")
            return []
        }
        var out: [PlaylistGroup] = []
        for m in arr {
            guard let c = m["c"] as? String, let n = m["n"] as? String,
                  let k = m["k"] as? Int else { continue }
            out.append(PlaylistGroup(code: c, name: n, count: k))
        }
        return out
    }

    private static let queue = DispatchQueue(label: "tvold.playlists")

    // Sorted here rather than on disk: the importer streams entries out in file
    // order and never holds a whole group, so there is no point at which it
    // could sort one. A group is the size of a country file and this is the
    // same work ChannelIndex already does to build the Channel array.
    static func channels(for id: String, group: String,
                         completion: @escaping ([Channel]) -> Void) {
        queue.async {
            let path = dir(for: id) + "/\(group).json"
            var result: [Channel] = []
            if let data = NSData(contentsOfFile: path) as Data?,
               let arr = (try? JSONSerialization.jsonObject(with: data, options: []))
                as? [[String: Any]] {
                result.reserveCapacity(arr.count)
                for item in arr {
                    if let c = Channel(json: item) { result.append(c) }
                }
                result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } else {
                DebugLog.shared.log("Playlist", "\(id)/\(group).json missing or unparseable")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Writing
    //
    // POSIX, not Data.write(to:) — the Foundation overlay's file write kills the
    // process on the shipped 5.1.5 runtime. Same rule as IndexBuilder.write and
    // LogoCache.writeFile.
    @discardableResult
    static func writeFile(_ data: Data, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = data.withUnsafeBytes { raw in
            Foundation.write(fd, raw.baseAddress, raw.count)
        }
        return written == data.count
    }
}

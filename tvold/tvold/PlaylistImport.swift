import UIKit

// Downloads a user-supplied M3U and hands it to PlaylistBuilder.
//
// The CatalogRefresh of this feature, and it follows the same rules: the file
// goes straight to disk and never through memory, the result is built in a
// staging directory and renamed only once complete, and the manifest is written
// last so a half-finished import cannot be mistaken for a good one.
final class PlaylistImport {

    static let shared = PlaylistImport()

    enum Progress {
        case downloading(Float)          // 0...1
        case parsing(Int)                // entries so far
        case finished(channels: Int, groups: Int, dropped: Int)
        case failed(String)
    }

    private(set) var isRunning = false
    private var cancelled = false
    private var download: CurlDownloadToken?
    private let queue = DispatchQueue(label: "tvold.playlistimport")

    private var scratch: String {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        return ((dirs.first ?? NSTemporaryDirectory()) as NSString)
            .appendingPathComponent("playlist-import.m3u")
    }

    // `report` is always called on the main thread, and exactly one of
    // .finished / .failed arrives last. Drives both a first import and a
    // refresh — a refresh is the same job with an id that already exists.
    func start(id: String, name: String, url: String,
               report: @escaping (Progress) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        UIApplication.shared.isIdleTimerDisabled = true
        DebugLog.shared.log("Playlist", "importing \(id) from \(DebugLog.redact(url))")

        try? FileManager.default.removeItem(atPath: scratch)
        report(.downloading(0))

        download = CurlFetcher.downloadToFile(
            url: url, outputPath: scratch, timeout: 180,
            progress: { frac in report(.downloading(frac)) },
            completion: { [weak self] ok in
                guard let self = self else { return }
                guard ok else {
                    self.finish(.failed(self.cancelled ? "Cancelled"
                                        : "Could not download the playlist"), report)
                    return
                }
                self.build(id: id, name: name, url: url, report: report)
            })
    }

    func cancel() {
        cancelled = true
        download?.cancel()
    }

    private func finish(_ p: Progress, _ report: @escaping (Progress) -> Void) {
        try? FileManager.default.removeItem(atPath: scratch)
        download = nil
        isRunning = false
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            report(p)
        }
    }

    private func build(id: String, name: String, url: String,
                       report: @escaping (Progress) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let staging = PlaylistStore.dir(for: id) + "-new"
            try? fm.removeItem(atPath: staging)
            do {
                try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
                let result = try PlaylistBuilder.build(
                    m3uPath: self.scratch, outDir: staging,
                    isCancelled: { self.cancelled },
                    note: { n in DispatchQueue.main.async { report(.parsing(n)) } })

                // Swap last. The window where neither directory exists is a
                // rename wide, and dying inside it leaves no groups.json, which
                // PlaylistStore reads as an empty playlist rather than as a
                // half-written one.
                let final = PlaylistStore.dir(for: id)
                try? fm.removeItem(atPath: final)
                try fm.moveItem(atPath: staging, toPath: final)

                var p = Playlist(id: id, name: name, url: url,
                                 count: result.channels, groups: result.groups,
                                 refreshed: Date())
                // A refresh keeps whatever the user renamed the playlist to.
                if let existing = PlaylistStore.all().first(where: { $0.id == id }) {
                    p.name = existing.name
                }
                PlaylistStore.upsert(p)

                DebugLog.shared.log("Playlist", "\(id): \(result.channels) channels in"
                    + " \(result.groups) groups, \(result.dropped) dropped,"
                    + " \(DebugLog.residentMB())MB resident")
                self.finish(.finished(channels: result.channels, groups: result.groups,
                                      dropped: result.dropped), report)
            } catch {
                try? fm.removeItem(atPath: staging)
                DebugLog.shared.log("Playlist", "import failed: \(error)")
                self.finish(.failed("\(error)"), report)
            }
        }
    }
}

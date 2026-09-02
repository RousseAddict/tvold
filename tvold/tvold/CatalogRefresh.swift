import UIKit

// Refreshes the channel index from the live iptv-org API: downloads the four
// raw files to scratch space, hands them to IndexBuilder, and swaps the result
// in. Fetched through libcurl because the API is HTTPS and the iOS 6 TLS stack
// cannot reach it.
//
// The files are 20.7 MB and go straight to disk, never through memory.
//
// What cannot move on-device is build_index.py's --probe pass, which drops dead
// and fMP4 streams. That is ~17k HTTP requests and is not something to run from
// a phone. Liveness is covered at playback time instead, by the player's connect
// watchdog and StreamStatus.
final class CatalogRefresh {

    static let shared = CatalogRefresh()

    private static let api = "https://iptv-org.github.io/api"
    // Downloaded in this order, weighted by size so the progress bar advances
    // evenly rather than stalling on channels.json.
    private static let files: [(name: String, weight: Float)] = [
        ("countries", 0.01), ("streams", 0.17), ("logos", 0.34), ("channels", 0.48)
    ]

    enum Progress {
        case downloading(String, Float)   // overall 0...1
        case building(String)
        case finished(channels: Int, countries: Int)
        case failed(String)
    }

    private(set) var isRunning = false
    private var cancelled = false
    private var download: CurlDownloadToken?
    private let queue = DispatchQueue(label: "tvold.refresh")

    private var scratch: String {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        return ((dirs.first ?? NSTemporaryDirectory()) as NSString)
            .appendingPathComponent("refresh")
    }

    // MARK: - Driving

    // `report` is always called on the main thread, and exactly one of
    // .finished / .failed arrives last.
    func start(report: @escaping (Progress) -> Void) {
        guard !isRunning else { return }
        CrashReport.stage("refresh-start")
        isRunning = true
        cancelled = false
        // Owned here rather than by the settings screen: the refresh outlives
        // that screen if the user closes it, and a view controller that has
        // gone away cannot put the idle timer back.
        UIApplication.shared.isIdleTimerDisabled = true

        CrashReport.stage("refresh-scratch")
        let fm = FileManager.default
        try? fm.removeItem(atPath: scratch)
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)

        // logNow, not log: everything from here is new ground on this runtime,
        // and an async line is still sitting in the queue when the crash it was
        // meant to describe throws it away.
        DebugLog.shared.logNow("Refresh", "starting — \(DebugLog.residentMB())MB resident")
        downloadFile(at: 0, done: 0, report: report)
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

    // One file at a time, chained through completions. Sequential rather than
    // parallel on purpose: four concurrent transfers would each hold their own
    // curl buffers, and there is no time to save here worth spending memory on.
    private func downloadFile(at i: Int, done: Float, report: @escaping (Progress) -> Void) {
        if cancelled { finish(.failed("Cancelled"), report); return }
        guard i < CatalogRefresh.files.count else {
            build(report: report)
            return
        }
        let f = CatalogRefresh.files[i]
        let out = (scratch as NSString).appendingPathComponent("\(f.name).json")
        report(.downloading(f.name, done))
        CrashReport.stage("refresh-dl-\(f.name)")

        download = CurlFetcher.downloadToFile(
            url: "\(CatalogRefresh.api)/\(f.name).json",
            outputPath: out,
            // A stalled transfer must not hang the refresh forever, and 3
            // minutes is far beyond what 10 MB needs on any usable connection.
            timeout: 180,
            progress: { frac in
                report(.downloading(f.name, done + f.weight * frac * 0.75))
            },
            completion: { [weak self] ok in
                guard let self = self else { return }
                CrashReport.stage("refresh-dl-\(f.name)-\(ok ? "ok" : "failed")")
                guard ok else {
                    DebugLog.shared.log("Refresh", "download failed: \(f.name).json")
                    self.finish(.failed(self.cancelled ? "Cancelled"
                                        : "Could not download \(f.name).json"), report)
                    return
                }
                self.downloadFile(at: i + 1, done: done + f.weight * 0.75, report: report)
            })
    }

    private func build(report: @escaping (Progress) -> Void) {
        CrashReport.stage("refresh-build")
        queue.async { [weak self] in
            guard let self = self else { return }
            let staging = ChannelIndex.refreshedDir + "-new"
            do {
                let counts = try IndexBuilder.build(
                    dataDir: self.scratch, outDir: staging,
                    isCancelled: { self.cancelled },
                    note: { msg in DispatchQueue.main.async { report(.building(msg)) } })

                // Swap last, and only once the new index is complete on disk.
                // The gap where neither directory exists is a rename apart, and
                // dying inside it leaves no manifest, which ChannelIndex reads
                // as "no refreshed index" and falls back to the bundled one.
                let fm = FileManager.default
                try? fm.removeItem(atPath: ChannelIndex.refreshedDir)
                try fm.moveItem(atPath: staging, toPath: ChannelIndex.refreshedDir)
                ChannelIndex.shared.reset()
                UserDefaults.standard.set(Date(), forKey: CatalogRefresh.dateKey)

                DebugLog.shared.log("Refresh", "done: \(counts.channels) channels,"
                    + " \(counts.countries) countries, \(DebugLog.residentMB())MB resident")
                self.finish(.finished(channels: counts.channels,
                                      countries: counts.countries), report)
            } catch {
                try? FileManager.default.removeItem(atPath: staging)
                DebugLog.shared.log("Refresh", "build failed: \(error)")
                self.finish(.failed(self.cancelled ? "Cancelled" : "\(error)"), report)
            }
        }
    }

    // MARK: - Bundled/refreshed state, for the settings screen

    private static let dateKey = "tvold.lastRefresh"

    static var lastRefresh: Date? {
        return UserDefaults.standard.object(forKey: dateKey) as? Date
    }

    // Drops a refreshed catalogue so the bundled one takes over again. The way
    // back from a refresh that produced a worse index than the one that shipped.
    static func revertToBundled() {
        try? FileManager.default.removeItem(atPath: ChannelIndex.refreshedDir)
        UserDefaults.standard.removeObject(forKey: dateKey)
        ChannelIndex.shared.reset()
        DebugLog.shared.log("Refresh", "reverted to the bundled index")
    }
}


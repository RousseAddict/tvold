import UIKit

// Channel logos, fetched through libcurl.
//
// Every logo in the catalogue is HTTPS-only, so NSURLConnection cannot reach
// them on iOS 6 — but unlike playback these are plain byte fetches with no
// player involved, so CurlFetcher is enough and the loopback proxy isn't
// needed. Results are cached in memory and on disk; the disk copy is what
// makes a second visit to a country instant.
//
// Everything is downscaled to thumbnail size before it is cached or shown.
// The catalogue routinely carries 1000x1000 logos: at native size a screenful
// of cells is tens of MB of decoded bitmap, a full cache is hundreds, and an
// A5 device gets killed within seconds of opening a country. Nothing here
// ever holds a full-size bitmap for longer than the one draw call that
// downsamples it, and that happens one at a time on a serial queue.
final class LogoCache {
    static let shared = LogoCache()

    // 2x the widest cell logo box, so it still looks right on a Retina 4S.
    private static let maxSide: CGFloat = 128
    // Enough for roughly two screenfuls; the disk cache absorbs the rest.
    private static let memoryBudget = 4 * 1024 * 1024
    // A fast scroll through 2893 channels would otherwise queue thousands of
    // fetches onto CurlFetcher's serial queue and the logos would arrive
    // minutes late. Requests past this are dropped; the list re-asks for the
    // visible cells when scrolling stops.
    private static let maxInflight = 24
    // Wikimedia hosts 1,326 of the catalogue's 14,368 logos and answers 403 to
    // any request that arrives without a User-Agent. libcurl sends none unless
    // told to, so without this roughly 9% of tiles stay blank. Measured.
    private static let fetchHeaders = ["User-Agent": "tvold/1.0 (iOS 6 IPTV client)"]

    private let mem = NSCache<NSString, UIImage>()
    private let io = DispatchQueue(label: "tvold.logos")
    private var inflight = Set<String>()
    private let dir: String

    private init() {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        dir = caches + "/logos"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: nil)
        mem.totalCostLimit = LogoCache.memoryBudget
        NotificationCenter.default.addObserver(self, selector: #selector(purge),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
    }

    @objc private func purge() {
        mem.removeAllObjects()
        DebugLog.shared.log("Logos", "memory warning — cache purged")
    }

    // Synchronous memory hit, for laying a cell out without a flash of blank.
    func cached(_ url: String) -> UIImage? {
        return mem.object(forKey: url as NSString)
    }

    func load(_ url: String, completion: @escaping (UIImage?) -> Void) {
        if let img = cached(url) { completion(img); return }
        let path = dir + "/" + LogoCache.key(url)
        io.async {
            if let data = NSData(contentsOfFile: path) as Data?,
               let img = LogoCache.decodeScaled(data) {
                self.store(img, for: url)
                DispatchQueue.main.async { completion(img) }
                return
            }
            // Coalesce duplicates and cap the backlog. A dropped request is
            // not an error — the cell asks again next time it is configured.
            var skip = false
            objc_sync_enter(self)
            if self.inflight.contains(url) || self.inflight.count >= LogoCache.maxInflight {
                skip = true
            } else {
                self.inflight.insert(url)
            }
            objc_sync_exit(self)
            if skip { DispatchQueue.main.async { completion(nil) }; return }

            CurlFetcher.fetchData(url: url, headers: LogoCache.fetchHeaders, timeout: 15) { data in
                // Back to the serial queue: decoding and downsampling a
                // full-size logo must not happen on the main thread, and only
                // one full-size bitmap may be alive at a time.
                self.io.async {
                    objc_sync_enter(self)
                    self.inflight.remove(url)
                    objc_sync_exit(self)
                    guard let data = data else {
                        DebugLog.shared.log("Logos", "fetch failed \(url)")
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let source = UIImage(data: data)
                    guard let img = LogoCache.decodeScaled(data) else {
                        DebugLog.shared.log("Logos", "undecodable \(data.count)B \(url)")
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let src = source?.size ?? CGSize.zero
                    DebugLog.shared.log("Logos", "ok \(data.count)B \(Int(src.width))x\(Int(src.height))"
                        + " -> \(Int(img.size.width))x\(Int(img.size.height))"
                        + " res=\(DebugLog.residentMB())MB")
                    self.store(img, for: url)
                    // The original bytes go to disk, not the thumbnail: it
                    // keeps the write cheap and avoids re-encoding, and the
                    // read path downsamples again anyway.
                    LogoCache.writeFile(data, to: path)
                    DispatchQueue.main.async { completion(img) }
                }
            }
        }
    }

    // Raw POSIX, not Data.write(to:). The Foundation overlay's file write is
    // what was killing the process mid-write on the 5.1.5 runtime, and this
    // was the other place the app still used it — on the logo path, which is
    // exactly where the app died a few seconds after a country was opened.
    private static func writeFile(_ data: Data, to path: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        close(fd)
    }

    private func store(_ img: UIImage, for url: String) {
        let cost = Int(img.size.width * img.size.height * 4)
        mem.setObject(img, forKey: url as NSString, cost: cost)
    }

    // Decodes and downsamples in one draw. UIKit drawing into an image
    // context is thread-safe (iOS 4+), so this is safe off the main thread.
    private static func decodeScaled(_ data: Data) -> UIImage? {
        guard let img = UIImage(data: data) else { return nil }
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0 else { return nil }
        let f = min(1, min(maxSide / w, maxSide / h))
        let size = CGSize(width: max(1, floor(w * f)), height: max(1, floor(h * f)))
        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        img.draw(in: CGRect(origin: CGPoint.zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out
    }

    // djb2. Swift's hashValue is seeded per process, so it cannot be used for
    // anything that has to survive a relaunch — like a cache filename.
    private static func key(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 36)
    }
}

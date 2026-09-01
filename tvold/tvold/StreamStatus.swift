import Foundation

// Remembers which streams were found unreachable, so the grid can dim them.
//
// Only failures are stored. Roughly half the catalogue is dead at any moment
// but *which* half moves, so a verdict is a hint with a shelf life, not a fact:
// entries expire after a week and an unknown stream always counts as alive.
// That keeps the store naturally small (a few hundred URLs at worst) and means
// a wrong verdict costs a dimmed tile, never a hidden channel.
//
// Keyed by stream URL rather than by channel name or index, which both move
// when the catalogue is refreshed.
enum StreamStatus {

    private static let key = "deadStreams"
    private static let expiry: TimeInterval = 7 * 24 * 3600

    // Both the scan's worker threads and the player's main thread write here.
    private static let lock = NSLock()
    private static var loaded: [String: Double]?

    // MARK: - Store

    // url -> the time it was found dead. Pruned on first read of the process,
    // which is the only moment expiry needs to be applied: nothing else adds
    // old entries.
    private static func map() -> [String: Double] {
        if let m = loaded { return m }
        let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let cutoff = Date().timeIntervalSinceReferenceDate - expiry
        let fresh = stored.filter { $0.value > cutoff }
        loaded = fresh
        if fresh.count != stored.count {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return fresh
    }

    static func isDead(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map()[url] != nil
    }

    static func markDead(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        var m = map()
        m[url] = Date().timeIntervalSinceReferenceDate
        loaded = m
        UserDefaults.standard.set(m, forKey: key)
    }

    static func markAlive(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        var m = map()
        guard m.removeValue(forKey: url) != nil else { return }
        loaded = m
        UserDefaults.standard.set(m, forKey: key)
    }

    // MARK: - Scan

    // Lets a screen that is being dismissed stop the workers it started.
    final class Token {
        // Written from the main thread, read by the workers. A plain Bool: the
        // read is a single word and a late observation costs one more request.
        fileprivate var cancelled = false
        func cancel() { cancelled = true }
    }

    // Shared cursor over the work list, plus the tallies the completion needs.
    private final class Cursor {
        let lock = NSLock()
        var next = 0
        var done = 0
        var dead = 0
    }

    // How many requests are in flight at once. Deliberately more than the two
    // cores an A5 has — these threads spend their time waiting on a socket, and
    // `concurrentPerform` would cap at the core count and take four times as
    // long.
    private static let workers = 6

    // Checks every playlist URL in `channels`, recording each verdict as it
    // lands. `progress` and `completion` are called on the main thread;
    // `completion` reports how many of the checked streams were dead.
    @discardableResult
    static func scan(_ channels: [Channel],
                     progress: @escaping (Int, Int) -> Void,
                     completion: @escaping (Int, Int) -> Void) -> Token {
        let token = Token()
        // A raw MPEG-TS endpoint never ends, so a GET would run for the whole
        // timeout and prove nothing. Only playlists are checkable; the rest
        // stay unknown, which is to say alive.
        let targets = channels.filter { $0.url.range(of: ".m3u8") != nil }
        let total = targets.count
        guard total > 0 else {
            DispatchQueue.main.async { completion(0, 0) }
            return token
        }

        DispatchQueue.global(priority: .default).async {
            // libcurl's one-time init has to happen off the main thread, and
            // before any worker calls curl_easy_init.
            CurlFetcher.ensureGlobalInit()

            let cursor = Cursor()
            let group = DispatchGroup()
            for _ in 0..<workers {
                DispatchQueue.global(priority: .default).async(group: group) {
                    while true {
                        cursor.lock.lock()
                        let i = cursor.next
                        cursor.next += 1
                        cursor.lock.unlock()
                        if i >= total || token.cancelled { return }

                        let channel = targets[i]
                        let alive = reachable(channel)
                        if alive { markAlive(channel.url) } else { markDead(channel.url) }

                        cursor.lock.lock()
                        cursor.done += 1
                        if !alive { cursor.dead += 1 }
                        let done = cursor.done
                        cursor.lock.unlock()
                        DispatchQueue.main.async { progress(done, total) }
                    }
                }
            }
            group.wait()
            let dead = cursor.dead
            let done = cursor.done
            DispatchQueue.main.async { completion(dead, done) }
        }
        return token
    }

    // A stream counts as reachable only if the response is a playlist. An HTTP
    // 200 on its own is not enough: a parked domain, a captive portal or an ISP
    // block page all answer 200 with HTML, and those are exactly the origins
    // that would otherwise be marked alive forever.
    private static func reachable(_ channel: Channel) -> Bool {
        guard let data = CurlFetcher.fetchSyncData(url: channel.url,
                                                   headers: channel.headers,
                                                   timeout: 12), !data.isEmpty else { return false }
        let head = data.count > 512 ? data.subdata(in: 0..<512) : data
        // isoLatin1 rather than utf8: it cannot fail, so a binary body reaches
        // the marker test and fails *that* instead of being misread as an error.
        guard let text = String(data: head, encoding: .isoLatin1) else { return false }
        return text.range(of: "#EXTM3U") != nil
    }
}

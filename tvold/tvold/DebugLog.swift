import Foundation

// Lightweight on-device debug trace, aimed at diagnosing "playback doesn't
// start" reports without a Mac/Xcode attached. Writes timestamped lines to
// Documents/debug.log (capped + trimmed), and exposes the tail as plain text
// so it can be copied to the clipboard directly from the app.
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "com.jellyold.debuglog")
    private let maxBytes = 500 * 1024

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    // Documents/debug.log, resolved with NSSearchPathForDirectoriesInDomains —
    // a plain C function, not FileManager's URL overlay.
    //
    // Everything on this path is deliberately the most primitive API that will
    // do the job. This is the one component that has to keep working while the
    // app is falling over, so it cannot be built on the same high-level
    // Foundation surface whose behaviour on the 5.1.5 runtime is the thing
    // being investigated.
    private var logPath: String {
        let dirs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let docs = dirs.first ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("debug.log")
    }

    private init() {}

    // Query parameters whose value must never reach the log. api_key is
    // Jellyfin's; the rest are how IPTV providers hand out a subscription —
    // an Xtream get.php URL carries username and password in the clear, and
    // the log is viewable and exportable from inside the app.
    private static let secretParams = ["api_key", "password", "username", "token", "pass"]

    static func redact(_ text: String) -> String {
        var out = text
        for name in secretParams {
            out = mask(out, param: name)
        }
        return out
    }

    private static func mask(_ text: String, param: String) -> String {
        let needle = param + "="
        guard text.range(of: needle) != nil else { return text }
        let parts = text.components(separatedBy: needle)
        var out = parts[0]
        for part in parts.dropFirst() {
            out += needle + "***"
            // Keep whatever followed the value (&NextParam=...), so the rest of
            // the URL stays readable.
            if let amp = part.range(of: "&") {
                out += String(part[amp.lowerBound...])
            }
        }
        return out
    }

    // Resident size in MB, or -1 if the kernel call fails.
    //
    // Straight Darwin/mach C — deliberately not any Foundation or UIKit
    // memory API. An out-of-memory jetsam kill runs no app code at all, so
    // the only way to see one coming is to have written the number to disk
    // before it happened.
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }

    func log(_ category: String, _ message: String) {
        let line = format(category, message)
        queue.async { [weak self] in
            self?.append(line)
        }
    }

    // Same as log(), but returns only once the line is on disk. Launch-path
    // and pre-crash breadcrumbs must not be sitting in a queue that the crash
    // they are meant to describe will discard.
    func logNow(_ category: String, _ message: String) {
        let line = format(category, message)
        queue.sync { self.append(line) }
    }

    private func format(_ category: String, _ message: String) -> String {
        let stamp = dateFormatter.string(from: Date())
        return "[\(stamp)] [\(category)] \(message)\n"
    }

    // Raw POSIX open/write/close. No FileHandle, no Data.write, no URL overlay:
    // an O_APPEND write is one syscall that either lands on disk or does not,
    // which is what lets a line survive the crash it is describing.
    private func append(_ line: String) {
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        line.utf8CString.withUnsafeBufferPointer { buf in
            // utf8CString carries a trailing NUL that must not reach the file.
            _ = write(fd, buf.baseAddress, buf.count - 1)
        }
        close(fd)
        trimIfNeeded()
    }

    // Keeps the file bounded on long-running devices — drops the oldest half
    // once it crosses maxBytes rather than growing forever.
    private func trimIfNeeded() {
        let path = logPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let trimmed = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Retrieval for the "copy to clipboard" UI

    func readAll() -> String {
        queue.sync {
            (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "(debug log is empty)"
        }
    }

    func readLast(lines count: Int) -> String {
        let split = readAll().split(separator: "\n", omittingEmptySubsequences: true)
        return split.suffix(count).joined(separator: "\n")
    }

    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(atPath: self.logPath)
        }
    }
}

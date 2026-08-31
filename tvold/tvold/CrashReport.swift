import Foundation

// Detects an unclean shutdown and preserves the log that led up to it.
//
// Neither a signal crash nor a jetsam out-of-memory kill runs any app code, so
// nothing can be recorded at the moment it happens. What works instead is a
// flag: set it on launch, clear it on an orderly exit, and if it is still set
// at the next launch the previous session died. The previous session's log is
// rotated aside at launch so it survives to be shown.
final class CrashReport {
    private static let flagKey = "tvold.sessionRunning"
    // Set once an unclean run's log has been preserved, cleared once it has
    // been handed to the UI. Survives relaunches, unlike flagKey.
    private static let unshownKey = "tvold.reportUnshown"

    // True when the previous session ended without clearing the flag.
    private(set) static var crashedLastRun = false

    // Last launch stage reached, recorded in NSUserDefaults rather than the log
    // file. A second, independent evidence channel: if writing the log is
    // itself what fails, the stage still survives, and vice versa.
    private static let stageKey = "tvold.launchStage"
    private(set) static var previousStage = ""

    private static var docs: NSString {
        let dirs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        return (dirs.first ?? NSTemporaryDirectory()) as NSString
    }

    // Records the stage before logging it — the NSUserDefaults write has to be
    // flushed before we call into anything that might not come back.
    static func stage(_ name: String) {
        UserDefaults.standard.set(name, forKey: stageKey)
        UserDefaults.standard.synchronize()
        DebugLog.shared.logNow("Session", "stage: \(name)")
    }
    private static var currentPath: String { return docs.appendingPathComponent("debug.log") }
    private static var previousPath: String { return docs.appendingPathComponent("debug-previous.log") }

    static func beginSession() {
        crashedLastRun = UserDefaults.standard.bool(forKey: flagKey)
        previousStage = UserDefaults.standard.string(forKey: stageKey) ?? "(none recorded)"

        let fm = FileManager.default
        // Rotate the finished run's log aside — but never on top of an unclean
        // run's log that nobody has read yet. A crash loop relaunches the app
        // every few seconds, and rotating unconditionally would grind the one
        // interesting log out of existence long before it could be shown.
        let hold = UserDefaults.standard.bool(forKey: unshownKey)
            && fm.fileExists(atPath: previousPath)
        if fm.fileExists(atPath: currentPath) {
            if hold {
                try? fm.removeItem(atPath: currentPath)
            } else {
                try? fm.removeItem(atPath: previousPath)
                try? fm.moveItem(atPath: currentPath, toPath: previousPath)
            }
        }
        if crashedLastRun { UserDefaults.standard.set(true, forKey: unshownKey) }
        markRunning(true)

        stage("session-begun")
        DebugLog.shared.logNow("Session", "launch — previous run "
            + (crashedLastRun ? "ENDED UNCLEANLY at stage '\(previousStage)'" : "exited cleanly")
            + " — \(DebugLog.residentMB())MB resident")
    }

    // Hands the preserved log to the caller and clears the pending flag in the
    // same step; nil when there is nothing to report.
    //
    // Clearing *before* anything is drawn is deliberate. The previous build
    // cleared it only on an orderly exit, so a crash anywhere on the reporting
    // path left the flag set and every relaunch walked straight back into it —
    // a launch-time crash loop the app could never escape. Losing one report is
    // the cheaper failure.
    static func takeReport() -> String? {
        guard UserDefaults.standard.bool(forKey: unshownKey) else { return nil }
        UserDefaults.standard.set(false, forKey: unshownKey)
        UserDefaults.standard.synchronize()
        return previousLog()
    }

    // Backgrounding counts as orderly: the user leaving the app is not a crash,
    // and iOS may evict a backgrounded app at any time for its own reasons.
    static func endSession() { markRunning(false) }
    static func resumeSession() { markRunning(true) }

    private static func markRunning(_ running: Bool) {
        UserDefaults.standard.set(running, forKey: flagKey)
        UserDefaults.standard.synchronize()
    }

    static func previousLog() -> String {
        guard let text = try? String(contentsOfFile: previousPath, encoding: .utf8) else {
            return "(no log file was captured for the previous run)"
        }
        return text.isEmpty ? "(the previous run's log file was created but never written to)" : text
    }
}

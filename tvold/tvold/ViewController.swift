import UIKit
import MediaPlayer

// Spike: prove LocalStreamProxy lets MPMoviePlayerController play a LIVE HTTPS
// HLS stream on iOS 6.
//
// The test host (amagi.tv) rejects an iOS 6-style CBC-only TLS handshake with
// alert 40 — verified with `openssl s_client -cipher` — and only negotiates
// ECDHE-RSA-CHACHA20-POLY1305. So "Direct" is expected to FAIL on device and
// "Via proxy" is expected to PLAY. If Direct ever succeeds, the device is not
// actually exercising the iOS 6 TLS stack and the result proves nothing.
//
// Unlike jellyold's Jellyfin VOD playlists, this is a LIVE sliding-window
// playlist that the player re-requests every few seconds — the specific thing
// that was unverified before this spike.
final class ViewController: UIViewController {

    private static let liveHTTPS =
        "https://amg00145-amg00145c11-samsung-au-6579.playouts.now.amagi.tv/playlist.m3u8"

    private let proxy = LocalStreamProxy()
    private var player: MPMoviePlayerController?

    private let statusView = UITextView()
    private var playerHost = UIView()
    private var lines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        let w = view.bounds.width
        let h = view.bounds.height

        statusView.frame = CGRect(x: 4, y: 20, width: w - 8, height: 150)
        statusView.isEditable = false
        statusView.backgroundColor = UIColor(white: 0.1, alpha: 1)
        statusView.textColor = UIColor.green
        statusView.font = UIFont(name: "Courier", size: 10)
        view.addSubview(statusView)

        playerHost.frame = CGRect(x: 0, y: 176, width: w, height: h - 176 - 60)
        playerHost.backgroundColor = UIColor.darkGray
        view.addSubview(playerHost)

        addButton("Direct (expect FAIL)", x: 4, width: w / 2 - 6,
                  y: h - 54, action: #selector(playDirect))
        addButton("Via proxy (expect PLAY)", x: w / 2 + 2, width: w / 2 - 6,
                  y: h - 54, action: #selector(playProxied))

        log("ready. tap a button.")
        log("host requires GCM/CHACHA20 — iOS 6 cannot reach it directly.")
    }

    private func addButton(_ title: String, x: CGFloat, width: CGFloat,
                           y: CGFloat, action: Selector) {
        // .custom, not .system — UIButtonType.system is iOS 7+ and this build
        // has to run on iOS 6.
        let b = UIButton(type: .custom)
        b.frame = CGRect(x: x, y: y, width: width, height: 44)
        b.backgroundColor = UIColor(white: 0.25, alpha: 1)
        b.setTitle(title, for: .normal)
        b.setTitleColor(UIColor.white, for: .normal)
        b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 11)
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.addTarget(self, action: action, for: .touchUpInside)
        view.addSubview(b)
    }

    private func log(_ msg: String) {
        DebugLog.shared.log("Spike", msg)
        lines.append(msg)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        statusView.text = lines.joined(separator: "\n")
        let end = NSRange(location: (statusView.text as NSString).length, length: 0)
        statusView.scrollRangeToVisible(end)
    }

    // MARK: - Playback

    @objc private func playDirect() {
        log("--- DIRECT: handing the https URL straight to the player ---")
        play(URL(string: ViewController.liveHTTPS))
    }

    @objc private func playProxied() {
        log("--- PROXY: registering route ---")
        guard let url = URL(string: ViewController.liveHTTPS) else { return }
        guard let local = proxy.start(remoteURL: url) else {
            log("FAIL: proxy.start returned nil (loopback socket unavailable)")
            return
        }
        log("local: \(local.absoluteString)")
        play(local)
    }

    private func play(_ url: URL?) {
        guard let url = url else { log("bad URL"); return }

        player?.stop()
        player?.view.removeFromSuperview()
        NotificationCenter.default.removeObserver(self)

        guard let p = MPMoviePlayerController(contentURL: url) else {
            log("FAIL: MPMoviePlayerController init returned nil")
            return
        }
        p.view.frame = playerHost.bounds
        p.controlStyle = .embedded
        p.shouldAutoplay = true
        playerHost.addSubview(p.view)
        player = p

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(loadStateChanged),
                       name: .MPMoviePlayerLoadStateDidChange, object: p)
        nc.addObserver(self, selector: #selector(playbackStateChanged),
                       name: .MPMoviePlayerPlaybackStateDidChange, object: p)
        nc.addObserver(self, selector: #selector(finished(_:)),
                       name: .MPMoviePlayerPlaybackDidFinish, object: p)

        p.prepareToPlay()
        log("prepareToPlay called")
    }

    // MARK: - Player notifications

    @objc private func loadStateChanged() {
        guard let p = player else { return }
        var parts: [String] = []
        let s = p.loadState
        if s.contains(.playable) { parts.append("playable") }
        if s.contains(.playthroughOK) { parts.append("playthroughOK") }
        if s.contains(.stalled) { parts.append("stalled") }
        if parts.isEmpty { parts.append("unknown") }
        log("loadState: \(parts.joined(separator: "|"))")
        if s.contains(.playthroughOK) {
            log(">>> SUCCESS: stream is playing <<<")
        }
    }

    @objc private func playbackStateChanged() {
        guard let p = player else { return }
        let names = ["stopped", "playing", "paused", "interrupted",
                     "seekForward", "seekBackward"]
        let i = p.playbackState.rawValue
        let name = (i >= 0 && i < names.count) ? names[i] : "raw(\(i))"
        log("playbackState: \(name)")
    }

    @objc private func finished(_ n: Notification) {
        let raw = (n.userInfo?[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey]
                    as? NSNumber)?.intValue ?? -1
        // 0 = ended, 1 = user exited, 2 = playback error
        let reason = raw == 0 ? "ended" : (raw == 1 ? "userExited"
                     : (raw == 2 ? "ERROR" : "raw(\(raw))"))
        log("finished: \(reason)")
        if raw == 2 {
            log(">>> FAILED to play (expected for Direct on iOS 6) <<<")
        }
    }
}

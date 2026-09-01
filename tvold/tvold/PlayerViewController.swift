import UIKit
import MediaPlayer

// Fullscreen player. Everything it plays goes through LocalStreamProxy —
// direct HTTPS is not reachable from the iOS 6 TLS stack, and the catalogue
// is overwhelmingly HTTPS.
//
// Chrome is custom rather than MPMoviePlayerController's own fullscreen
// controls: zapping and favouriting need buttons of their own, and the
// built-in fullscreen chrome cannot be extended or overlaid cleanly.
final class PlayerViewController: UIViewController {

    private let proxy = LocalStreamProxy()
    private var player: MPMoviePlayerController?

    private var channels: [Channel]
    private var index: Int

    private let touchLayer = UIView()
    private let chrome = UIView()
    private let bottomBar = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let favButton = UIButton(type: .custom)
    private var hideTimer: Timer?
    private var connectTimer: Timer?

    // Roughly half the catalogue is dead at any time, and a dead origin makes
    // MPMoviePlayerController sit silent — no load-state change, no finish
    // notification, nothing to react to. Without a watchdog the UI just says
    // "Connecting" forever.
    private static let connectTimeout: TimeInterval = 15

    init(channels: [Channel], index: Int) {
        self.channels = channels
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    private var current: Channel { return channels[index] }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        // Gestures live on a transparent layer of our own, not on `view`.
        // MPMoviePlayerController's view swallows touches that land on it, so a
        // recognizer attached to `view` stops firing the moment the movie view
        // covers the screen — which leaves no way to bring the chrome back once
        // it has auto-hidden, and therefore no way out of the player at all.
        // This layer sits above the movie view and below the chrome, so buttons
        // still get their taps first.
        touchLayer.frame = view.bounds
        touchLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        touchLayer.backgroundColor = UIColor.clear
        view.addSubview(touchLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        touchLayer.addGestureRecognizer(tap)
        // Swipe down closes. A second way out that does not depend on the
        // chrome being visible, so a missed tap can never trap the user in a
        // fullscreen video with no controls.
        for (dir, sel) in [(UISwipeGestureRecognizer.Direction.left, #selector(zapNext)),
                           (UISwipeGestureRecognizer.Direction.right, #selector(zapPrevious)),
                           (UISwipeGestureRecognizer.Direction.down, #selector(closeTapped))] {
            let swipe = UISwipeGestureRecognizer(target: self, action: sel)
            swipe.direction = dir
            touchLayer.addGestureRecognizer(swipe)
        }

        // After the touch layer, so the chrome ends up above it.
        buildChrome()
        play()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.setStatusBarHidden(true, with: .fade)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.setStatusBarHidden(false, with: .fade)
    }

    override var shouldAutorotate: Bool { return true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }

    deinit {
        hideTimer?.invalidate()
        connectTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        player?.stop()
        proxy.stop()
    }

    // MARK: - Chrome

    private func buildChrome() {
        let w = view.bounds.width
        let h = view.bounds.height

        chrome.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        chrome.autoresizingMask = [.flexibleWidth]
        chrome.backgroundColor = UIColor(white: 0, alpha: 0.6)
        view.addSubview(chrome)

        let close = UIButton(type: .custom)
        close.frame = CGRect(x: 4, y: 4, width: 44, height: 36)
        close.setImage(Icons.image(.close, size: 22), for: .normal)
        close.accessibilityLabel = "Close"
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        chrome.addSubview(close)

        nameLabel.frame = CGRect(x: 52, y: 4, width: w - 52 - 48, height: 36)
        nameLabel.autoresizingMask = [.flexibleWidth]
        nameLabel.textColor = UIColor.white
        nameLabel.font = UIFont.boldSystemFont(ofSize: 14)
        nameLabel.backgroundColor = UIColor.clear
        chrome.addSubview(nameLabel)

        favButton.frame = CGRect(x: w - 44, y: 4, width: 40, height: 36)
        favButton.autoresizingMask = [.flexibleLeftMargin]
        favButton.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        favButton.setTitleColor(UIColor.yellow, for: .normal)
        favButton.addTarget(self, action: #selector(toggleFavorite), for: .touchUpInside)
        chrome.addSubview(favButton)

        bottomBar.frame = CGRect(x: 0, y: h - 52, width: w, height: 52)
        bottomBar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        bottomBar.backgroundColor = UIColor(white: 0, alpha: 0.6)
        view.addSubview(bottomBar)

        addBarButton(.skipBack, label: "Previous channel", x: 8, width: 80,
                     action: #selector(zapPrevious))
        addBarButton(.retry, label: "Retry", x: (w - 70) / 2, width: 70,
                     action: #selector(retry))
        addBarButton(.skipForward, label: "Next channel", x: w - 88, width: 80,
                     action: #selector(zapNext))

        statusLabel.frame = CGRect(x: 8, y: 48, width: w - 16, height: 20)
        statusLabel.autoresizingMask = [.flexibleWidth]
        statusLabel.textColor = UIColor(white: 0.8, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 12)
        statusLabel.backgroundColor = UIColor.clear
        view.addSubview(statusLabel)
    }

    // The button stays 80pt wide with a 28pt icon centred in it: the icon is
    // what is read, the button is what is hit.
    private func addBarButton(_ icon: Icon, label: String, x: CGFloat, width: CGFloat,
                              action: Selector) {
        let b = UIButton(type: .custom)
        b.frame = CGRect(x: x, y: 8, width: width, height: 36)
        b.autoresizingMask = x > view.bounds.width / 2 ? [.flexibleLeftMargin]
            : (x > 8 ? [.flexibleLeftMargin, .flexibleRightMargin] : [.flexibleRightMargin])
        b.setImage(Icons.image(icon, size: 28), for: .normal)
        b.accessibilityLabel = label
        b.addTarget(self, action: action, for: .touchUpInside)
        bottomBar.addSubview(b)
    }

    @objc private func toggleChrome() {
        setChrome(hidden: !chrome.isHidden)
    }

    private func setChrome(hidden: Bool) {
        hideTimer?.invalidate()
        chrome.isHidden = hidden
        bottomBar.isHidden = hidden
        statusLabel.isHidden = hidden
        if !hidden {
            hideTimer = Timer.scheduledTimer(timeInterval: 5, target: self,
                                             selector: #selector(autoHide), userInfo: nil,
                                             repeats: false)
        }
    }

    @objc private func autoHide() { setChrome(hidden: true) }

    // MARK: - Actions

    @objc private func closeTapped() {
        player?.stop()
        proxy.stop()
        dismiss(animated: true, completion: nil)
    }

    @objc private func toggleFavorite() {
        Favorites.shared.toggle(current)
        updateFavButton()
    }

    private func updateFavButton() {
        // Filled star when favourited, hollow when not.
        favButton.setTitle(Favorites.shared.contains(current) ? "\u{2605}" : "\u{2606}",
                           for: .normal)
    }

    @objc private func zapNext() { zap(1) }
    @objc private func zapPrevious() { zap(-1) }
    @objc private func retry() { play() }

    private func zap(_ delta: Int) {
        guard channels.count > 1 else { return }
        index = (index + delta + channels.count) % channels.count
        setChrome(hidden: false)
        play()
    }

    // MARK: - Playback

    private func play() {
        nameLabel.text = current.name
        updateFavButton()
        setChrome(hidden: false)

        tearDownPlayer()

        guard let remote = URL(string: current.url) else {
            status("Bad stream URL")
            return
        }
        status("Connecting\u{2026}")

        // start() bumps the proxy generation, which aborts any transfer still
        // running for the previous channel — otherwise a stuck segment fetch
        // holds its thread for the whole timeout after zapping away.
        let url = proxy.start(remoteURL: remote, headers: current.headers) ?? remote
        if url == remote {
            DebugLog.shared.log("Player", "proxy unavailable — trying the direct URL, HTTPS will fail on iOS 6")
        }

        guard let p = MPMoviePlayerController(contentURL: url) else {
            status("Player unavailable")
            return
        }
        p.view.frame = view.bounds
        p.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.controlStyle = .none
        p.scalingMode = .aspectFit
        p.shouldAutoplay = true
        view.insertSubview(p.view, at: 0)
        player = p

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(loadStateChanged),
                       name: .MPMoviePlayerLoadStateDidChange, object: p)
        nc.addObserver(self, selector: #selector(finished(_:)),
                       name: .MPMoviePlayerPlaybackDidFinish, object: p)

        p.prepareToPlay()
        connectTimer = Timer.scheduledTimer(timeInterval: PlayerViewController.connectTimeout,
                                            target: self, selector: #selector(connectTimedOut),
                                            userInfo: nil, repeats: false)
    }

    @objc private func connectTimedOut() {
        guard let p = player,
              !(p.loadState.contains(.playable) || p.loadState.contains(.playthroughOK))
        else { return }
        tearDownPlayer()
        setChrome(hidden: false)
        status("No response after \(Int(PlayerViewController.connectTimeout))s — try Next")
    }

    private func tearDownPlayer() {
        connectTimer?.invalidate()
        connectTimer = nil
        NotificationCenter.default.removeObserver(self)
        player?.stop()
        player?.view.removeFromSuperview()
        player = nil
    }

    private func status(_ text: String) {
        statusLabel.text = text
        DebugLog.shared.log("Player", "\(current.name): \(text)")
    }

    @objc private func loadStateChanged() {
        guard let p = player else { return }
        if p.loadState.contains(.playthroughOK) || p.loadState.contains(.playable) {
            // No immediate hide — play() already started the 5s auto-hide, so
            // the controls stay up long enough to actually be used.
            connectTimer?.invalidate()
            connectTimer = nil
            status("")
        } else if p.loadState.contains(.stalled) {
            status("Buffering\u{2026}")
        }
    }

    @objc private func finished(_ n: Notification) {
        let raw = (n.userInfo?[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey]
                    as? NSNumber)?.intValue ?? -1
        // 0 = ended, 1 = user exited, 2 = playback error.
        guard raw == 2 || raw == 0 else { return }
        setChrome(hidden: false)
        status(raw == 2 ? "Stream unavailable — try Next" : "Stream ended")
    }
}

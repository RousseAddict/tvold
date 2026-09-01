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
    private let positionLabel = UILabel()
    private let statusLabel = UILabel()
    private let busy = UIActivityIndicatorView(style: .whiteLarge)
    private let favButton = UIButton(type: .custom)
    private var hideTimer: Timer?
    private var connectTimer: Timer?

    // Set when a channel has given up, cleared by the next play(). While it is
    // set the chrome does not auto-hide: there is nothing behind it to look at,
    // and hiding it is how the user ends up staring at black with no controls
    // and no explanation of what went wrong.
    private var failed = false

    // Whether the current channel ever reached a playable state. A live stream
    // that drops after an hour reports the same playback error as one that was
    // never reachable, so without this a channel could be marked dead on the
    // strength of having been watched.
    private var becamePlayable = false

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
        // The player is where this app has always been most likely to die, and
        // until now the stage log stopped at 'root-visible' — every crash from
        // here on looked identical. These four stages bisect the open path:
        // chrome construction, icon drawing, and the handoff to
        // MPMoviePlayerController each get their own marker.
        CrashReport.stage("player-open")
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
        CrashReport.stage("player-chrome")
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

        nameLabel.frame = CGRect(x: 52, y: 4, width: w - 52 - 48 - 58, height: 36)
        nameLabel.autoresizingMask = [.flexibleWidth]
        nameLabel.textColor = UIColor.white
        nameLabel.font = UIFont.boldSystemFont(ofSize: 14)
        nameLabel.backgroundColor = UIColor.clear
        chrome.addSubview(nameLabel)

        // Where this channel sits in the list being zapped through. Without it
        // a swipe gives no sense of how far along the list you are, or that it
        // wraps around at the end.
        positionLabel.frame = CGRect(x: w - 48 - 58, y: 4, width: 58, height: 36)
        positionLabel.autoresizingMask = [.flexibleLeftMargin]
        positionLabel.textColor = UIColor(white: 0.6, alpha: 1)
        positionLabel.font = UIFont.systemFont(ofSize: 11)
        positionLabel.textAlignment = .right
        positionLabel.backgroundColor = UIColor.clear
        chrome.addSubview(positionLabel)

        favButton.frame = CGRect(x: w - 44, y: 4, width: 40, height: 36)
        favButton.autoresizingMask = [.flexibleLeftMargin]
        // A glyph rather than a drawn path: the grid cell's star is the same
        // character in the same colour, so the two screens agree, and a drawn
        // star is what crashed the player on device.
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

        // Centred on the screen and deliberately *not* part of the chrome: when
        // a stream fails the movie view is torn down and the screen is black,
        // and the one thing that must survive the chrome auto-hiding is the
        // sentence explaining why.
        statusLabel.frame = CGRect(x: 20, y: h / 2 - 8, width: w - 40, height: 60)
        statusLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]
        statusLabel.textColor = UIColor.white
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3
        statusLabel.backgroundColor = UIColor.clear
        view.addSubview(statusLabel)

        busy.center = CGPoint(x: w / 2, y: h / 2 - 32)
        busy.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                 .flexibleTopMargin, .flexibleBottomMargin]
        busy.hidesWhenStopped = true
        view.addSubview(busy)
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
        // A failed channel keeps its controls: Retry, Next and Close are the
        // only things left to do, and they are the only things on screen.
        let hide = hidden && !failed
        chrome.isHidden = hide
        bottomBar.isHidden = hide
        if !hide && !failed {
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
        // Solid star when favourited, hollow when not.
        let fav = Favorites.shared.contains(current)
        favButton.setTitle(fav ? "\u{2605}" : "\u{2606}", for: .normal)
        favButton.accessibilityLabel = fav ? "Remove from favourites" : "Add to favourites"
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
        positionLabel.text = channels.count > 1 ? "\(index + 1) / \(channels.count)" : nil
        CrashReport.stage("player-labels")
        updateFavButton()
        CrashReport.stage("player-icons")
        failed = false
        becamePlayable = false
        setChrome(hidden: false)

        tearDownPlayer()

        guard let remote = URL(string: current.url) else {
            fail("Bad stream URL")
            return
        }
        working("Connecting\u{2026}")

        // start() bumps the proxy generation, which aborts any transfer still
        // running for the previous channel — otherwise a stuck segment fetch
        // holds its thread for the whole timeout after zapping away.
        let url = proxy.start(remoteURL: remote, headers: current.headers) ?? remote
        if url == remote {
            DebugLog.shared.log("Player", "proxy unavailable — trying the direct URL, HTTPS will fail on iOS 6")
        }

        guard let p = MPMoviePlayerController(contentURL: url) else {
            fail("Player unavailable")
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
        CrashReport.stage("player-preparing")
        connectTimer = Timer.scheduledTimer(timeInterval: PlayerViewController.connectTimeout,
                                            target: self, selector: #selector(connectTimedOut),
                                            userInfo: nil, repeats: false)
    }

    @objc private func connectTimedOut() {
        guard let p = player,
              !(p.loadState.contains(.playable) || p.loadState.contains(.playthroughOK))
        else { return }
        tearDownPlayer()
        // Watching a channel is the most reliable liveness check there is, so
        // every play records its verdict — the explicit scan only exists to
        // fill in the channels nobody has opened.
        StreamStatus.markDead(current.url)
        fail("No response after \(Int(PlayerViewController.connectTimeout))s.\n"
             + "This channel looks dead — try Next, or Retry if you think it isn't.")
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
        statusLabel.text = text.isEmpty ? nil : text
        DebugLog.shared.log("Player", "\(current.name): \(text)")
    }

    // Something is happening and the wait is expected: spinner plus a word for
    // what it is waiting on.
    private func working(_ text: String) {
        busy.startAnimating()
        status(text)
    }

    // Nothing more will happen on its own. The message stays put and the chrome
    // stops auto-hiding until the next channel.
    private func fail(_ text: String) {
        busy.stopAnimating()
        failed = true
        status(text)
        setChrome(hidden: false)
    }

    @objc private func loadStateChanged() {
        guard let p = player else { return }
        if p.loadState.contains(.playthroughOK) || p.loadState.contains(.playable) {
            // No immediate hide — play() already started the 5s auto-hide, so
            // the controls stay up long enough to actually be used.
            connectTimer?.invalidate()
            connectTimer = nil
            becamePlayable = true
            failed = false
            busy.stopAnimating()
            StreamStatus.markAlive(current.url)
            status("")
            // Restarts the auto-hide the failure state suppressed, so a stream
            // that recovers does not keep its controls up over the video.
            setChrome(hidden: false)
        } else if p.loadState.contains(.stalled) {
            working("Buffering\u{2026}")
        }
    }

    @objc private func finished(_ n: Notification) {
        let raw = (n.userInfo?[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey]
                    as? NSNumber)?.intValue ?? -1
        // 0 = ended, 1 = user exited, 2 = playback error.
        guard raw == 2 || raw == 0 else { return }
        if raw == 2 && !becamePlayable { StreamStatus.markDead(current.url) }
        fail(raw == 2 ? "Stream unavailable.\nTry Next, or Retry to try again."
                      : "Stream ended.\nTry Retry, or Next for another channel.")
    }
}

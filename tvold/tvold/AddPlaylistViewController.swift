import UIKit

// Add a playlist by URL, and watch the first import run.
//
// A screen rather than a UIAlertView with a text field: the URL is the whole
// point of the form and provider URLs are long, so it needs a field wide enough
// to see what was pasted and to fix a typo in. The import then reports into the
// same screen, which is also where a failure has to be shown — an alert would
// have been dismissed long before the download finished.
//
// Form styling follows elementold's LoginVC: hand-built dark fields and a solid
// accent button, laid out fresh on every layout pass inside a scroll view that
// the keyboard shortens. The stock controls are not usable here —
// `borderStyle = .roundedRect` draws a white field on a black screen, and
// `UIButton(type: .roundedRect)` draws its own white bezel *under* whatever
// backgroundColor is set, so a white title on it is invisible.
final class AddPlaylistViewController: UIViewController, UITextFieldDelegate {

    private var scroll: UIScrollView!
    private let urlLabel = UILabel()
    private let urlField = UITextField()
    private let nameLabel = UILabel()
    private let nameField = UITextField()
    private let addButton = UIButton(type: .custom)
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)

    private var running = false

    // How much of the view the keyboard covers. The scroll view is shortened by
    // it rather than the whole view being pushed up, so whatever it hides can
    // still be scrolled to.
    private var keyboardOverlap: CGFloat = 0
    private weak var activeField: UITextField?

    private let controlHeight: CGFloat = 46
    private let labelHeight: CGFloat = 18
    private let labelGap: CGFloat = 4
    private let fieldGap: CGFloat = 16
    private let buttonGap: CGFloat = 24
    private let edgePadding: CGFloat = 20
    // Landscape is wide enough that full-width fields look stranded.
    private let maxContentWidth: CGFloat = 420

    private let accent = UIColor(red: 0.30, green: 0.68, blue: 1, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add Playlist"
        view.backgroundColor = UIColor.black
        registerKeyboardObservers()
        buildUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // UIKit's nav-bar inset lands around the first layout pass and
        // layoutContent measures against it, so the form would otherwise be
        // centred against an inset of zero.
        layoutContent()
        if !running { urlField.becomeFirstResponder() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        // Must be the first subview: that is what makes iOS 7 inset the content
        // for the navigation bar. On iOS 6 no inset is applied and none is
        // needed — the view already starts below the bar.
        scroll = UIScrollView(frame: view.bounds)
        scroll.backgroundColor = UIColor.clear
        scroll.showsHorizontalScrollIndicator = false
        view.addSubview(scroll)

        style(urlLabel, "Playlist URL")
        style(nameLabel, "Name (optional)")

        makeField(urlField, placeholder: "http://example.com/playlist.m3u")
        urlField.keyboardType = .URL
        urlField.returnKeyType = .next

        makeField(nameField, placeholder: "My playlist")
        nameField.returnKeyType = .done

        addButton.setTitle("Add", for: .normal)
        addButton.setTitleColor(UIColor.white, for: .normal)
        addButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .disabled)
        addButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        addButton.backgroundColor = accent
        addButton.layer.cornerRadius = 10
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        scroll.addSubview(addButton)

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = UIColor(white: 0.72, alpha: 1)
        statusLabel.backgroundColor = UIColor.clear
        scroll.addSubview(statusLabel)

        // Tinted explicitly: the default track is invisible on black.
        progress.progressTintColor = accent
        progress.trackTintColor = UIColor(white: 0.22, alpha: 1)
        progress.isHidden = true
        scroll.addSubview(progress)
    }

    private func style(_ label: UILabel, _ text: String) {
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = UIColor(white: 0.55, alpha: 1)
        // iOS 6 labels default to a white background.
        label.backgroundColor = UIColor.clear
        scroll.addSubview(label)
    }

    private func makeField(_ f: UITextField, placeholder: String) {
        f.backgroundColor = UIColor(white: 1, alpha: 0.08)
        f.textColor = UIColor.white
        f.font = UIFont.systemFont(ofSize: 15)
        // Without this the text sits on the field's baseline rather than in the
        // middle of a 46pt box.
        f.contentVerticalAlignment = .center
        f.layer.cornerRadius = 10
        f.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        f.layer.borderWidth = 1
        // A rounded field with no left inset puts the first character in the
        // corner radius.
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: controlHeight))
        f.leftViewMode = .always
        f.clearButtonMode = .whileEditing
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardAppearance = .dark
        f.delegate = self
        // The plain `placeholder` property draws dark grey, which is unreadable
        // on this background.
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [NSAttributedString.Key.foregroundColor: UIColor(white: 0.5, alpha: 1)])
        scroll.addSubview(f)
    }

    private func layoutContent() {
        guard scroll != nil else { return }
        let bounds = view.bounds
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width,
                              height: max(0, bounds.height - keyboardOverlap))

        let inset = scroll.contentInset
        let visibleHeight = scroll.bounds.height - inset.top - inset.bottom
        let width = min(bounds.width - edgePadding * 2, maxContentWidth)
        let left = (bounds.width - width) / 2

        let formHeight = (labelHeight + labelGap + controlHeight) * 2 + fieldGap
            + buttonGap + controlHeight
        var y = max(edgePadding, (visibleHeight - formHeight) / 2 - 40)

        urlLabel.frame = CGRect(x: left, y: y, width: width, height: labelHeight)
        y += labelHeight + labelGap
        urlField.frame = CGRect(x: left, y: y, width: width, height: controlHeight)
        y += controlHeight + fieldGap

        nameLabel.frame = CGRect(x: left, y: y, width: width, height: labelHeight)
        y += labelHeight + labelGap
        nameField.frame = CGRect(x: left, y: y, width: width, height: controlHeight)
        y += controlHeight + buttonGap

        addButton.frame = CGRect(x: left, y: y, width: width, height: controlHeight)
        y += controlHeight + buttonGap

        statusLabel.frame = CGRect(x: left, y: y, width: width, height: 54)
        y += 54 + 8
        progress.frame = CGRect(x: left, y: y, width: width, height: 4)
        y += 4 + edgePadding

        scroll.contentSize = CGSize(width: bounds.width, height: y)
    }

    // MARK: - Keyboard avoidance

    private func registerKeyboardObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                       name: UIResponder.keyboardWillShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ n: Notification) {
        guard let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0.25
        keyboardOverlap = overlap(with: frame)
        UIView.animate(withDuration: duration) {
            self.layoutContent()
            if let f = self.activeField {
                self.scroll.scrollRectToVisible(f.frame.insetBy(dx: 0, dy: -self.edgePadding),
                                                animated: false)
            }
        }
    }

    @objc private func keyboardWillHide(_ n: Notification) {
        let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0.25
        keyboardOverlap = 0
        UIView.animate(withDuration: duration) { self.layoutContent() }
    }

    // The notification carries the keyboard frame in SCREEN coordinates, and
    // before iOS 8 those are not rotated — in landscape its `height` is the
    // screen's short side, not what the keyboard covers. Converting screen ->
    // window -> view is right on every version and orientation.
    private func overlap(with keyboardFrame: CGRect) -> CGFloat {
        guard let window = view.window else { return keyboardFrame.height }
        let inWindow = window.convert(keyboardFrame, from: nil)
        let inView = view.convert(inWindow, from: window)
        return max(0, view.bounds.maxY - inView.minY)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === urlField {
            nameField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            addTapped()
        }
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { activeField = textField }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if activeField === textField { activeField = nil }
    }

    // MARK: - Import

    @objc private func addTapped() {
        if running {
            PlaylistImport.shared.cancel()
            statusLabel.text = "Cancelling\u{2026}"
            return
        }
        let url = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // http/https only, because the fetch goes through CurlFetcher and the
        // playback that follows goes through LocalStreamProxy — neither speaks
        // anything else.
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            alert(title: "Invalid URL", message: "Enter an http:// or https:// address.")
            return
        }

        var name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = AddPlaylistViewController.suggestedName(for: url) }

        view.endEditing(true)
        running = true
        addButton.setTitle("Cancel", for: .normal)
        addButton.backgroundColor = UIColor(white: 0.18, alpha: 1)
        statusLabel.text = "Starting\u{2026}"
        progress.progress = 0
        progress.isHidden = false

        let id = PlaylistStore.newID()
        PlaylistImport.shared.start(id: id, name: name, url: url) { [weak self] p in
            guard let self = self else { return }
            switch p {
            case .downloading(let frac):
                self.statusLabel.text = "\(Int(frac * 100))%  Downloading"
                self.progress.progress = frac
            case .parsing(let n):
                self.statusLabel.text = "Reading \(n) channels\u{2026}"
                self.progress.isHidden = true
            case .finished(let channels, let count, let dropped):
                self.reset()
                // The alert is its own window, so it survives the pop that puts
                // the new playlist on screen behind it.
                self.navigationController?.popViewController(animated: true)
                self.alert(title: "Playlist added",
                           message: PlaylistViewController.summary(channels: channels,
                                                                   groups: count,
                                                                   dropped: dropped))
            case .failed(let why):
                self.reset()
                self.statusLabel.text = nil
                self.alert(title: "Could not add playlist", message: why)
            }
        }
    }

    private func reset() {
        running = false
        addButton.setTitle("Add", for: .normal)
        addButton.backgroundColor = accent
        progress.isHidden = true
    }

    // Host of the URL, so an unnamed playlist still reads as something in the
    // list. Deliberately not the last path component: those are all "get.php"
    // or "playlist.m3u" and tell the user nothing.
    static func suggestedName(for url: String) -> String {
        var s = url
        for scheme in ["http://", "https://"] {
            if s.lowercased().hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)) }
        }
        if let slash = s.range(of: "/") { s = String(s[..<slash.lowerBound]) }
        if let colon = s.range(of: ":") { s = String(s[..<colon.lowerBound]) }
        return s.isEmpty ? "Playlist" : s
    }

    // Property by property — see the note in PlaylistViewController.
    private func alert(title: String, message: String) {
        let a = UIAlertView()
        a.title = title
        a.message = message
        a.cancelButtonIndex = a.addButton(withTitle: "OK")
        a.show()
    }
}

import UIKit

// Plain text dump of a debug log, with a Copy button. Exists so a crash can be
// diagnosed from the device alone — there is no Xcode attached to this thing.
final class LogViewController: UIViewController {

    private let text: String
    private let banner: String?
    private let textView = UITextView()

    // `banner` is the line shown above the log; nil for a routine view.
    init(text: String, banner: String?) {
        // The log is capped at 500 KB and a UITextView on an A5 struggles well
        // before that, so only the tail is shown — which is the part that
        // matters when the run ended abruptly.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        self.text = lines.suffix(400).joined(separator: "\n")
        self.banner = banner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Debug log"
        view.backgroundColor = UIColor.black

        var top: CGFloat = 0
        if let banner = banner {
            let label = UILabel(frame: CGRect(x: 8, y: 8, width: view.bounds.width - 16, height: 44))
            label.autoresizingMask = [.flexibleWidth]
            label.numberOfLines = 2
            label.font = UIFont.boldSystemFont(ofSize: 13)
            label.textColor = UIColor.orange
            label.backgroundColor = UIColor.clear
            label.text = banner
            view.addSubview(label)
            top = 56
        }

        textView.frame = CGRect(x: 0, y: top, width: view.bounds.width,
                                height: view.bounds.height - top)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        textView.textColor = UIColor.green
        textView.font = UIFont(name: "Courier", size: 9)
        textView.text = text
        view.addSubview(textView)

        navigationItem.leftBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyLog))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Scroll to the end — the last lines are the interesting ones.
        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }

    @objc private func copyLog() {
        UIPasteboard.general.string = text
        navigationItem.rightBarButtonItem?.title = "Copied"
    }

    // Wraps itself in a navigation controller so the buttons have a bar.
    static func present(from vc: UIViewController, text: String, banner: String?) {
        let nav = UINavigationController(rootViewController:
            LogViewController(text: text, banner: banner))
        nav.navigationBar.barStyle = .black
        vc.present(nav, animated: true, completion: nil)
    }
}

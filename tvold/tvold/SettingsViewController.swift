import UIKit

// Settings, reached from the gear on the root screen. Mostly a home for the
// catalogue refresh; the debug log lives here too now that it no longer needs
// its own permanent button in the navigation bar.
final class SettingsViewController: UIViewController, UITableViewDataSource,
                                    UITableViewDelegate, UIAlertViewDelegate {

    private let table = UITableView(frame: CGRect.zero, style: .grouped)

    // Live refresh state lives in a table header rather than inside a cell.
    // A .value1 cell truncates its detail label from the middle as soon as the
    // two labels compete for the row, which turned "Downloading channels.json…
    // 42%" into something unreadable. A header is free to be two lines tall and
    // to hold the progress bar next to the text it describes.
    private let header = UIView()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private static let headerHeight: CGFloat = 74

    private var running: Bool { return CatalogRefresh.shared.isRunning }

    // UIAlertView has no per-button closure on iOS 6, so the tag is how the
    // delegate callback tells the two confirmations apart.
    private static let confirmRefresh = 1
    private static let confirmRevert = 2

    private enum Section: Int {
        case catalogue, refresh, diagnostics, about
        static let count = 4
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = UIColor.black

        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = UIColor.black
        table.separatorColor = UIColor(white: 0.2, alpha: 1)
        view.addSubview(table)

        buildHeader()

        navigationItem.leftBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
    }

    @objc private func close() {
        // Leaving does not stop a refresh — it runs on its own queues and the
        // root screen picks up the new index when it finishes.
        dismiss(animated: true, completion: nil)
    }

    // MARK: - Status header

    private func buildHeader() {
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width,
                              height: SettingsViewController.headerHeight)
        header.autoresizingMask = [.flexibleWidth]
        header.backgroundColor = UIColor.clear

        statusLabel.frame = CGRect(x: 16, y: 12, width: view.bounds.width - 32, height: 36)
        statusLabel.autoresizingMask = [.flexibleWidth]
        // Two lines, always reserved: the height never changes as the text does,
        // so a progress tick can rewrite the label without the table having to
        // re-measure its header many times a second.
        statusLabel.numberOfLines = 2
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = UIColor.white
        statusLabel.backgroundColor = UIColor.clear
        header.addSubview(statusLabel)

        progress.frame = CGRect(x: 16, y: 56, width: view.bounds.width - 32, height: 4)
        progress.autoresizingMask = [.flexibleWidth]
        // The default tint is a mid blue on a light track — close to invisible
        // against this background.
        progress.progressTintColor = UIColor(red: 0.30, green: 0.68, blue: 1, alpha: 1)
        progress.trackTintColor = UIColor(white: 0.22, alpha: 1)
        header.addSubview(progress)
    }

    // Shown only while a refresh is in flight; the table has no header at all
    // the rest of the time rather than an empty gap where one used to be.
    private func showHeader(_ show: Bool) {
        table.tableHeaderView = show ? header : nil
    }

    private func setStatus(_ text: String?, fraction: Float?) {
        statusLabel.text = text
        if let f = fraction { progress.progress = f }
        progress.isHidden = fraction == nil
    }

    // MARK: - Refresh

    // Built property by property rather than through
    // UIAlertView(title:message:delegate:cancelButtonTitle:otherButtonTitles:).
    //
    // That initializer is a Swift UIKit-overlay shim, not a plain ObjC method,
    // and this app compiles against the 5.6.3 overlay but ships the 5.1.5
    // libswiftUIKit.dylib. A symbol present in one and not the other binds
    // lazily, so the app launches perfectly and then dies the first time the
    // initializer is actually called. `init()`, `addButton` and the properties
    // are all straight Objective-C and involve no overlay at all.
    private func alert(title: String, message: String,
                       confirm: String?, tag: Int) -> UIAlertView {
        let a = UIAlertView()
        a.title = title
        a.message = message
        a.tag = tag
        a.delegate = confirm == nil ? nil : self
        a.cancelButtonIndex = a.addButton(withTitle: confirm == nil ? "OK" : "Cancel")
        if let confirm = confirm { a.addButton(withTitle: confirm) }
        return a
    }

    private func confirmRefresh() {
        CrashReport.stage("refresh-alert-build")
        alert(title: "Refresh catalogue",
              message: "Downloads about 21 MB from iptv-org and rebuilds the channel list. "
                     + "Your favourites are kept. Best on Wi-Fi.",
              confirm: "Refresh",
              tag: SettingsViewController.confirmRefresh).show()
        CrashReport.stage("refresh-alert-shown")
    }

    private func confirmRevert() {
        alert(title: "Use bundled catalogue",
              message: "Discards the downloaded catalogue and goes back to the one that "
                     + "shipped with the app. Favourites are kept.",
              confirm: "Revert",
              tag: SettingsViewController.confirmRevert).show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt index: Int) {
        CrashReport.stage("alert-clicked-\(alertView.tag)-\(index)")
        guard index != alertView.cancelButtonIndex else { return }
        switch alertView.tag {
        case SettingsViewController.confirmRefresh: startRefresh()
        case SettingsViewController.confirmRevert:
            CatalogRefresh.revertToBundled()
            table.reloadData()
        default: break
        }
    }

    private func startRefresh() {
        CrashReport.stage("refresh-ui-start")
        setStatus("Starting\u{2026}", fraction: 0)
        showHeader(true)
        table.reloadData()
        CrashReport.stage("refresh-ui-ready")

        CatalogRefresh.shared.start { [weak self] p in
            guard let self = self else { return }
            switch p {
            case .downloading(let name, let overall):
                // The percentage leads: it is the part that changes, and at the
                // front it does not move around as the file name changes width.
                self.setStatus("\(Int(overall * 100))%  Downloading \(name).json",
                               fraction: overall)
            case .building(let msg):
                self.setStatus(msg, fraction: 0.85)
            case .finished(let channels, let countries):
                self.setStatus(nil, fraction: nil)
                self.showHeader(false)
                self.table.reloadData()
                self.alert(title: "Catalogue updated",
                           message: "\(channels) channels in \(countries) countries.",
                           confirm: nil, tag: 0).show()
            case .failed(let why):
                self.setStatus(nil, fraction: nil)
                self.showHeader(false)
                self.table.reloadData()
                self.alert(title: "Refresh failed", message: why,
                           confirm: nil, tag: 0).show()
            }
        }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { return Section.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        // Three short rows instead of one crowded one: a single cell holding
        // "16745 channels, 178 countries" on the left and a date on the right
        // has no room left for either.
        case .catalogue: return 3
        // The revert row only exists once there is something to revert to.
        case .refresh: return ChannelIndex.hasRefreshedIndex && !running ? 2 : 1
        case .diagnostics: return 2
        case .about: return 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .catalogue: return "Catalogue"
        case .refresh: return nil
        case .diagnostics: return "Diagnostics"
        case .about: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section)! == .refresh, !running else { return nil }
        return "A refresh brings in the newest channels, but cannot check which streams "
             + "are still alive — expect more dead ones than the bundled list has."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "s"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .value1, reuseIdentifier: id)
        cell.backgroundColor = UIColor(white: 0.08, alpha: 1)
        cell.textLabel?.textColor = UIColor.white
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.accessoryType = .none
        cell.selectionStyle = .none

        switch Section(rawValue: indexPath.section)! {
        case .catalogue:
            let countries = ChannelIndex.shared.countries()
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Channels"
                cell.detailTextLabel?.text = "\(countries.reduce(0) { $0 + $1.count })"
            case 1:
                cell.textLabel?.text = "Countries"
                cell.detailTextLabel?.text = "\(countries.count)"
            default:
                cell.textLabel?.text = "Updated"
                cell.detailTextLabel?.text = sourceDescription()
            }

        case .refresh:
            cell.selectionStyle = .blue
            if indexPath.row == 0 {
                cell.textLabel?.text = running ? "Cancel refresh" : "Refresh now"
                cell.textLabel?.textColor = running ? UIColor.orange : UIColor.white
            } else {
                cell.textLabel?.text = "Use bundled catalogue"
            }
            cell.detailTextLabel?.text = nil

        case .diagnostics:
            cell.selectionStyle = .blue
            cell.textLabel?.text = ["Debug log", "AC-3 transcode probe"][indexPath.row]
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator

        case .about:
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            cell.textLabel?.text = "tvold"
            cell.detailTextLabel?.text = v ?? "1.0"
        }
        return cell
    }

    // Short by design — it shares a row with the "Updated" label, and a medium
    // date plus a time does not fit next to it on a 320pt screen.
    private func sourceDescription() -> String {
        guard ChannelIndex.hasRefreshedIndex else { return "Bundled" }
        guard let d = CatalogRefresh.lastRefresh else { return "Refreshed" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    // Probes do real work — encoding audio, and in the transcode case fetching
    // a multi-megabyte segment — so they never run on the main thread. A probe
    // run *while a stream plays* is part of the point, and blocking the main
    // thread would stall the player and corrupt the result being measured.
    private func runProbe(_ status: String, timeout: Double = 60,
                          _ work: @escaping () -> String) {
        showHeader(true)
        setStatus(status, fraction: nil)
        // A wedged probe is a real outcome, not a bug in the harness: the first
        // AAC run went into the hardware encoder and never returned. Without
        // this the screen just says "Probing…" forever and the finding is only
        // visible by reading the log afterwards. `done` is only ever touched on
        // the main thread, so the flag needs no locking.
        var done = false
        DispatchQueue.global(priority: .default).async {
            let text = work()
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                self.showHeader(false)
                LogViewController.present(from: self, text: text, banner: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !done else { return }
            done = true
            self.showHeader(false)
            DebugLog.shared.logNow("Probe", "did not return within \(Int(timeout))s")
            LogViewController.present(
                from: self,
                text: "The probe did not return within \(Int(timeout)) seconds.\n\n"
                    + "It is still running on a background thread — the app is "
                    + "fine. The last stage line in the debug log says which "
                    + "phase it stopped in.",
                banner: nil)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        CrashReport.stage("settings-row-\(indexPath.section)-\(indexPath.row)")
        switch Section(rawValue: indexPath.section)! {
        case .refresh:
            if indexPath.row == 0 {
                if running {
                    CatalogRefresh.shared.cancel()
                    setStatus("Cancelling\u{2026}", fraction: nil)
                } else {
                    confirmRefresh()
                }
            } else {
                confirmRevert()
            }
        case .diagnostics:
            switch indexPath.row {
            case 0:
                LogViewController.present(from: self, text: DebugLog.shared.readAll(),
                                          banner: nil)
            default:
                runProbe("Fetching M6 segment, transcoding\u{2026}") { TranscodeProbe.run() }
            }
        case .catalogue, .about:
            break
        }
    }
}

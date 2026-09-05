import UIKit

// One user playlist: its groups, and a way to refresh it.
//
// Deliberately the country list with a different data source — a playlist is
// stored in the catalogue's own shape, so Playlist -> group -> grid is
// Country -> grid with one extra level, and the grid underneath is untouched.
final class PlaylistViewController: UIViewController, UITableViewDataSource,
                                    UITableViewDelegate {

    private let table = UITableView()
    private var playlist: Playlist
    private var groups: [PlaylistGroup] = []

    // The refresh readout, in a table header for the same reason Settings puts
    // it there: a cell's detail label truncates from the middle and turns a
    // percentage into something unreadable.
    private let header = UIView()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)

    private var running = false

    init(playlist: Playlist) {
        self.playlist = playlist
        super.init(nibName: nil, bundle: nil)
        title = playlist.name
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = UIColor.black
        table.separatorColor = UIColor(white: 0.2, alpha: 1)
        view.addSubview(table)

        buildHeader()
        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "Refresh", style: .plain, target: self,
                            action: #selector(refreshTapped))
        groups = PlaylistStore.groups(for: playlist.id)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let sel = table.indexPathForSelectedRow { table.deselectRow(at: sel, animated: true) }
    }

    // MARK: - Refresh

    private func buildHeader() {
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 74)
        header.autoresizingMask = [.flexibleWidth]
        header.backgroundColor = UIColor.clear

        statusLabel.frame = CGRect(x: 16, y: 12, width: view.bounds.width - 32, height: 36)
        statusLabel.autoresizingMask = [.flexibleWidth]
        statusLabel.numberOfLines = 2
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = UIColor.white
        statusLabel.backgroundColor = UIColor.clear
        header.addSubview(statusLabel)

        progress.frame = CGRect(x: 16, y: 56, width: view.bounds.width - 32, height: 4)
        progress.autoresizingMask = [.flexibleWidth]
        progress.progressTintColor = UIColor(red: 0.30, green: 0.68, blue: 1, alpha: 1)
        progress.trackTintColor = UIColor(white: 0.22, alpha: 1)
        header.addSubview(progress)
    }

    @objc private func refreshTapped() {
        if running {
            PlaylistImport.shared.cancel()
            statusLabel.text = "Cancelling\u{2026}"
            return
        }
        running = true
        navigationItem.rightBarButtonItem?.title = "Cancel"
        table.tableHeaderView = header
        statusLabel.text = "Starting\u{2026}"
        progress.progress = 0
        progress.isHidden = false

        PlaylistImport.shared.start(id: playlist.id, name: playlist.name, url: playlist.url) {
            [weak self] p in
            guard let self = self else { return }
            switch p {
            case .downloading(let frac):
                self.statusLabel.text = "\(Int(frac * 100))%  Downloading"
                self.progress.progress = frac
            case .parsing(let n):
                self.statusLabel.text = "Reading \(n) channels\u{2026}"
                self.progress.isHidden = true
            case .finished(let channels, let count, let dropped):
                self.endRefresh()
                self.playlist.count = channels
                self.playlist.groups = count
                self.groups = PlaylistStore.groups(for: self.playlist.id)
                self.table.reloadData()
                self.alert(title: "Playlist updated",
                           message: PlaylistViewController.summary(channels: channels,
                                                                   groups: count,
                                                                   dropped: dropped))
            case .failed(let why):
                self.endRefresh()
                self.alert(title: "Refresh failed", message: why)
            }
        }
    }

    private func endRefresh() {
        running = false
        navigationItem.rightBarButtonItem?.title = "Refresh"
        table.tableHeaderView = nil
    }

    static func summary(channels: Int, groups: Int, dropped: Int) -> String {
        var s = "\(channels) channels in \(groups) groups."
        if dropped > 0 {
            // Said out loud rather than swallowed: a list can lose a large
            // slice to this, and silently showing a shorter list than the one
            // the user pasted looks like a bug.
            s += "\n\(dropped) entries were skipped — iOS 6 cannot play them."
        }
        return s
    }

    // Property by property, never
    // UIAlertView(title:message:delegate:cancelButtonTitle:otherButtonTitles:):
    // that initializer is a Swift overlay shim and binds lazily against the
    // 5.1.5 runtime this app ships, so it kills the process at first use.
    private func alert(title: String, message: String) {
        let a = UIAlertView()
        a.title = title
        a.message = message
        a.cancelButtonIndex = a.addButton(withTitle: "OK")
        a.show()
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "\(playlist.count) channels"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "g"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .value1, reuseIdentifier: id)
        cell.backgroundColor = UIColor(white: 0.08, alpha: 1)
        cell.textLabel?.textColor = UIColor.white
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.accessoryType = .disclosureIndicator
        let g = groups[indexPath.row]
        cell.textLabel?.text = g.name
        cell.detailTextLabel?.text = "\(g.count)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let g = groups[indexPath.row]
        let vc = ChannelListViewController(playlistID: playlist.id, group: g.code,
                                           groupName: g.name)
        navigationController?.pushViewController(vc, animated: true)
    }
}

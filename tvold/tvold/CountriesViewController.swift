import UIKit

// How the country list is ordered. Persisted because it is a standing
// preference, not a per-visit choice, and it is set from a different screen.
enum CountrySort: Int {
    case count = 0   // the manifest's own order
    case name = 1

    private static let key = "countrySort"

    static var current: CountrySort {
        get { return CountrySort(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .count }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var label: String {
        return self == .count ? "Most channels first" : "Alphabetical"
    }

    // The manifest is already ordered by channel count with ties broken on
    // country code, in both the Python and the on-device builder — so `.count`
    // leaves it alone rather than re-sorting it with an unstable sort and
    // getting a different order than the one that shipped.
    func apply(_ list: [Country]) -> [Country] {
        guard self == .name else { return list }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// Root screen: favourites shortcut on top, then every country in the
// catalogue, ordered by channel count or by name.
final class CountriesViewController: UIViewController, UITableViewDataSource,
                                     UITableViewDelegate, UISearchBarDelegate {

    private let table = UITableView()
    private let search = UISearchBar()
    private var all: [Country] = []
    private var shown: [Country] = []
    private var playlists: [Playlist] = []
    private var shownCrashLog = false
    private var appliedSort = CountrySort.current

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "tvold"
        view.backgroundColor = UIColor.black

        CrashReport.stage("loading-countries")
        all = appliedSort.apply(ChannelIndex.shared.countries())
        shown = all
        playlists = PlaylistStore.all()
        CrashReport.stage("countries-loaded-\(all.count)")

        search.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
        search.placeholder = "Search countries"
        search.delegate = self
        search.barStyle = .black

        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.dataSource = self
        table.delegate = self
        table.tableHeaderView = search
        table.backgroundColor = UIColor.black
        table.separatorColor = UIColor(white: 0.2, alpha: 1)
        view.addSubview(table)

        // The debug log moved inside Settings — it was only ever a bar button
        // because there was nowhere else to put it.
        navigationItem.rightBarButtonItem =
            UIBarButtonItem(title: "Settings", style: .plain, target: self,
                            action: #selector(showSettings))
        CrashReport.stage("root-vc-ready")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A refresh can have replaced the whole catalogue while Settings was
        // open, and so can the sort order — so re-read the manifest rather than
        // just redrawing: `all` would otherwise still hold the countries of the
        // index that was swapped out.
        let latest = CountrySort.current.apply(ChannelIndex.shared.countries())
        if latest.count != all.count || CountrySort.current != appliedSort {
            appliedSort = CountrySort.current
            all = latest
            search.text = nil
            shown = all
        }
        // The favourites count changes while the user is inside the player, and
        // a playlist can have been added or refreshed on the screens above.
        playlists = PlaylistStore.all()
        table.reloadData()
        if let sel = table.indexPathForSelectedRow { table.deselectRow(at: sel, animated: true) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CrashReport.stage("root-visible")
        guard !shownCrashLog, let report = CrashReport.takeReport() else { return }
        shownCrashLog = true
        LogViewController.present(from: self, text: report,
                                  banner: "Previous run died at stage '\(CrashReport.previousStage)'."
                                        + " Its log follows.")
    }

    @objc private func showSettings() {
        let nav = UINavigationController(rootViewController: SettingsViewController())
        nav.navigationBar.barStyle = .black
        present(nav, animated: true, completion: nil)
    }

    // MARK: - Table

    // 0: favourites, 1: the user's own playlists plus the row that adds one,
    // 2: the catalogue. Playlists sit above Countries because the list is short
    // and personal, and below Favorites for the same reason.
    func numberOfSections(in tableView: UITableView) -> Int { return 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return playlists.count + 1
        default: return shown.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return nil
        case 1: return "Playlists"
        default: return "Countries"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "c"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .value1, reuseIdentifier: id)
        cell.backgroundColor = UIColor(white: 0.08, alpha: 1)
        cell.textLabel?.textColor = UIColor.white
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.accessoryType = .disclosureIndicator

        switch indexPath.section {
        case 0:
            let n = Favorites.shared.channels.count
            cell.textLabel?.text = "Favorites"
            cell.detailTextLabel?.text = n == 0 ? "none yet" : "\(n)"
        case 1:
            if indexPath.row < playlists.count {
                let p = playlists[indexPath.row]
                cell.textLabel?.text = p.name
                cell.detailTextLabel?.text = "\(p.count)"
            } else {
                cell.textLabel?.text = "Add playlist\u{2026}"
                cell.textLabel?.textColor = UIColor(red: 0.30, green: 0.68, blue: 1, alpha: 1)
                cell.detailTextLabel?.text = nil
                cell.accessoryType = .none
            }
        default:
            let c = shown[indexPath.row]
            cell.textLabel?.text = c.name
            cell.detailTextLabel?.text = "\(c.count)"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch indexPath.section {
        case 0:
            let favs = Favorites.shared.channels
            if favs.isEmpty {
                tableView.deselectRow(at: indexPath, animated: true)
                return
            }
            let vc = ChannelListViewController(favorites: favs)
            navigationController?.pushViewController(vc, animated: true)
        case 1:
            if indexPath.row < playlists.count {
                let vc = PlaylistViewController(playlist: playlists[indexPath.row])
                navigationController?.pushViewController(vc, animated: true)
            } else {
                navigationController?.pushViewController(AddPlaylistViewController(),
                                                         animated: true)
            }
        default:
            let c = shown[indexPath.row]
            let vc = ChannelListViewController(countryName: c.name, code: c.code)
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    // Swipe-to-delete on playlist rows only. Deleting drops the whole imported
    // directory, not just the manifest entry — a playlist is a few MB of group
    // files and leaving them behind would be invisible and unreclaimable.
    func tableView(_ tableView: UITableView,
                   canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 1 && indexPath.row < playlists.count
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < playlists.count else { return }
        PlaylistStore.remove(id: playlists[indexPath.row].id)
        playlists.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    // MARK: - Search

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // Cancel appears only while editing, as on the channel grid: the keyboard
    // covers most of a 3.5-inch screen and tapping the list behind it selects a
    // country instead of dismissing.
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        searchBar.resignFirstResponder()
        applyFilter("")
    }

    private func applyFilter(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? all : all.filter { $0.name.lowercased().range(of: q) != nil }
        table.reloadData()
    }
}

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
    private var shownCrashLog = false
    private var appliedSort = CountrySort.current

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "tvold"
        view.backgroundColor = UIColor.black

        CrashReport.stage("loading-countries")
        all = appliedSort.apply(ChannelIndex.shared.countries())
        shown = all
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
        // The favourites count changes while the user is inside the player.
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

    func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? 1 : shown.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? nil : "Countries"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "c"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .value1, reuseIdentifier: id)
        cell.backgroundColor = UIColor(white: 0.08, alpha: 1)
        cell.textLabel?.textColor = UIColor.white
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.accessoryType = .disclosureIndicator

        if indexPath.section == 0 {
            let n = Favorites.shared.channels.count
            cell.textLabel?.text = "Favorites"
            cell.detailTextLabel?.text = n == 0 ? "none yet" : "\(n)"
        } else {
            let c = shown[indexPath.row]
            cell.textLabel?.text = c.name
            cell.detailTextLabel?.text = "\(c.count)"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 0 {
            let favs = Favorites.shared.channels
            if favs.isEmpty {
                tableView.deselectRow(at: indexPath, animated: true)
                return
            }
            let vc = ChannelListViewController(title: "Favorites", channels: favs)
            navigationController?.pushViewController(vc, animated: true)
        } else {
            let c = shown[indexPath.row]
            let vc = ChannelListViewController(countryName: c.name, code: c.code)
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    // MARK: - Search

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? all : all.filter { $0.name.lowercased().range(of: q) != nil }
        table.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

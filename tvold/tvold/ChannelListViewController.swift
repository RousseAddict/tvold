import UIKit

final class ChannelCell: UICollectionViewCell {
    static let reuseID = "ch"

    let logo = UIImageView()
    let name = UILabel()
    let star = UILabel()
    // Guards against a slow logo landing in a cell that has been recycled.
    var logoURL: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        contentView.layer.cornerRadius = 4

        logo.contentMode = .scaleAspectFit
        logo.backgroundColor = UIColor.clear
        contentView.addSubview(logo)

        name.font = UIFont.systemFont(ofSize: 10)
        name.textColor = UIColor.white
        name.textAlignment = .center
        name.numberOfLines = 2
        name.backgroundColor = UIColor.clear
        contentView.addSubview(name)

        star.font = UIFont.systemFont(ofSize: 12)
        star.textColor = UIColor.yellow
        star.text = "\u{2605}"
        star.backgroundColor = UIColor.clear
        star.isHidden = true
        contentView.addSubview(star)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let h = contentView.bounds.height
        logo.frame = CGRect(x: 6, y: 6, width: w - 12, height: h - 34)
        name.frame = CGRect(x: 2, y: h - 30, width: w - 4, height: 28)
        star.frame = CGRect(x: w - 16, y: 2, width: 14, height: 14)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logo.image = nil
        logoURL = nil
        contentView.alpha = 1
    }

    func configure(_ c: Channel) {
        name.text = c.name
        star.isHidden = !Favorites.shared.contains(c)
        // Dimmed, not hidden: a dead verdict is a hint that can be up to a week
        // stale, and a stream that came back should still be one tap away.
        contentView.alpha = StreamStatus.isDead(c.url) ? 0.35 : 1
        logoURL = c.logo
        guard let url = c.logo else {
            logo.image = nil
            return
        }
        if let img = LogoCache.shared.cached(url) {
            logo.image = img
            return
        }
        logo.image = nil
        LogoCache.shared.load(url) { [weak self] img in
            guard let self = self, self.logoURL == url else { return }
            self.logo.image = img
        }
    }
}

// Grid of channels for one country (loaded lazily from the bundled index) or
// for a fixed list (favourites).
final class ChannelListViewController: UIViewController, UICollectionViewDataSource,
                                       UICollectionViewDelegateFlowLayout, UISearchBarDelegate {

    private let search = UISearchBar()
    private var grid: UICollectionView!
    private let spinner = UIActivityIndicatorView(style: .white)
    private let empty = UILabel()

    // Where this screen's channels come from. Favourites is the odd one: it is
    // the only source that can change while the screen is on the stack, because
    // the player stars and unstars from underneath it.
    private enum Source {
        case country(String)
        case favorites
        case playlist(id: String, group: String)
    }

    private let source: Source
    private var all: [Channel] = []
    private var shown: [Channel] = []
    private var memTimer: Timer?
    private var scan: StreamStatus.Token?
    // The country name, put back when the progress readout that replaced it is
    // done with the title bar.
    private var savedTitle: String?

    init(countryName: String, code: String) {
        self.source = .country(code)
        super.init(nibName: nil, bundle: nil)
        title = countryName
    }

    init(favorites: [Channel]) {
        self.source = .favorites
        super.init(nibName: nil, bundle: nil)
        self.title = "Favorites"
        all = favorites
        shown = favorites
    }

    init(playlistID: String, group: String, groupName: String) {
        self.source = .playlist(id: playlistID, group: group)
        super.init(nibName: nil, bundle: nil)
        title = groupName
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        search.placeholder = "Search channels"
        search.delegate = self
        search.barStyle = .black
        search.autoresizingMask = [.flexibleWidth]

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Check", style: .plain,
                                                            target: self,
                                                            action: #selector(toggleCheck))

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        grid = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.backgroundColor = UIColor.black
        grid.dataSource = self
        grid.delegate = self
        grid.register(ChannelCell.self, forCellWithReuseIdentifier: ChannelCell.reuseID)

        // A 44pt hole is reserved at the top of the grid's content and the
        // search bar is slid to follow the scroll into it, so it scrolls away
        // like the country list's tableHeaderView does rather than costing 44
        // of the 416 points a 3.5-inch screen has — most of a row of tiles.
        //
        // The bar is a *sibling* of the grid, never a subview of it. A
        // UICollectionView has no tableHeaderView, and both ways of putting one
        // inside lose the keyboard mid-word: a section header is recycled by
        // `reloadData`, and a plain subview does not survive it either — and
        // reloadData runs on every keystroke. Outside the grid, nothing
        // reloadData does can reach it.
        grid.contentInset = UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)
        grid.scrollIndicatorInsets = grid.contentInset
        grid.contentOffset = CGPoint(x: 0, y: -44)

        // An empty view goes in ahead of the grid so the grid is not the root
        // view's *first* subview. iOS 7 auto-adjusts the content inset of a
        // scroll view in that position for the navigation bar, which would
        // overwrite the 44 set above and leave the search bar over the tiles.
        // Anything visible would be hidden behind the opaque grid, so this is
        // deliberately a view with nothing in it.
        view.addSubview(UIView(frame: CGRect.zero))
        view.addSubview(grid)

        empty.frame = view.bounds
        empty.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        empty.textAlignment = .center
        empty.textColor = UIColor(white: 0.5, alpha: 1)
        empty.font = UIFont.systemFont(ofSize: 14)
        empty.text = "No channels"
        empty.isHidden = true
        view.addSubview(empty)

        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                    .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(spinner)

        // Added last so it stays above the grid and the empty-state label as it
        // slides. Its y is owned by scrollViewDidScroll from here on.
        search.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
        view.addSubview(search)

        switch source {
        case .favorites:
            // Already in hand, and re-read on every appearance below.
            break
        case .country(let code):
            spinner.startAnimating()
            ChannelIndex.shared.channels(for: code) { [weak self] in self?.loaded($0) }
        case .playlist(let id, let group):
            spinner.startAnimating()
            PlaylistStore.channels(for: id, group: group) { [weak self] in self?.loaded($0) }
        }
    }

    private func loaded(_ list: [Channel]) {
        spinner.stopAnimating()
        all = list
        applyFilter(search.text ?? "")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Favourite stars, and the favourites list itself, change in the player.
        switch source {
        case .favorites:
            all = Favorites.shared.channels
            applyFilter(search.text ?? "")
        case .country, .playlist:
            grid.reloadData()
        }
        // A jetsam kill leaves no trace of its own, so the memory curve has to
        // already be in the log by the time it happens.
        memTimer?.invalidate()
        memTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(logMemory),
                                        userInfo: nil, repeats: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        memTimer?.invalidate()
        memTimer = nil
        // Six sockets of liveness checks would be competing with the segment
        // fetches of whatever the user just opened.
        if scan != nil { toggleCheck() }
    }

    @objc private func logMemory() {
        DebugLog.shared.log("Memory", "\(DebugLog.residentMB())MB — \(title ?? "?"), "
            + "\(shown.count) channels, \(grid.visibleCells.count) cells on screen")
    }

    deinit {
        memTimer?.invalidate()
        scan?.cancel()
    }

    // MARK: - Liveness check

    // Checks this screen's channels, or stops a check already running. The
    // verdicts are recorded as they land, so stopping halfway still leaves the
    // list better informed than it was.
    @objc private func toggleCheck() {
        if let running = scan {
            running.cancel()
            endCheck()
            return
        }
        guard !all.isEmpty else { return }
        savedTitle = title
        navigationItem.rightBarButtonItem?.title = "Stop"
        scan = StreamStatus.scan(all, progress: { [weak self] done, total in
            self?.title = "Checking \(done)/\(total)"
        }, completion: { [weak self] dead, done in
            guard let self = self else { return }
            DebugLog.shared.log("Status", "\(self.savedTitle ?? "?"): \(dead) of \(done) dead")
            self.endCheck()
        })
    }

    private func endCheck() {
        scan = nil
        navigationItem.rightBarButtonItem?.title = "Check"
        if let t = savedTitle { title = t }
        savedTitle = nil
        applyFilter(search.text ?? "")
    }

    // MARK: - Grid

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        return shown.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChannelCell.reuseID,
                                                      for: indexPath) as! ChannelCell
        cell.configure(shown[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cols = max(3, Int(collectionView.bounds.width / 110))
        let spacing: CGFloat = 8
        let w = (collectionView.bounds.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
        return CGSize(width: floor(w), height: floor(w) + 20)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        search.resignFirstResponder()
        let vc = PlayerViewController(channels: shown, index: indexPath.item)
        vc.modalTransitionStyle = .crossDissolve
        present(vc, animated: true, completion: nil)
    }

    // LogoCache drops requests once its backlog is full, so cells that came
    // and went during a fast scroll need to ask again once things settle.
    // Keeps the search bar glued to the top of the grid's content: flush with
    // the navigation bar when the grid is at rest, sliding up out of sight as
    // the grid scrolls, and back on a pull down. The 44 cancels the content
    // inset, so at rest (contentOffset.y == -44) the bar sits at y == 0.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        search.frame.origin.y = -44 - scrollView.contentOffset.y
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reconfigureVisible()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reconfigureVisible() }
    }

    private func reconfigureVisible() {
        for cell in grid.visibleCells {
            guard let c = cell as? ChannelCell, c.logo.image == nil,
                  let ip = grid.indexPath(for: cell), ip.item < shown.count else { continue }
            c.configure(shown[ip.item])
        }
    }

    // MARK: - Search

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // Cancel appears only while editing. The keyboard covers most of a 3.5-inch
    // screen and the grid behind it has nothing to tap that dismisses it, so
    // without this the only way out was the Search key.
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
        let matched = q.isEmpty ? all : all.filter { $0.name.lowercased().range(of: q) != nil }
        // Known-dead channels sink to the bottom. Two filters rather than a
        // sort: Swift's sort is not stable, and the catalogue's own ordering is
        // worth keeping within each group.
        let dead = matched.filter { StreamStatus.isDead($0.url) }
        shown = dead.isEmpty ? matched
            : matched.filter { !StreamStatus.isDead($0.url) } + dead
        empty.isHidden = !shown.isEmpty || spinner.isAnimating
        grid.reloadData()
    }
}

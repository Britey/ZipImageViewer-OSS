import UIKit

final class ArchiveLibraryViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    var onOpen: (() -> Void)?
    var onRetry: (() -> Void)?
    var onSelect: ((CachedArchiveSummary) -> Void)?
    var onRemove: ((CachedArchiveSummary) -> Void)?
    let searchController = UISearchController(searchResultsController: nil)
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private var archives: [CachedArchiveSummary] = []
    private var archiveByID: [UUID: CachedArchiveSummary] = [:]
    private var isReady = false
    private var isBusy = false
    private var failure: String?
    private var layoutKey = ""
    private var isGrid = false
    private let emptyScroll = UIScrollView()
    private let emptyStack = UIStackView()
    private let emptyIcon = UIImageView()
    private let emptyTitle = UILabel()
    private let emptyMessage = UILabel()
    private let emptyAction = UIButton(type: .system)
    private var didInitialLayout = false
    private var viewportAnchor: (UUID, CGFloat)?
    private var snapshotGeneration = 0
    private var isUpdatingLayout = false
    private var lastQuery = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "homeArchiveList"
        collectionView.delegate = self
        collectionView.register(ArchiveLibraryCell.self, forCellWithReuseIdentifier: ArchiveLibraryCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] collection, indexPath, id in
            guard let self, let archive = self.archiveByID[id],
                  let cell = collection.dequeueReusableCell(withReuseIdentifier: ArchiveLibraryCell.reuseIdentifier, for: indexPath) as? ArchiveLibraryCell else { return nil }
            cell.configure(archive, grid: self.isGrid, isBusy: self.isBusy,
                           details: { [weak self] in self?.showDetails(archive) },
                           remove: { [weak self] in self?.onRemove?(archive) })
            return cell
        }
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search archives"
        searchController.searchBar.accessibilityIdentifier = "librarySearch"
        configureEmptyState()
        updateSnapshot()
    }

    func update(archives: [CachedArchiveSummary], ready: Bool, busy: Bool, error: String? = nil) {
        self.archives = archives
        archiveByID = Dictionary(uniqueKeysWithValues: archives.map { ($0.id, $0) })
        isReady = ready
        isBusy = busy
        failure = error
        guard isViewLoaded else { return }
        collectionView.allowsSelection = !busy
        updateSnapshot()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.safeAreaLayoutGuide.layoutFrame.width
        let newGrid = width >= 600 && traitCollection.verticalSizeClass != .compact && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let key = "\(Int(width)):\(newGrid):\(traitCollection.preferredContentSizeCategory.rawValue)"
        guard width > 0, key != layoutKey else { return }
        layoutKey = key
        let anchor = viewportAnchor ?? visibleAnchor()
        isUpdatingLayout = true
        isGrid = newGrid
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        apply(snapshot, restoring: anchor)
        didInitialLayout = true
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        viewportAnchor = visibleAnchor()
        super.viewWillTransition(to: size, with: coordinator)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            guard let self else { return nil }
            let width = environment.container.effectiveContentSize.width
            let usable = min(width, self.isGrid ? 1440 : 840)
            let baseInset: CGFloat = self.isGrid ? (width >= 1000 ? 32 : 24) : 16
            let inset = baseInset + max(0, (width - usable) / 2)
            let count = self.isGrid ? min(6, max(2, Int((usable - baseInset * 2 + 20) / 220))) : 1
            // Unlike the deprecated subitem:count: initializer, repeatingSubitem
            // preserves the item's width. Account for every gap explicitly so
            // the last column cannot extend outside the section's content area.
            let itemWidth = max(1, floor((width - inset * 2 - CGFloat(count - 1) * 20) / CGFloat(count)))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(itemWidth), heightDimension: .estimated(self.isGrid ? 350 : 110)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(self.isGrid ? 350 : 110)), repeatingSubitem: item, count: count)
            group.interItemSpacing = .fixed(20)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: inset, bottom: 24, trailing: inset)
            section.interGroupSpacing = self.isGrid ? 20 : 12
            return section
        }
    }

    private func visibleAnchor() -> (UUID, CGFloat)? {
        guard didInitialLayout, let first = collectionView.indexPathsForVisibleItems.sorted().first,
              let id = dataSource.itemIdentifier(for: first), let attributes = collectionView.layoutAttributesForItem(at: first) else { return nil }
        return (id, attributes.frame.minY - collectionView.contentOffset.y - collectionView.adjustedContentInset.top)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, !isUpdatingLayout else { return }
        viewportAnchor = visibleAnchor()
    }

    private func apply(_ snapshot: NSDiffableDataSourceSnapshot<Int, UUID>, restoring anchor: (UUID, CGFloat)?) {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, self.snapshotGeneration == generation else { return }
            self.restore(anchor)
            self.isUpdatingLayout = false
            self.viewportAnchor = self.visibleAnchor()
        }
    }

    private func restore(_ anchor: (UUID, CGFloat)?) {
        guard let (id, delta) = anchor, let index = dataSource.indexPath(for: id) else { return }
        collectionView.layoutIfNeeded()
        guard let attributes = collectionView.layoutAttributesForItem(at: index) else { return }
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY,
            attributes.frame.minY - delta - collectionView.adjustedContentInset.top))), animated: false)
    }

    private func updateSnapshot() {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? archives : archives.filter { $0.displayName.localizedStandardContains(query) }
        let queryChanged = query != lastQuery
        lastQuery = query
        let anchor = queryChanged ? nil : (viewportAnchor ?? visibleAnchor())
        isUpdatingLayout = true
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(filtered.map(\.id))
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(filtered.map(\.id).filter { existing.contains($0) })
        apply(snapshot, restoring: anchor)
        if queryChanged {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }
        let showEmpty = filtered.isEmpty || !isReady || failure != nil
        emptyScroll.isHidden = !showEmpty
        collectionView.isHidden = showEmpty
        if let failure {
            setEmpty(symbol: "exclamationmark.arrow.triangle.2.circlepath", title: "Unable to Load Library", message: failure, action: "Try Again")
        } else if !isReady {
            setEmpty(symbol: "books.vertical", title: "Loading Library", message: "Your recent archives will appear here.", action: nil)
        } else if !query.isEmpty && filtered.isEmpty {
            setEmpty(symbol: "magnifyingglass", title: "No Matching Archives", message: "Try another name or clear your search.", action: "Clear Search")
        } else {
            setEmpty(symbol: "books.vertical", title: "Your next read starts here", message: "Open an archive to view its images.\nZIP, CBZ, and 7z", action: "Open Archive")
        }
        emptyAction.isEnabled = !isBusy && (isReady || failure != nil)
    }

    private func configureEmptyState() {
        emptyScroll.alwaysBounceVertical = false
        emptyScroll.contentInsetAdjustmentBehavior = .never
        emptyScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyScroll)
        NSLayoutConstraint.activate([
            emptyScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        emptyIcon.tintColor = .tintColor
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .light)
        emptyIcon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        emptyIcon.isAccessibilityElement = false
        emptyTitle.font = .preferredFont(forTextStyle: .title2)
        emptyMessage.font = .preferredFont(forTextStyle: .body)
        emptyMessage.textColor = .secondaryLabel
        for label in [emptyTitle, emptyMessage] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        emptyAction.configuration = config
        emptyAction.configuration?.titleLineBreakMode = .byWordWrapping
        emptyAction.titleLabel?.adjustsFontForContentSizeCategory = true
        emptyAction.isPointerInteractionEnabled = true
        emptyAction.addTarget(self, action: #selector(emptyTapped), for: .touchUpInside)
        emptyAction.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        emptyAction.accessibilityIdentifier = "libraryEmptyAction"
        [emptyIcon, emptyTitle, emptyMessage, emptyAction].forEach(emptyStack.addArrangedSubview)
        emptyStack.axis = .vertical
        emptyStack.alignment = .center
        emptyStack.spacing = 18
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        emptyScroll.addSubview(content)
        content.addSubview(emptyStack)
        // Centre short content in the viewport; longer accessibility content
        // grows the scrollable area without pinning it to the visible frame.
        let preferredHeight = content.heightAnchor.constraint(equalTo: emptyScroll.frameLayoutGuide.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: emptyScroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: emptyScroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: emptyScroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: emptyScroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: emptyScroll.frameLayoutGuide.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: emptyScroll.frameLayoutGuide.heightAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
            emptyStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 32),
            emptyStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -32),
            emptyTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            emptyMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            emptyTitle.widthAnchor.constraint(lessThanOrEqualTo: emptyStack.widthAnchor),
            emptyMessage.widthAnchor.constraint(lessThanOrEqualTo: emptyStack.widthAnchor),
            emptyAction.widthAnchor.constraint(lessThanOrEqualTo: emptyStack.widthAnchor),
            preferredHeight
        ])
    }

    private func setEmpty(symbol: String, title: String, message: String, action: String?) {
        emptyIcon.image = UIImage(systemName: symbol)
        emptyTitle.text = title
        emptyMessage.text = message
        emptyAction.isHidden = action == nil
        emptyAction.configuration?.title = action
    }

    @objc private func emptyTapped() {
        if failure != nil { onRetry?() }
        else if !(searchController.searchBar.text ?? "").isEmpty {
            searchController.searchBar.text = ""
            updateSnapshot()
        } else { onOpen?() }
    }

    func updateSearchResults(for searchController: UISearchController) { updateSnapshot() }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isBusy, let id = dataSource.itemIdentifier(for: indexPath), let archive = archiveByID[id] else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        onSelect?(archive)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isBusy, let id = dataSource.itemIdentifier(for: indexPath), let archive = archiveByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id.uuidString as NSString, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Archive Details", image: UIImage(systemName: "info.circle")) { _ in self?.showDetails(archive) },
                             UIAction(title: "Remove Cached Archive…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.onRemove?(archive) }])
        }
    }

    private func showDetails(_ archive: CachedArchiveSummary) {
        guard !isBusy else { return }
        let details = ArchiveDetailsViewController(archive: archive)
        details.onRemove = { [weak self, weak details] in
            details?.dismiss(animated: true) { self?.onRemove?(archive) }
        }
        let navigation = UINavigationController(rootViewController: details)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 560, height: 520)
        present(navigation, animated: true)
    }
}

private final class ArchiveDetailsViewController: UITableViewController {
    let archive: CachedArchiveSummary
    var onRemove: (() -> Void)?
    init(archive: CachedArchiveSummary) { self.archive = archive; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Archive Details"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 5 : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        if indexPath.section == 1 { config.text = "Remove Cached Archive…"; config.textProperties.color = .systemRed }
        else {
            let page = min(max(1, archive.position.index + 1), max(1, archive.imageCount))
            let values = [("Filename", archive.displayName), ("Format", archive.format.uppercased()),
                          ("Reading position", "Page \(page) of \(archive.imageCount)"),
                          ("Cached size", ByteCountFormatter.string(fromByteCount: archive.retainedBytes, countStyle: .file)),
                          ("Availability", archive.isAvailable ? "Ready to read" : "Select original again")]
            config.text = values[indexPath.row].0
            config.secondaryText = values[indexPath.row].1
            config.textProperties.numberOfLines = 0
            config.secondaryTextProperties.numberOfLines = 0
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = config
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { onRemove?() }
    }
}

import UIKit
import ImageIO

/// Independent of the full-resolution reader cache; at most two decodes run at once.
final class PageThumbnailLoader {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let cache = NSCache<NSURL, UIImage>()
    var retainImageWork: (() -> (() -> Void))?
    init() { cache.totalCostLimit = 24 * 1024 * 1024 }
    func load(_ url: URL, fallbackURL: URL? = nil, completion: @escaping (UIImage?) -> Void) -> Operation {
        let operation = BlockOperation()
        let release = retainImageWork?()
        operation.completionBlock = { release?() }
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            let image: UIImage?
            if let cached = self.cache.object(forKey: url as NSURL) {
                image = cached
            } else {
                image = Self.decode(url) ?? fallbackURL.flatMap { Self.decode($0) }
                if let image, let cg = image.cgImage {
                    self.cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
                }
            }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { if !operation.isCancelled { completion(image) } }
        }
        queue.addOperation(operation)
        return operation
    }
    static func decode(_ url: URL) -> UIImage? {
        ReaderImagePipeline.decode(url, maximumPixels: 720)
    }
    func clearCache() { cache.removeAllObjects() }
    func cancel() { queue.cancelAllOperations() }
    deinit { queue.cancelAllOperations() }
}

final class PageThumbnailCell: UICollectionViewCell {
    let imageView = UIImageView()
    let label = UILabel()
    var operation: Operation?
    var representedURL: URL?
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.tintColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.layer.cornerRadius = 12
        contentView.backgroundColor = .secondarySystemGroupedBackground
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); operation?.cancel(); operation = nil; representedURL = nil; imageView.image = nil }
}

final class PageOverviewViewController: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    private let urls: [URL]
    private let current: Int
    private let thumbnails = PageThumbnailLoader()
    var previewURLs: [URL: URL] = [:]
    var retainImageWork: (() -> (() -> Void))? { didSet { thumbnails.retainImageWork = retainImageWork } }
    private var didScrollToCurrent = false
    private var lastWidth: CGFloat = 0
    var onSelect: ((Int) -> Void)?
    private(set) var thumbnailSize: Double
    init(urls: [URL], currentIndex: Int, thumbnailSize: Double = 0.25) {
        self.thumbnailSize = thumbnailSize.isFinite ? min(1, max(0, thumbnailSize)) : 0.25
        self.urls = urls
        self.current = currentIndex
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        super.init(collectionViewLayout: layout)
        preferredContentSize = CGSize(width: 760, height: 760)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pages"
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.register(PageThumbnailCell.self, forCellWithReuseIdentifier: "page")
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: PageOverviewViewController, _) in
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.setNeedsLayout()
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if lastWidth != collectionView.bounds.width {
            lastWidth = collectionView.bounds.width
            collectionView.collectionViewLayout.invalidateLayout()
        }
        if !didScrollToCurrent, urls.indices.contains(current), collectionView.bounds.width > 0 {
            didScrollToCurrent = true
            collectionView.scrollToItem(at: IndexPath(item: current, section: 0), at: .centeredVertically, animated: false)
        }
    }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PageThumbnailCell
        let url = urls[indexPath.item]
        cell.operation?.cancel()
        cell.representedURL = url
        cell.imageView.image = UIImage(systemName: "photo")
        cell.label.text = "Page \(indexPath.item + 1)"
        cell.accessibilityLabel = "Page \(indexPath.item + 1) of \(urls.count)"
        cell.accessibilityTraits = indexPath.item == current ? [.button, .selected] : .button
        cell.accessibilityValue = indexPath.item == current ? "Current page" : nil
        cell.contentView.layer.borderWidth = indexPath.item == current ? 3 : 0
        cell.contentView.layer.borderColor = view.tintColor.cgColor
        cell.operation = thumbnails.load(previewURLs[url] ?? url, fallbackURL: previewURLs[url] == nil ? nil : url) { [weak cell] image in
            guard let cell, cell.representedURL == url else { return }
            cell.imageView.image = image ?? UIImage(systemName: "exclamationmark.triangle")
        }
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? PageThumbnailCell)?.operation?.cancel()
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = collectionView.bounds.inset(by: collectionView.adjustedContentInset).width - 32
        let preferred = CGFloat(96 + thumbnailSize * 184)
        let minimum = max(preferred, traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 140 : 96)
        let columns = max(1, Int((available + 12) / (minimum + 12)))
        let width = max(1, (available - CGFloat(columns - 1) * 12) / CGFloat(columns))
        return CGSize(width: width, height: width * 1.3 + UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection).lineHeight + 24)
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
        dismiss(animated: true)
    }
    func cancelThumbnailWork() { thumbnails.cancel() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); cancelThumbnailWork() }
    override func didReceiveMemoryWarning() { super.didReceiveMemoryWarning(); thumbnails.clearCache() }
}

import UIKit
import ImageIO

/// Thumbnail work is separate from the full-resolution reader cache.
final class LibraryThumbnailLoader {
    static let shared = LibraryThumbnailLoader()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private let cache = NSCache<NSString, UIImage>()
    private var memoryObserver: NSObjectProtocol?

    init() {
        cache.totalCostLimit = 24 * 1024 * 1024
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }

    @discardableResult
    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) -> Operation? {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { completion(image); return nil }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true]
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let cgImage = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            guard !operation.isCancelled else { return }
            let image = cgImage.map { UIImage(cgImage: $0) }
            if let image, let cgImage { self?.cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height) }
            DispatchQueue.main.async {
                guard !operation.isCancelled else { return }
                completion(image)
            }
        }
        queue.addOperation(operation)
        return operation
    }
}

final class ArchiveLibraryCell: UICollectionViewCell {
    static let reuseIdentifier = "ArchiveLibraryCell"
    private let cover = UIImageView()
    private let title = UILabel()
    private let progress = UILabel()
    private let position = UIProgressView(progressViewStyle: .default)
    private let more = UIButton(type: .system)
    private let stack = UIStackView()
    private let coverContainer = UIView()
    private var coverConstraints: [NSLayoutConstraint] = []
    private var representedID: UUID?
    private var thumbnailOperation: Operation?
    private var details: (() -> Void)?
    private var remove: (() -> Void)?
    private var isBusy = false
    private var usesGrid = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
        coverContainer.backgroundColor = .tertiarySystemGroupedBackground
        coverContainer.layer.cornerRadius = 10
        coverContainer.clipsToBounds = true
        cover.contentMode = .scaleAspectFit
        cover.tintColor = .tertiaryLabel
        cover.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor, constant: 6),
            cover.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor, constant: -6),
            cover.topAnchor.constraint(equalTo: coverContainer.topAnchor, constant: 6),
            cover.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor, constant: -6)
        ])
        title.font = .preferredFont(forTextStyle: .headline)
        title.accessibilityIdentifier = "archiveTitle"
        title.adjustsFontForContentSizeCategory = true
        progress.font = .preferredFont(forTextStyle: .subheadline)
        progress.accessibilityIdentifier = "archiveReadingProgress"
        progress.adjustsFontForContentSizeCategory = true
        progress.textColor = .secondaryLabel
        progress.numberOfLines = 0
        position.isAccessibilityElement = false
        let labels = UIStackView(arrangedSubviews: [title, progress, position])
        labels.axis = .vertical
        labels.spacing = 7
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        more.configuration = config
        more.accessibilityLabel = "Archive actions"
        more.accessibilityIdentifier = "archiveActions"
        more.isPointerInteractionEnabled = true
        more.showsMenuAsPrimaryAction = true
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 44), more.heightAnchor.constraint(equalToConstant: 44)])
        let info = UIStackView(arrangedSubviews: [labels, more])
        info.alignment = .center
        info.spacing = 4
        stack.addArrangedSubview(coverContainer)
        stack.addArrangedSubview(info)
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: ArchiveLibraryCell, _) in
            cell.updateLayoutForTraits()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({ self.updateAppearance() }, completion: nil)
    }

    private func updateAppearance() {
        contentView.backgroundColor = isHighlighted || isSelected || isFocused
            ? .tertiarySystemFill : .secondarySystemGroupedBackground
        contentView.layer.borderWidth = isFocused ? 2 : 0
        contentView.layer.borderColor = tintColor.cgColor
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        // Keep the column width supplied by the layout and let wrapped text
        // determine height. Estimated row heights must never compress a cover.
        attributes.size.height = ceil(contentView.systemLayoutSizeFitting(
            CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
        return attributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailOperation?.cancel()
        thumbnailOperation = nil
        representedID = nil
        cover.image = nil
        details = nil
        remove = nil
    }

    func configure(_ archive: CachedArchiveSummary, grid: Bool, isBusy: Bool,
                   details: @escaping () -> Void, remove: @escaping () -> Void) {
        thumbnailOperation?.cancel()
        representedID = archive.id
        self.details = details
        self.remove = remove
        self.isBusy = isBusy
        usesGrid = grid
        title.text = archive.displayName
        let page = min(max(1, archive.position.index + 1), max(1, archive.imageCount))
        let detail = archive.isAvailable ? "Page \(page) of \(archive.imageCount)" : "Select original again"
        progress.text = detail
        position.progress = Float(page) / Float(max(1, archive.imageCount))
        position.isHidden = !archive.isAvailable
        more.isEnabled = !isBusy
        more.menu = UIMenu(children: [
            UIAction(title: "Archive Details", image: UIImage(systemName: "info.circle")) { _ in details() },
            UIAction(title: "Remove Cached Archive…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in remove() }
        ])
        accessibilityLabel = "\(archive.displayName), \(detail)"
        accessibilityHint = archive.isAvailable ? "Resume reading" : "Select the original archive to continue reading"
        accessibilityIdentifier = "recentArchive-\(archive.id.uuidString)"
        accessibilityTraits = isBusy ? [.button, .notEnabled] : .button
        accessibilityCustomActions = isBusy ? [] : [UIAccessibilityCustomAction(name: "Archive Details", target: self, selector: #selector(showDetails)),
                                      UIAccessibilityCustomAction(name: "Remove Cached Archive", target: self, selector: #selector(removeArchive))]
        updateLayoutForTraits()
        cover.image = UIImage(systemName: "doc.zipper")
        if let url = archive.thumbnailURL {
            let id = archive.id
            thumbnailOperation = LibraryThumbnailLoader.shared.load(url) { [weak self] image in
                guard let self, self.representedID == id else { return }
                self.cover.image = image ?? UIImage(systemName: "doc.zipper")
            }
        }
    }

    private func updateLayoutForTraits() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let grid = usesGrid && !accessible
        // Resolve against the cell's traits: a new cell can be configured before
        // UIKit has updated fonts that were created outside this hierarchy.
        title.font = .preferredFont(forTextStyle: .headline, compatibleWith: traitCollection)
        progress.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        title.numberOfLines = accessible ? 0 : 2
        NSLayoutConstraint.deactivate(coverConstraints)
        stack.axis = grid ? .vertical : .horizontal
        stack.alignment = grid ? .fill : .center
        if grid {
            let aspect = coverContainer.heightAnchor.constraint(equalTo: coverContainer.widthAnchor, multiplier: 1.15)
            aspect.priority = .defaultHigh
            coverConstraints = [aspect, coverContainer.heightAnchor.constraint(lessThanOrEqualToConstant: 280)]
        } else {
            coverConstraints = [coverContainer.widthAnchor.constraint(equalToConstant: accessible ? 44 : 56),
                                coverContainer.heightAnchor.constraint(equalToConstant: accessible ? 60 : 76)]
        }
        NSLayoutConstraint.activate(coverConstraints)
        setNeedsLayout()
    }

    @objc private func showDetails() -> Bool { guard !isBusy else { return false }; details?(); return true }
    @objc private func removeArchive() -> Bool { guard !isBusy else { return false }; remove?(); return true }
}

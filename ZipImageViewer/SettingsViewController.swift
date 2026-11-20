import UIKit

/// One accessible form is shared by the library and active reader.
final class SettingsViewController: UITableViewController {
    private enum Section { case reading, order, storage, help }
    private let store: ReaderPreferencesStore
    private let includesStorage: Bool
    private var isUpdatingThumbnailSize = false
    private var storagePreferences = ArchiveCachePreferences()
    private var storageUsage = ArchiveCacheUsage(retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0)
    private var storageBusy = true
    private var visibleArchiveCount = 0
    private var sections: [Section] { includesStorage ? [.reading, .order, .storage, .help] : [.reading, .order, .help] }

    var onStoragePreferencesChange: ((ArchiveCachePreferences) -> Void)?
    var onRemoveAllCachedArchives: (() -> Void)?

    init(store: ReaderPreferencesStore, includesStorage: Bool) {
        self.store = store
        self.includesStorage = includesStorage
        super.init(style: .insetGrouped)
        title = includesStorage ? "Settings" : "Reader Settings"
        preferredContentSize = CGSize(width: 620, height: 720)
    }

    required init?(coder: NSCoder) { fatalError("Use init(store:includesStorage:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "readerSettings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.cellLayoutMarginsFollowReadableWidth = true
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: ReaderPreferencesStore.didChangeNotification, object: store)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SettingsViewController, _) in
            self.tableView.reloadData()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if navigationController?.viewControllers.first === self,
           navigationController?.presentingViewController != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
        tableView.reloadData()
    }

    func updateStorage(preferences: ArchiveCachePreferences, usage: ArchiveCacheUsage, isBusy: Bool, archiveCount: Int? = nil) {
        storagePreferences = preferences
        storageUsage = usage
        visibleArchiveCount = archiveCount ?? usage.archiveCount
        storageBusy = isBusy
        if isViewLoaded { tableView.reloadData() }
    }

    @objc private func preferencesChanged() {
        if !isUpdatingThumbnailSize { tableView.reloadData() }
    }
    private func update(_ mutation: (inout ReaderPreferences) -> Void) {
        var preferences = store.preferences
        mutation(&preferences)
        store.update(preferences)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .reading: return 9
        case .order: return 2
        case .storage: return 5
        case .help: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .reading: return "Reading"
        case .order: return "Page Order"
        case .storage: return "Storage"
        case .help: return "Help"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .reading: return "Changes apply to every archive, including the one you are reading. Page-turn animation also respects Reduce Motion."
        case .order: return "Sorts images inside each archive. Your current image stays selected when the order changes."
        case .storage: return "Compress extracted images saves space in newly extracted caches using JPEG XL. JPEG images are recompressed losslessly; PNG conversion may slightly reduce quality. Existing cached images are unchanged. Turn it off before importing an archive to preserve its original images.\n\nLowering a limit can remove the least recently opened cached copies. Original archive files are never deleted.\n\nCached images from password-protected archives are stored decrypted and reopen without a password. Passwords are never saved. Extraction may temporarily use extra storage."
        case .help: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let preferences = store.preferences
        switch sections[indexPath.section] {
        case .reading:
            switch indexPath.row {
            case 0: return switchCell("Page slider", id: "showPageSlider", isOn: preferences.showPageSlider) { [weak self] value in self?.update { $0.showPageSlider = value } }
            case 1: return switchCell("Show page count", id: "showPageCount", isOn: preferences.showPageCount) { [weak self] value in self?.update { $0.showPageCount = value } }
            case 2: return valueCell("Reading direction", value: preferences.readingDirectionReversed ? "Right to left" : "Left to right", id: "readingDirection")
            case 3: return switchCell("Page-turn animation", id: "pageTurnAnimation", isOn: preferences.enablePageTurnAnimation) { [weak self] value in self?.update { $0.enablePageTurnAnimation = value } }
            case 4: return valueCell("Tap areas", value: preferences.tapAreaDescription, id: "tapAreas")
            case 5: return switchCell("Tap center to show/hide controls", id: "centerTapTogglesControls", isOn: preferences.centerTapTogglesControls) { [weak self] value in self?.update { $0.centerTapTogglesControls = value } }
            case 8: return switchCell("Show image rotation buttons", id: "showRotationButtons", isOn: preferences.showRotationButtons) { [weak self] value in self?.update { $0.showRotationButtons = value } }
            case 7: return switchCell("Double-tap to zoom", id: "doubleTapZoom", isOn: preferences.enableDoubleTapZoom) { [weak self] value in self?.update { $0.enableDoubleTapZoom = value } }
            default:
                return ThumbnailSizeSettingCell(value: preferences.thumbnailSize) { [weak self] value in
                    guard let self else { return }
                    // Persist continuously without replacing the cell during the drag.
                    self.isUpdatingThumbnailSize = true
                    self.update { $0.thumbnailSize = value }
                    self.isUpdatingThumbnailSize = false
                }
            }
        case .order:
            return indexPath.row == 0 ? valueCell("Sort by", value: preferences.pageSortDescription, id: "pageSortCriterion") : valueCell("Order", value: preferences.sortOrder.title, id: "pageSortOrder")
        case .storage:
            switch indexPath.row {
            case 0:
                var value = "\(Self.bytes(storageUsage.totalBytes)) used · \(storageUsage.archiveCount) archives"
                if storageUsage.pendingDeletionBytes > 0 { value += "\n\(Self.bytes(storageUsage.pendingDeletionBytes)) awaiting cleanup" }
                return valueCell("Cached archives", value: value, id: "storageUsage", actionable: false)
            case 1: return valueCell("Storage limit", value: Self.bytes(storagePreferences.maximumBytes), id: "storageLimit", enabled: !storageBusy)
            case 2: return valueCell("Archive limit", value: storagePreferences.maximumArchiveCount.map(String.init) ?? "No limit", id: "archiveLimit", enabled: !storageBusy)
            case 3:
                return switchCell("Compress extracted images", id: "compressExtractedImages",
                                  isOn: storagePreferences.compressExtractedImages, enabled: !storageBusy) { [weak self] value in
                    guard let self, !self.storageBusy else { return }
                    var updated = self.storagePreferences
                    updated.compressExtractedImages = value
                    self.onStoragePreferencesChange?(updated)
                }
            default:
                let cell = valueCell("Remove All Cached Archives…", value: nil, id: "removeAllCachedArchives", enabled: !storageBusy && visibleArchiveCount > 0)
                cell.accessoryType = .none
                var content = cell.defaultContentConfiguration()
                content.text = "Remove All Cached Archives…"
                content.textProperties.numberOfLines = 0
                content.textProperties.color = !storageBusy && visibleArchiveCount > 0 ? .systemRed : .tertiaryLabel
                cell.contentConfiguration = content
                cell.accessibilityHint = "Asks for confirmation before removing cached copies and saved reading positions."
                return cell
            }
        case .help:
            return valueCell("Reader gestures", value: "Learn how to turn pages and show controls", id: "readerHelp")
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .reading:
            if indexPath.row == 2 {
                select(title: "Reading direction", options: ["Left to right", "Right to left"], selected: store.preferences.readingDirectionReversed ? 1 : 0) { [weak self] value in self?.update { $0.readingDirectionReversed = value == 1 } }
            } else if indexPath.row == 4 {
                navigationController?.pushViewController(TapAreaPickerViewController(store: store), animated: true)
            }
        case .order:
            if indexPath.row == 0 {
                select(title: "Sort by", options: ["Filename", "Modification date", "Creation date"], selected: store.preferences.sortCriterion.rawValue) { [weak self] value in self?.update { $0.sortCriterion = SortCriterion(rawValue: value) ?? .filename } }
            } else {
                select(title: "Order", options: ["Ascending", "Descending"], selected: store.preferences.sortOrder.rawValue) { [weak self] value in self?.update { $0.sortOrder = SortOrder(rawValue: value) ?? .ascending } }
            }
        case .storage:
            guard !storageBusy else { return }
            if indexPath.row == 1 {
                let values: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000]
                select(title: "Storage limit", options: values.map(Self.bytes), selected: values.firstIndex(of: storagePreferences.maximumBytes)) { [weak self] index in
                    guard let self else { return }
                    var preferences = self.storagePreferences
                    preferences.maximumBytes = values[index]
                    self.onStoragePreferencesChange?(preferences)
                }
            } else if indexPath.row == 2 {
                let values: [Int?] = [nil, 5, 10, 20, 50]
                select(title: "Archive limit", options: values.map { $0.map(String.init) ?? "No limit" }, selected: values.firstIndex(of: storagePreferences.maximumArchiveCount)) { [weak self] index in
                    guard let self else { return }
                    var preferences = self.storagePreferences
                    preferences.maximumArchiveCount = values[index]
                    self.onStoragePreferencesChange?(preferences)
                }
            } else if indexPath.row == 4 && visibleArchiveCount > 0 { onRemoveAllCachedArchives?() }
        case .help:
            navigationController?.pushViewController(ReaderHelpViewController(), animated: true)
        }
    }

    private func select(title: String, options: [String], selected: Int?, onSelect: @escaping (Int) -> Void) {
        navigationController?.pushViewController(SettingsSelectionViewController(title: title, options: options, selected: selected, onSelect: onSelect), animated: true)
    }

    private func valueCell(_ title: String, value: String?, id: String, actionable: Bool = true, enabled: Bool = true) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.secondaryText = value
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.textProperties.color = enabled ? .label : .tertiaryLabel
        content.secondaryTextProperties.color = enabled ? .secondaryLabel : .tertiaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = actionable ? .disclosureIndicator : .none
        cell.selectionStyle = actionable && enabled ? .default : .none
        cell.isUserInteractionEnabled = enabled
        cell.isAccessibilityElement = true
        cell.accessibilityIdentifier = id
        cell.accessibilityLabel = title
        cell.accessibilityValue = value
        cell.accessibilityTraits = actionable ? [.button] : [.staticText]
        if !enabled { cell.accessibilityTraits.insert(.notEnabled) }
        return cell
    }

    private func switchCell(_ title: String, id: String, isOn: Bool, enabled: Bool = true, onChange: @escaping (Bool) -> Void) -> UITableViewCell {
        SettingsSwitchCell(title: title, id: id, isOn: isOn, enabled: enabled,
                           accessibilitySize: traitCollection.preferredContentSizeCategory.isAccessibilityCategory, onChange: onChange)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
}

private final class SettingsSwitchCell: UITableViewCell {
    init(title: String, id: String, isOn: Bool, enabled: Bool, accessibilitySize: Bool, onChange: @escaping (Bool) -> Void) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = enabled ? .label : .tertiaryLabel
        label.isAccessibilityElement = false
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = enabled
        toggle.accessibilityLabel = title
        toggle.accessibilityIdentifier = id
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [label, toggle])
        stack.axis = accessibilitySize ? .vertical : .horizontal
        stack.alignment = accessibilitySize ? .leading : .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -4),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
        accessibilityElements = [toggle]
    }
    required init?(coder: NSCoder) { fatalError("Use configured initializer") }
}

private final class SettingsSelectionViewController: UITableViewController {
    private let options: [String]
    private let selected: Int?
    private let onSelect: (Int) -> Void

    init(title: String, options: [String], selected: Int?, onSelect: @escaping (Int) -> Void) {
        self.options = options
        self.selected = selected
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("Use configured initializer") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = options[indexPath.row]
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = indexPath.row == selected ? .checkmark : .none
        cell.accessibilityTraits = indexPath.row == selected ? [.button, .selected] : [.button]
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // Finish the pop before the owner presents a storage-impact confirmation.
        navigationController?.popViewController(animated: false)
        onSelect(indexPath.row)
    }
}

private final class ReaderHelpViewController: UITableViewController {
    private let instructions: [(String, String)] = [
        ("Turn pages", "Tap the left or right area, or swipe horizontally. Reading direction controls which side goes forward. While zoomed in, drag to move around the image; use the page controls to turn pages."),
        ("Show and hide controls", "Tap the small center area to toggle all controls when enabled in Settings. Touch and hold the image also works, or use Hide Controls. Hiding controls does not change your page slider or count preferences."),
        ("Find a page", "Use the page number to enter a page, the slider to move through the archive, or Pages to browse thumbnails.")
    ]
    init() { super.init(style: .insetGrouped); title = "Reader Help" }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { instructions.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = instructions[indexPath.row].0
        content.secondaryText = instructions[indexPath.row].1
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}


private final class ThumbnailSizeSettingCell: UITableViewCell {
    init(value: Double, onChange: @escaping (Double) -> Void) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let title = UILabel()
        title.text = "Thumbnail size"
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        let hint = UILabel()
        hint.text = "Smaller thumbnails show more pages in the overview."
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.numberOfLines = 0
        hint.textColor = .secondaryLabel
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = Float(value)
        slider.minimumValueImage = UIImage(systemName: "square.grid.3x3.fill")
        slider.maximumValueImage = UIImage(systemName: "square.fill")
        slider.accessibilityIdentifier = "thumbnailSize"
        slider.accessibilityLabel = "Thumbnail size"
        slider.accessibilityHint = hint.text
        slider.accessibilityValue = "\(Int((value * 100).rounded())) percent"
        slider.addAction(UIAction { [weak slider] _ in
            guard let slider else { return }
            slider.accessibilityValue = "\(Int((slider.value * 100).rounded())) percent"
            onChange(Double(slider.value))
        }, for: .valueChanged)
        slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [title, slider, hint])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        accessibilityElements = [slider]
    }
    required init?(coder: NSCoder) { fatalError("Use configured initializer") }
}

import UIKit

final class TapAreaPickerViewController: UITableViewController {
    private let store: ReaderPreferencesStore

    init(store: ReaderPreferencesStore) {
        self.store = store
        super.init(style: .insetGrouped)
        title = "Tap Areas"
    }
    required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "tapAreaPicker"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: ReaderPreferencesStore.didChangeNotification, object: store)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: TapAreaPickerViewController, _) in self.tableView.reloadData() }
    }
    @objc private func preferencesChanged() { tableView.reloadData() }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : ReaderPreferences.tapAreaPresets.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Tap preview" : "Choose a layout" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "These are physical areas of the reading screen. Changing reading direction swaps their page actions. When enabled, the small center area shows or hides controls instead of turning a page." : "A larger next-page area is recommended for one-handed reading. Touch and hold anywhere on the image to show or hide controls."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let preferences = store.preferences
        if indexPath.section == 0 { return TapAreaDiagramCell(preferences: preferences) }
        let ratio = ReaderPreferences.tapAreaPresets[indexPath.row]
        var choice = preferences
        choice.previousPageTapWidthRatio = ratio
        let recommended = abs(ratio - (preferences.readingDirectionReversed ? 0.7 : 0.3)) < 0.001
        let selected = abs(ratio - preferences.previousPageTapWidthRatio) < 0.001
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = choice.tapAreaDescription
        content.secondaryText = recommended ? "Recommended for this reading direction" : nil
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        cell.accessibilityIdentifier = "tapAreaPreset-\(Int(ratio * 100))"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        var preferences = store.preferences
        preferences.previousPageTapWidthRatio = ReaderPreferences.tapAreaPresets[indexPath.row]
        store.update(preferences)
    }
}

private final class TapAreaDiagramCell: UITableViewCell {
    init(preferences: ReaderPreferences) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let leftAction = preferences.readingDirectionReversed ? "Next page" : "Previous page"
        let rightAction = preferences.readingDirectionReversed ? "Previous page" : "Next page"
        let leftPercent = Int((preferences.previousPageTapWidthRatio * 100).rounded())
        let summary = label(preferences.tapAreaDescription, style: .headline)
        let left = label("Left \(leftPercent)%: \(leftAction)", style: .body)
        let right = label("Right \(100 - leftPercent)%: \(rightAction)", style: .body)
        let bar = UIView()
        bar.backgroundColor = .systemOrange
        bar.layer.cornerRadius = 10
        bar.clipsToBounds = true
        let leftArea = UIView()
        leftArea.backgroundColor = .systemBlue
        leftArea.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(leftArea)
        let boundary = UIView()
        boundary.backgroundColor = .label
        boundary.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(boundary)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 88),
            leftArea.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            leftArea.topAnchor.constraint(equalTo: bar.topAnchor),
            leftArea.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            leftArea.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: preferences.previousPageTapWidthRatio),
            boundary.centerXAnchor.constraint(equalTo: leftArea.trailingAnchor),
            boundary.topAnchor.constraint(equalTo: bar.topAnchor),
            boundary.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            boundary.widthAnchor.constraint(equalToConstant: 2)
        ])
        var rows: [UIView] = [summary, bar, left, right]
        if preferences.centerTapTogglesControls {
            let centerArea = UIImageView(image: UIImage(systemName: "eye"))
            centerArea.tintColor = .label
            centerArea.backgroundColor = .secondarySystemBackground
            centerArea.contentMode = .center
            centerArea.layer.cornerRadius = 6
            centerArea.layer.borderColor = UIColor.label.cgColor
            centerArea.layer.borderWidth = 1
            centerArea.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(centerArea)
            NSLayoutConstraint.activate([
                centerArea.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                centerArea.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                centerArea.widthAnchor.constraint(equalToConstant: 44),
                centerArea.heightAnchor.constraint(equalToConstant: 32)
            ])
            rows.append(label("Small center area: show/hide controls", style: .body))
        }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 12
        // Physical left/right zones must not be mirrored by the system locale.
        bar.semanticContentAttribute = .forceLeftToRight
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -8)
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Tap area preview"
        accessibilityValue = "Left \(leftPercent) percent, \(leftAction). Right \(100 - leftPercent) percent, \(rightAction)."
        if preferences.centerTapTogglesControls { accessibilityValue? += " Small center area, show or hide controls." }
        accessibilityTraits = .image
    }
    required init?(coder: NSCoder) { fatalError("Use init(preferences:)") }
    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }
}

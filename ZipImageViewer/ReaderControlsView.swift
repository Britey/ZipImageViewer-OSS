import UIKit

final class ReaderControlsView: UIView {
    let slider = UISlider()
    let pageButton = UIButton(type: .system)
    let backButton = UIButton(type: .system)
    let rotateCounterclockwiseButton = UIButton(type: .system)
    let rotateClockwiseButton = UIButton(type: .system)
    let settingsButton = UIButton(type: .system)
    let hideButton = UIButton(type: .system)
    let pagesButton = UIButton(type: .system)
    let topSurface = UIView()
    let bottomSurface = UIView()
    private let sliderSurface = UIView()
    private var expandedWidth: NSLayoutConstraint!
    private var pageWidthLimit: NSLayoutConstraint!
    private var showCount = true
    private var page = 0
    private var count = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        for surface in [topSurface, bottomSurface] {
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
        }
        configure(backButton, symbol: "chevron.backward", label: "Back to Library")
        backButton.accessibilityIdentifier = "readerClose"
        configure(rotateCounterclockwiseButton, symbol: "rotate.left", label: "Rotate image counterclockwise 90 degrees")
        rotateCounterclockwiseButton.accessibilityIdentifier = "readerRotateCounterclockwise"
        configure(rotateClockwiseButton, symbol: "rotate.right", label: "Rotate image clockwise 90 degrees")
        rotateClockwiseButton.accessibilityIdentifier = "readerRotateClockwise"
        rotateCounterclockwiseButton.isHidden = true
        rotateClockwiseButton.isHidden = true
        configure(settingsButton, symbol: "gearshape", label: "Reader Settings")
        configure(hideButton, symbol: "eye.slash", label: "Hide Controls")
        configure(pagesButton, symbol: "square.grid.2x2", label: "Pages")
        pagesButton.accessibilityIdentifier = "readerPages"
        pagesButton.accessibilityHint = "Browse page thumbnails"
        configure(pageButton, symbol: nil, label: "Go to page")
        pageButton.accessibilityIdentifier = "readerPageButton"
        pageButton.titleLabel?.adjustsFontSizeToFitWidth = true
        pageButton.titleLabel?.minimumScaleFactor = 0.75
        pageButton.setContentHuggingPriority(.required, for: .horizontal)
        pageButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for button in [backButton, rotateCounterclockwiseButton, rotateClockwiseButton, settingsButton, hideButton, pagesButton] {
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        backButton.translatesAutoresizingMaskIntoConstraints = false
        topSurface.addSubview(backButton)
        let trailingActions = UIStackView(arrangedSubviews: [rotateCounterclockwiseButton, rotateClockwiseButton, settingsButton, hideButton])
        trailingActions.spacing = 8
        trailingActions.translatesAutoresizingMaskIntoConstraints = false
        topSurface.addSubview(trailingActions)

        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(white: 0.65, alpha: 1)
        slider.thumbTintColor = .white
        slider.accessibilityLabel = "Page"
        slider.accessibilityIdentifier = "readerPageSlider"
        slider.translatesAutoresizingMaskIntoConstraints = false
        addMaterial(to: sliderSurface)
        sliderSurface.addSubview(slider)
        sliderSurface.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let minimumSliderWidth = sliderSurface.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        minimumSliderWidth.priority = .defaultHigh
        minimumSliderWidth.isActive = true
        let bottom = UIStackView(arrangedSubviews: [pageButton, sliderSurface, pagesButton])
        bottom.spacing = 8
        bottom.alignment = .center
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottomSurface.addSubview(bottom)
        expandedWidth = bottomSurface.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -16)
        expandedWidth.priority = .defaultHigh
        // Leave useful slider travel even for very long page counts on a phone.
        pageWidthLimit = pageButton.widthAnchor.constraint(lessThanOrEqualTo: bottomSurface.widthAnchor, multiplier: 0.4)
        pageWidthLimit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topSurface.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            topSurface.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            topSurface.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            topSurface.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topSurface.leadingAnchor),
            backButton.topAnchor.constraint(equalTo: topSurface.topAnchor),
            trailingActions.trailingAnchor.constraint(equalTo: topSurface.trailingAnchor),
            trailingActions.topAnchor.constraint(equalTo: topSurface.topAnchor),
            bottomSurface.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            bottomSurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomSurface.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bottomSurface.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bottomSurface.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            bottomSurface.heightAnchor.constraint(equalToConstant: 44),
            bottom.leadingAnchor.constraint(equalTo: bottomSurface.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: bottomSurface.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: bottomSurface.topAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomSurface.bottomAnchor),
            slider.leadingAnchor.constraint(equalTo: sliderSurface.leadingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: sliderSurface.trailingAnchor, constant: -12),
            slider.topAnchor.constraint(equalTo: sliderSurface.topAnchor),
            slider.bottomAnchor.constraint(equalTo: sliderSurface.bottomAnchor),
            expandedWidth, pageWidthLimit
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: ReaderControlsView, _) in self.updatePageTitle() }
        updatePageTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: UIButton, symbol: String?, label: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        configuration.cornerStyle = .capsule
        var background = UIBackgroundConfiguration.clear()
        background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        configuration.background = background
        button.configuration = configuration
        button.accessibilityLabel = label
        button.isPointerInteractionEnabled = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func addMaterial(to container: UIView) {
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        material.isUserInteractionEnabled = false
        material.translatesAutoresizingMaskIntoConstraints = false
        container.insertSubview(material, at: 0)
        container.layer.cornerRadius = 22
        container.clipsToBounds = true
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            material.topAnchor.constraint(equalTo: container.topAnchor),
            material.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func apply(showSlider: Bool, showCount: Bool, showRotationButtons: Bool = false) {
        rotateCounterclockwiseButton.isHidden = !showRotationButtons
        rotateClockwiseButton.isHidden = !showRotationButtons
        slider.isHidden = !showSlider
        sliderSurface.isHidden = !showSlider
        expandedWidth.isActive = showSlider
        pageWidthLimit.isActive = showSlider
        self.showCount = showCount
        updatePageTitle()
    }

    private func updatePageTitle() {
        // Keep the transport in one row at accessibility sizes, with the full
        // unabridged position available as the button's accessibility value.
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 15, weight: .medium), maximumPointSize: 24,
            compatibleWith: traitCollection)
        var configuration = pageButton.configuration
        configuration?.title = showCount ? "\(count == 0 ? 0 : page + 1)/\(count)" : nil
        // Hiding the count still leaves a direct jump action; Pages only opens thumbnails.
        configuration?.image = showCount ? nil : UIImage(systemName: "number")
        configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = font
            return result
        }
        pageButton.configuration = configuration
    }

    func update(page: Int, count: Int) {
        self.page = page
        self.count = count
        slider.maximumValue = Float(max(count - 1, 0))
        slider.value = Float(page)
        slider.isEnabled = count > 1
        slider.accessibilityValue = "Page \(count == 0 ? 0 : page + 1) of \(count)"
        pageButton.accessibilityValue = "Current page \(count == 0 ? 0 : page + 1) of \(count)"
        pageButton.isEnabled = count > 1
        pagesButton.isEnabled = count > 0
        updatePageTitle()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        // The empty space between edge buttons remains part of the reading canvas.
        return result === self || result === topSurface || result === bottomSurface ? nil : result
    }
}

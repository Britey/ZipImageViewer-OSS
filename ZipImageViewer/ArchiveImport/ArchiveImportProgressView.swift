import UIKit

/// Shared archive feedback; cancellation is shown only when the worker supports it.
final class ArchiveImportProgressView: UIView {
    var onCancel: (() -> Void)?

    private let stageLabel = UILabel()
    private let filenameLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let cancelButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.3)
        accessibilityViewIsModal = true

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        stageLabel.font = .preferredFont(forTextStyle: .headline)
        stageLabel.adjustsFontForContentSizeCategory = true
        stageLabel.textAlignment = .center
        stageLabel.numberOfLines = 0
        stageLabel.accessibilityIdentifier = "archiveImportStage"
        filenameLabel.font = .preferredFont(forTextStyle: .subheadline)
        filenameLabel.adjustsFontForContentSizeCategory = true
        filenameLabel.textColor = .secondaryLabel
        filenameLabel.textAlignment = .center
        filenameLabel.numberOfLines = 0
        filenameLabel.accessibilityIdentifier = "archiveImportFilename"
        progressView.accessibilityIdentifier = "archiveImportProgress"
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.accessibilityIdentifier = "cancelArchiveImport"
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.isPointerInteractionEnabled = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: [stageLabel, filenameLabel, spinner, progressView, cancelButton])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        let preferredHeight = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 48)
        preferredHeight.priority = .defaultHigh
        preferredHeight.isActive = true
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ state: ImportPresentationState) {
        update(stage: state.stage.title, filename: state.filename, progress: state.progress,
               canCancel: state.canCancel)
        if [.waitingForPassword, .completed, .failed].contains(state.stage) {
            spinner.stopAnimating()
            spinner.isHidden = true
            progressView.isHidden = true
        }
    }

    func update(stage: String, filename: String? = nil, progress: Double? = nil, canCancel: Bool = true) {
        let stageChanged = stageLabel.text != stage
        stageLabel.text = stage
        filenameLabel.text = filename
        filenameLabel.isHidden = filename?.isEmpty != false
        cancelButton.isEnabled = canCancel
        cancelButton.isHidden = !canCancel
        progressView.accessibilityLabel = stage
        if let progress, progress.isFinite {
            spinner.stopAnimating()
            spinner.isHidden = true
            progressView.isHidden = false
            progressView.progress = Float(min(1, max(0, progress)))
            progressView.accessibilityValue = "\(Int(min(1, max(0, progress)) * 100)) percent of this stage"
        } else {
            progressView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimating()
        }
        if stageChanged, window != nil {
            UIAccessibility.post(notification: .announcement, argument: stage)
        }
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}

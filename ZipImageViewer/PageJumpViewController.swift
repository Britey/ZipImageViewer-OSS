import UIKit

enum PageInput {
    static func index(for text: String, pageCount: Int) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let page = Int(value), page > 0, page <= pageCount else { return nil }
        return page - 1
    }
}

final class PageJumpViewController: UIViewController, UITextFieldDelegate {
    let pageCount: Int
    let currentIndex: Int
    var onSelect: ((Int) -> Void)?
    private let field = UITextField()
    private let errorLabel = UILabel()
    private var goItem: UIBarButtonItem!
    init(pageCount: Int, currentIndex: Int) {
        self.pageCount = pageCount
        self.currentIndex = currentIndex
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 480, height: 240)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Go to Page"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        goItem = UIBarButtonItem(title: "Go", style: .done, target: self, action: #selector(submit))
        navigationItem.rightBarButtonItem = goItem
        let range = UILabel()
        range.text = "Enter a page number from 1 to \(pageCount)."
        range.font = .preferredFont(forTextStyle: .body)
        range.adjustsFontForContentSizeCategory = true
        range.numberOfLines = 0
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .title2)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .numberPad
        field.returnKeyType = .go
        field.text = String(currentIndex + 1)
        field.accessibilityLabel = "Page number"
        field.accessibilityIdentifier = "pageJumpInput"
        field.delegate = self
        field.addTarget(self, action: #selector(validateInput), for: .editingChanged)
        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        let content = UIStackView(arrangedSubviews: [range, field, errorLabel])
        content.axis = .vertical
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        validateInput()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); field.becomeFirstResponder(); field.selectAll(nil) }
    @objc private func validateInput() {
        let valid = PageInput.index(for: field.text ?? "", pageCount: pageCount) != nil
        goItem.isEnabled = valid
        errorLabel.text = valid ? nil : "Use a whole number from 1 to \(pageCount)."
    }
    @objc private func submit() {
        guard let index = PageInput.index(for: field.text ?? "", pageCount: pageCount) else { validateInput(); return }
        onSelect?(index)
        dismiss(animated: true)
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { submit(); return true }
}

import UIKit

/// The sessions drawer that slides in from the left, like the Android `DrawerLayout` of
/// `TermuxActivity` with `TermuxSessionsListViewController`: a list of sessions and the
/// "Settings", "Keyboard" and "New session" buttons.
final class SessionsDrawerView: UIView, UITableViewDataSource, UITableViewDelegate {

    struct Item {
        let title: String
        let subtitle: String?
        let isCurrent: Bool
        let isRunning: Bool
        let exitStatus: Int32
    }

    var items: [Item] = [] {
        didSet { tableView.reloadData() }
    }

    var onSelectSession: ((Int) -> Void)?
    var onRenameSession: ((Int) -> Void)?
    var onKillSession: ((Int) -> Void)?
    var onNewSession: (() -> Void)?
    var onNewNamedSession: (() -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onSettings: (() -> Void)?

    private let titleLabel = UILabel()
    let tableView = UITableView(frame: .zero, style: .plain)
    private let buttonStack = UIStackView()
    private let settingsButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let newSessionButton = UIButton(type: .system)
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .systemBackground
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 2, height: 0)

        titleLabel.text = "Termux"
        titleLabel.font = UIFont.preferredFont(forTextStyle: .title2).withBoldTrait()
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "session")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.tableFooterView = UIView()
        addSubview(tableView)

        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        configure(settingsButton, title: "Settings", image: "gearshape", action: #selector(settingsTapped))
        configure(keyboardButton, title: "Keyboard", image: "keyboard", action: #selector(keyboardTapped))
        configure(newSessionButton, title: "New session", image: "plus", action: #selector(newSessionTapped))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(newSessionLongPressed(_:)))
        newSessionButton.addGestureRecognizer(longPress)

        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 4
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(settingsButton)
        buttonStack.addArrangedSubview(keyboardButton)
        buttonStack.addArrangedSubview(newSessionButton)
        addSubview(buttonStack)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

            separator.topAnchor.constraint(equalTo: tableView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            buttonStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            buttonStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 4),
            buttonStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -4),
            buttonStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -4),
            buttonStack.heightAnchor.constraint(equalToConstant: 56),
        ])

        accessibilityViewIsModal = true
    }

    private func configure(_ button: UIButton, title: String, image: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setImage(UIImage(systemName: image), for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = title
    }

    func setKeyboardButtonTitle(_ title: String) {
        keyboardButton.setTitle(title, for: .normal)
    }

    /// Scroll so that the current session is visible. Port of `checkAndScrollToSession()`.
    func scrollToCurrentSession() {
        guard let index = items.firstIndex(where: { $0.isCurrent }), index < tableView.numberOfRows(inSection: 0) else { return }
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .none, animated: false)
    }

    // MARK: Actions

    @objc private func settingsTapped() { onSettings?() }
    @objc private func keyboardTapped() { onToggleKeyboard?() }
    @objc private func newSessionTapped() { onNewSession?() }

    @objc private func newSessionLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            onNewNamedSession?()
        }
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "session", for: indexPath)
        let item = items[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.title
        content.textProperties.font = UIFont.monospacedSystemFont(ofSize: 15, weight: item.isCurrent ? .bold : .regular)
        if item.isRunning {
            content.secondaryText = item.subtitle
            content.textProperties.color = .label
        } else {
            content.secondaryText = "exited with code \(item.exitStatus)"
            content.textProperties.color = .systemRed
        }
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = item.isCurrent ? .checkmark : .none
        cell.backgroundColor = .clear
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectSession?(indexPath.row)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let kill = UIContextualAction(style: .destructive, title: "Kill") { [weak self] _, _, completion in
            self?.onKillSession?(indexPath.row)
            completion(true)
        }
        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
            self?.onRenameSession?(indexPath.row)
            completion(true)
        }
        rename.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [kill, rename])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let row = indexPath.row
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let rename = UIAction(title: "Rename session", image: UIImage(systemName: "pencil")) { _ in
                self?.onRenameSession?(row)
            }
            let kill = UIAction(title: "Kill session", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { _ in
                self?.onKillSession?(row)
            }
            return UIMenu(children: [rename, kill])
        }
    }
}

private extension UIFont {
    func withBoldTrait() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

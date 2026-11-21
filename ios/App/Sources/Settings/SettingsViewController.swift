import UIKit

/// The settings screen. iOS counterpart of `SettingsActivity` / `TermuxPreferencesFragment`:
/// font size, theme, bell vibration and access to the `~/.termux` configuration files.
final class SettingsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case appearance
        case terminal
        case configuration
        case about
    }

    private enum ConfigurationRow: Int, CaseIterable {
        case editProperties
        case editColors
        case reload
        case location
    }

    private let environment: TermuxEnvironment
    private var preferences: AppPreferences { return environment.preferences }

    private let fontSizeStepper = UIStepper()
    private let themeControl = UISegmentedControl(items: AppTheme.allCases.map { $0.displayName })
    private let bellSwitch = UISwitch()

    init(environment: TermuxEnvironment) {
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        fontSizeStepper.minimumValue = AppPreferences.MIN_FONT_SIZE
        fontSizeStepper.maximumValue = AppPreferences.MAX_FONT_SIZE
        fontSizeStepper.stepValue = AppPreferences.FONT_SIZE_STEP
        fontSizeStepper.value = preferences.fontSize
        fontSizeStepper.addTarget(self, action: #selector(fontSizeChanged), for: .valueChanged)

        themeControl.selectedSegmentIndex = AppTheme.allCases.firstIndex(of: preferences.theme) ?? 0
        themeControl.addTarget(self, action: #selector(themeChanged), for: .valueChanged)

        bellSwitch.isOn = preferences.bellVibrate
        bellSwitch.addTarget(self, action: #selector(bellChanged), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func fontSizeChanged() {
        preferences.fontSize = fontSizeStepper.value
        environment.preferencesDidChange()
        tableView.reloadRows(at: [IndexPath(row: 0, section: Section.appearance.rawValue)], with: .none)
    }

    @objc private func themeChanged() {
        let index = themeControl.selectedSegmentIndex
        guard index >= 0 && index < AppTheme.allCases.count else { return }
        preferences.theme = AppTheme.allCases[index]
        environment.preferencesDidChange()
    }

    @objc private func bellChanged() {
        preferences.bellVibrate = bellSwitch.isOn
        environment.preferencesDidChange()
    }

    // MARK: - Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .appearance: return 2
        case .terminal: return 1
        case .configuration: return ConfigurationRow.allCases.count
        case .about: return 2
        case .none: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .configuration: return "Configuration"
        case .about: return "About"
        case .none: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .appearance:
            return "Pinch the terminal to change the font size. \"System\" follows night-mode in termux.properties."
        case .terminal:
            return "Used when bell-character is \"vibrate\" (the default) in termux.properties."
        case .configuration:
            return "The home directory is shown in the Files app under On My iPhone/iPad › Termux › home. "
                + "The Files app hides folders starting with a dot, so ~/.termux is edited here or from the shell. "
                + "Settings are reloaded automatically when the files change. "
                + "A custom font can be installed as ~/.termux/font.ttf."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        cell.accessoryView = nil
        cell.accessoryType = .none

        switch Section(rawValue: indexPath.section) {
        case .appearance:
            if indexPath.row == 0 {
                content.text = "Font size"
                content.secondaryText = String(format: "%.0f pt", preferences.fontSize)
                cell.accessoryView = fontSizeStepper
            } else {
                content.text = "Theme"
                themeControl.sizeToFit()
                cell.accessoryView = themeControl
            }
        case .terminal:
            content.text = "Vibrate on bell"
            cell.accessoryView = bellSwitch
        case .configuration:
            switch ConfigurationRow(rawValue: indexPath.row) {
            case .editProperties:
                content.text = "Edit termux.properties"
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case .editColors:
                content.text = "Edit colors.properties"
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case .reload:
                content.text = "Reload settings"
                content.textProperties.color = .systemBlue
                cell.selectionStyle = .default
            case .location:
                content.text = "~/.termux"
                content.secondaryText = environment.paths.termuxConfigDirectory.path
                content.secondaryTextProperties.numberOfLines = 0
                content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption2)
                content.prefersSideBySideTextAndSecondaryText = false
            case .none:
                break
            }
        case .about:
            if indexPath.row == 0 {
                content.text = "Version"
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                content.secondaryText = "\(version) (\(build))"
            } else {
                content.text = "Shell"
                content.secondaryText = "Built-in (no packages)"
            }
        case .none:
            break
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .configuration else { return }
        switch ConfigurationRow(rawValue: indexPath.row) {
        case .editProperties:
            let editor = PropertiesEditorViewController(
                environment: environment, fileURL: environment.paths.propertiesFile,
                template: Bootstrap.defaultTermuxProperties)
            navigationController?.pushViewController(editor, animated: true)
        case .editColors:
            let editor = PropertiesEditorViewController(
                environment: environment, fileURL: environment.paths.colorsPropertiesFile,
                template: PropertiesEditorViewController.colorsTemplate)
            navigationController?.pushViewController(editor, animated: true)
        case .reload:
            environment.reloadSettings()
            let alert = UIAlertController(title: "Settings reloaded", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        default:
            break
        }
    }
}

/// A plain text editor for `termux.properties` and `colors.properties`.
final class PropertiesEditorViewController: UIViewController {

    static let colorsTemplate = """
    # Terminal colors, see https://wiki.termux.com/wiki/Terminal_Settings
    # Uncomment and change the values, then tap Save.
    # background=#000000
    # foreground=#ffffff
    # cursor=#ffffff
    # color0=#000000
    # color1=#cd0000
    # color2=#00cd00
    # color3=#cdcd00
    # color4=#6495ed
    # color5=#cd00cd
    # color6=#00cdcd
    # color7=#e5e5e5
    # color8=#7f7f7f
    # color9=#ff0000
    # color10=#00ff00
    # color11=#ffff00
    # color12=#5c5cff
    # color13=#ff00ff
    # color14=#00ffff
    # color15=#ffffff

    """

    private let environment: TermuxEnvironment
    private let fileURL: URL
    private let template: String
    private let textView = UITextView()

    init(environment: TermuxEnvironment, fileURL: URL, template: String) {
        self.environment = environment
        self.fileURL = fileURL
        self.template = template
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = fileURL.lastPathComponent
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) {
            textView.text = text
        } else {
            textView.text = template
        }
    }

    @objc private func saveTapped() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((textView.text ?? "").utf8).write(to: fileURL, options: .atomic)
            environment.reloadSettings()
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(title: "Could not save \(fileURL.lastPathComponent)",
                                          message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

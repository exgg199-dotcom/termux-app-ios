import Foundation
import TermuxTerminal

/// Global app state: paths, preferences, the parsed `termux.properties`, colors, font and the
/// session manager. Plays the role of `TermuxApplication` + the settings parts of `TermuxActivity`.
final class TermuxEnvironment {

    static let shared = TermuxEnvironment()

    /// Posted on the main queue after the settings were (re)loaded or a preference changed.
    static let settingsDidChangeNotification = Notification.Name("TermuxSettingsDidChange")

    /// Post this notification (on any queue) to reload the settings, e.g. from a
    /// `termux-reload-settings` shell builtin. Port of the `RELOAD_STYLE` broadcast.
    static let reloadSettingsNotification = Notification.Name("com.termux.app.reload_style")

    let paths: TermuxPaths
    let preferences: AppPreferences
    private(set) var properties = TermuxProperties()
    private(set) var extraKeysInfo: ExtraKeysInfo?
    /// An error loading the extra keys that should be shown to the user.
    private(set) var extraKeysError: String?
    /// Contents of `~/.termux/font.ttf`, if any.
    private(set) var customFontData: Data?
    /// An error during bootstrap, shown in the first session.
    private(set) var bootstrapError: String?

    private(set) lazy var sessionManager = SessionManager(environment: self)

    private var watcher: SettingsWatcher?
    private var didBootstrap = false

    init(paths: TermuxPaths = .appDefault(), preferences: AppPreferences = AppPreferences()) {
        self.paths = paths
        self.preferences = preferences
    }

    /// First launch setup and initial settings load. Safe to call multiple times.
    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try Bootstrap.run(paths: paths)
        } catch {
            bootstrapError = "Failed to set up the home directory: \(error.localizedDescription)"
            NSLog("Termux: %@", bootstrapError ?? "")
        }

        NotificationCenter.default.addObserver(forName: TermuxEnvironment.reloadSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadSettings()
        }

        watcher = SettingsWatcher { [weak self] in
            self?.reloadSettings()
        }
        reloadSettings()
    }

    /// Reload termux.properties, colors.properties and font.ttf. Port of
    /// `TermuxActivity.reloadActivityStyling()` / `checkForFontAndColors()`.
    func reloadSettings() {
        properties = TermuxProperties.load(from: paths.propertiesFile)
        for warning in properties.warnings {
            NSLog("Termux: termux.properties: %@", warning)
        }

        let extraKeys = ExtraKeysInfo.loadWithFallback(extraKeys: properties.extraKeys, style: properties.extraKeysStyle)
        extraKeysInfo = extraKeys.info
        extraKeysError = extraKeys.error

        // Colors: an empty map resets the scheme to the defaults.
        let colors = JavaPropertiesParser.parse(contentsOf: paths.colorsPropertiesFile) ?? [:]
        TerminalColors.colorScheme.updateWith(properties: colors)

        if let data = try? Data(contentsOf: paths.fontFile), !data.isEmpty {
            customFontData = data
        } else {
            customFontData = nil
        }

        for session in sessionManager.sessions {
            session.emulator?.colors.reset()
            // Re-reads the cursor style from the client (`terminal-cursor-style`).
            session.updateTerminalSessionClient(sessionManager)
        }

        restartWatcher()
        NotificationCenter.default.post(name: TermuxEnvironment.settingsDidChangeNotification, object: self)
    }

    /// Notify observers that a preference changed (font size, theme, ...).
    func preferencesDidChange() {
        NotificationCenter.default.post(name: TermuxEnvironment.settingsDidChangeNotification, object: self)
    }

    private func restartWatcher() {
        let fm = FileManager.default
        let candidates = [
            paths.termuxConfigDirectory,
            paths.termuxConfigDirectory2,
            paths.primaryPropertiesFile,
            paths.secondaryPropertiesFile,
            paths.colorsPropertiesFile,
            paths.fontFile,
        ]
        watcher?.watch(candidates.filter { fm.fileExists(atPath: $0.path) })
    }

    /// The environment variables for new shells.
    func shellEnvironment() -> [String: String] {
        var env: [String: String] = [
            "HOME": paths.homeDirectory.path,
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8",
            "TERMUX_APP": "ios",
            "TERMUX_VERSION": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        ]
        if let dir = properties.defaultWorkingDirectory {
            let expanded: String
            if dir == "~" {
                expanded = paths.homeDirectory.path
            } else if dir.hasPrefix("~/") {
                expanded = paths.homeDirectory.appendingPathComponent(String(dir.dropFirst(2))).path
            } else if dir.hasPrefix("/") {
                expanded = dir
            } else {
                expanded = paths.homeDirectory.appendingPathComponent(dir).path
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                env["PWD"] = expanded
            }
        }
        return env
    }
}

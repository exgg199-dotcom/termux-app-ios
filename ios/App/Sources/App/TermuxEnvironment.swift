import Foundation
import Combine
import TermuxTerminal

final class TermuxEnvironment: ObservableObject {
    static let shared = TermuxEnvironment()

    static let settingsDidChangeNotification = Notification.Name("TermuxSettingsDidChange")

    static let reloadSettingsNotification = Notification.Name("com.termux.app.reload_style")

    let paths: TermuxPaths
    let preferences: AppPreferences
    @Published private(set) var properties = TermuxProperties()
    @Published private(set) var settingsRevision = 0
    private(set) var extraKeysInfo: ExtraKeysInfo?
    private(set) var extraKeysError: String?
    private(set) var customFontData: Data?
    private(set) var bootstrapError: String?

    private(set) lazy var sessionManager = SessionManager(environment: self)

    private var watcher: SettingsWatcher?
    private var reloadObserver: NSObjectProtocol?
    private var didBootstrap = false

    init(paths: TermuxPaths = .appDefault(), preferences: AppPreferences = AppPreferences()) {
        self.paths = paths
        self.preferences = preferences
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try Bootstrap.run(paths: paths)
        } catch {
            let message = "Failed to set up the home directory: \(error.localizedDescription)"
            bootstrapError = message
            NSLog("Termux: %@", message)
        }

        reloadObserver = NotificationCenter.default.addObserver(
            forName: TermuxEnvironment.reloadSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadSettings()
        }

        watcher = SettingsWatcher { [weak self] in
            self?.reloadSettings()
        }
        reloadSettings()
    }

    func reloadSettings() {
        let loadedProperties = TermuxProperties.load(from: paths.propertiesFile)
        for warning in loadedProperties.warnings {
            NSLog("Termux: termux.properties: %@", warning)
        }

        let extraKeys = ExtraKeysInfo.loadWithFallback(extraKeys: loadedProperties.extraKeys, style: loadedProperties.extraKeysStyle)
        extraKeysInfo = extraKeys.info
        extraKeysError = extraKeys.error

        let colors = JavaPropertiesParser.parse(contentsOf: paths.colorsPropertiesFile) ?? [:]
        TerminalColors.colorScheme.updateWith(properties: colors)

        if let data = try? Data(contentsOf: paths.fontFile), !data.isEmpty {
            customFontData = data
        } else {
            customFontData = nil
        }

        properties = loadedProperties

        for session in sessionManager.sessions {
            session.emulator?.colors.reset()
            session.updateTerminalSessionClient(sessionManager)
        }

        restartWatcher()
        notifySettingsChanged()
    }

    func preferencesDidChange() {
        notifySettingsChanged()
    }

    private func notifySettingsChanged() {
        settingsRevision += 1
        NotificationCenter.default.post(name: TermuxEnvironment.settingsDidChangeNotification, object: self)
    }

    private func restartWatcher() {
        let fileManager = FileManager.default
        let candidates = [
            paths.termuxConfigDirectory,
            paths.termuxConfigDirectory2,
            paths.primaryPropertiesFile,
            paths.secondaryPropertiesFile,
            paths.colorsPropertiesFile,
            paths.fontFile,
        ]
        watcher?.watch(candidates.filter { fileManager.fileExists(atPath: $0.path) })
    }

    func shellEnvironment() -> [String: String] {
        var environmentVariables: [String: String] = [
            "HOME": paths.homeDirectory.path,
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8",
            "TERMUX_APP": "ios",
            "TERMUX_VERSION": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        ]
        if let directory = properties.defaultWorkingDirectory {
            let expanded: String
            if directory == "~" {
                expanded = paths.homeDirectory.path
            } else if directory.hasPrefix("~/") {
                expanded = paths.homeDirectory.appendingPathComponent(String(directory.dropFirst(2))).path
            } else if directory.hasPrefix("/") {
                expanded = directory
            } else {
                expanded = paths.homeDirectory.appendingPathComponent(directory).path
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                environmentVariables["PWD"] = expanded
            }
        }
        return environmentVariables
    }
}

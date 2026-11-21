import Foundation

/// The UI theme of the app chrome (drawer, extra keys, settings). The terminal colors themselves
/// come from `~/.termux/colors.properties`.
public enum AppTheme: String, CaseIterable {
    /// Follow `night-mode` in termux.properties, which defaults to the system appearance.
    case system
    case light
    case dark
    /// Dark with pure black backgrounds (`use-black-ui`).
    case black

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .black: return "Black"
        }
    }
}

/// App preferences stored in `UserDefaults`. Port of the relevant parts of
/// `TermuxAppSharedPreferences` (font size, soft keyboard enabled) plus iOS specific settings.
public final class AppPreferences {

    public static let MIN_FONT_SIZE: Double = 6
    public static let MAX_FONT_SIZE: Double = 40
    public static let DEFAULT_FONT_SIZE: Double = 12
    /// The step used by pinch zoom and the font size shortcuts.
    public static let FONT_SIZE_STEP: Double = 1

    private enum Keys {
        static let fontSize = "terminal_font_size"
        static let theme = "app_theme"
        static let bellVibrate = "bell_vibrate"
        static let softKeyboardEnabled = "soft_keyboard_enabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Terminal font size in points.
    public var fontSize: Double {
        get {
            let value = defaults.double(forKey: Keys.fontSize)
            return value > 0 ? AppPreferences.clampFontSize(value) : AppPreferences.DEFAULT_FONT_SIZE
        }
        set { defaults.set(AppPreferences.clampFontSize(newValue), forKey: Keys.fontSize) }
    }

    public static func clampFontSize(_ size: Double) -> Double {
        return min(MAX_FONT_SIZE, max(MIN_FONT_SIZE, size))
    }

    /// Port of `TermuxAppSharedPreferences.changeFontSize()`.
    @discardableResult
    public func changeFontSize(increase: Bool) -> Double {
        let newSize = AppPreferences.clampFontSize(fontSize + (increase ? 1 : -1) * AppPreferences.FONT_SIZE_STEP)
        fontSize = newSize
        return newSize
    }

    public var theme: AppTheme {
        get { return AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.theme) }
    }

    /// Haptic feedback for the bell character (when `bell-character=vibrate`).
    public var bellVibrate: Bool {
        get { return defaults.object(forKey: Keys.bellVibrate) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.bellVibrate) }
    }

    /// If the soft keyboard is enabled (toggled with the KEYBOARD extra key / drawer button).
    public var softKeyboardEnabled: Bool {
        get { return defaults.object(forKey: Keys.softKeyboardEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.softKeyboardEnabled) }
    }
}

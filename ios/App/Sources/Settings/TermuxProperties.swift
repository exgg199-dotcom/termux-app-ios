import Foundation

// Port of `com.termux.shared.termux.settings.properties.TermuxPropertyConstants`,
// `TermuxSharedProperties` and `SharedProperties` (the subset that makes sense on iOS), plus a
// `java.util.Properties.load()` compatible parser.
//
// UIKit-free so that it can be unit tested on any platform.

/// Parser for the `java.util.Properties` text format used by `termux.properties` and
/// `colors.properties`.
public enum JavaPropertiesParser {

    /// Parse properties text. Port of `java.util.Properties.load(Reader)`:
    ///
    /// * `#` and `!` start comment lines, blank lines are ignored.
    /// * A line ending with an odd number of backslashes continues on the next line (leading
    ///   whitespace of the continuation line is skipped).
    /// * The key ends at the first unescaped `=`, `:` or whitespace; whitespace and one `=`/`:`
    ///   after the key are skipped.
    /// * Escapes `\t`, `\n`, `\r`, `\f`, `\uXXXX` and `\<char>` are supported in keys and values.
    ///
    /// Later definitions of a key replace earlier ones, like in Java.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for logicalLine in logicalLines(text) {
            let (key, value) = splitKeyValue(logicalLine)
            result[key] = value
        }
        return result
    }

    /// Parse a properties file, returns `nil` if it can't be read.
    public static func parse(contentsOf url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Java reads termux.properties as UTF-8, fall back to Latin-1 for invalid data.
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    private static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        return c == " " || c == "\t" || c == "\u{0C}"
    }

    /// Split the text into logical lines (comments and blank lines removed, continuations joined).
    /// The returned lines still contain their escape sequences.
    static func logicalLines(_ text: String) -> [[Unicode.Scalar]] {
        // Split into natural lines on \n, \r and \r\n.
        var naturalLines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var previousWasCR = false
        for c in text.unicodeScalars {
            if c == "\n" {
                if previousWasCR {
                    previousWasCR = false
                    continue
                }
                naturalLines.append(current)
                current = []
            } else if c == "\r" {
                naturalLines.append(current)
                current = []
                previousWasCR = true
                continue
            } else {
                current.append(c)
            }
            previousWasCR = false
        }
        naturalLines.append(current)

        var result: [[Unicode.Scalar]] = []
        var index = 0
        while index < naturalLines.count {
            var line = Array(naturalLines[index].drop(while: isWhitespace))
            index += 1
            if line.isEmpty { continue }
            if line[0] == "#" || line[0] == "!" { continue }

            var logical: [Unicode.Scalar] = []
            while true {
                // Count trailing backslashes.
                var backslashes = 0
                var i = line.count - 1
                while i >= 0 && line[i] == "\\" {
                    backslashes += 1
                    i -= 1
                }
                if backslashes % 2 == 1 {
                    logical.append(contentsOf: line.dropLast())
                    if index < naturalLines.count {
                        line = Array(naturalLines[index].drop(while: isWhitespace))
                        index += 1
                        continue
                    }
                    break
                } else {
                    logical.append(contentsOf: line)
                    break
                }
            }
            result.append(logical)
        }
        return result
    }

    static func splitKeyValue(_ line: [Unicode.Scalar]) -> (String, String) {
        var keyLen = 0
        var valueStart = line.count
        var hasSep = false
        var precedingBackslash = false
        while keyLen < line.count {
            let c = line[keyLen]
            if (c == "=" || c == ":") && !precedingBackslash {
                valueStart = keyLen + 1
                hasSep = true
                break
            } else if isWhitespace(c) && !precedingBackslash {
                valueStart = keyLen + 1
                break
            }
            if c == "\\" {
                precedingBackslash = !precedingBackslash
            } else {
                precedingBackslash = false
            }
            keyLen += 1
        }
        while valueStart < line.count {
            let c = line[valueStart]
            if !isWhitespace(c) {
                if !hasSep && (c == "=" || c == ":") {
                    hasSep = true
                } else {
                    break
                }
            }
            valueStart += 1
        }
        let key = unescape(Array(line[0..<keyLen]))
        let value = valueStart < line.count ? unescape(Array(line[valueStart...])) : ""
        return (key, value)
    }

    static func unescape(_ chars: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            if c != "\\" {
                out.append(c)
                continue
            }
            guard i < chars.count else { break }
            let e = chars[i]
            i += 1
            switch e {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "f": out.append("\u{0C}")
            case "u":
                var value: UInt32 = 0
                var digits = 0
                while digits < 4 && i < chars.count, let d = hexValue(chars[i]) {
                    value = value * 16 + d
                    digits += 1
                    i += 1
                }
                if digits == 4, let scalar = Unicode.Scalar(value) {
                    out.append(scalar)
                }
            default:
                out.append(e)
            }
        }
        return String(out)
    }

    private static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
        switch c.value {
        case 0x30...0x39: return c.value - 0x30
        case 0x41...0x46: return c.value - 0x41 + 10
        case 0x61...0x66: return c.value - 0x61 + 10
        default: return nil
        }
    }
}

/// The location of the Termux files inside the app sandbox.
public struct TermuxPaths {
    /// The app's Documents directory, exposed in the Files app (UIFileSharingEnabled).
    public let documentsDirectory: URL
    /// `$HOME`, i.e. `Documents/home`.
    public let homeDirectory: URL

    public init(documentsDirectory: URL) {
        self.documentsDirectory = documentsDirectory
        self.homeDirectory = documentsDirectory.appendingPathComponent("home", isDirectory: true)
    }

    /// The paths for the app's real Documents directory.
    public static func appDefault() -> TermuxPaths {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return TermuxPaths(documentsDirectory: documents)
    }

    /// `~/.termux`
    public var termuxConfigDirectory: URL { return homeDirectory.appendingPathComponent(".termux", isDirectory: true) }
    /// `~/.config/termux`
    public var termuxConfigDirectory2: URL {
        return homeDirectory.appendingPathComponent(".config", isDirectory: true).appendingPathComponent("termux", isDirectory: true)
    }
    /// `~/.termux/termux.properties`
    public var primaryPropertiesFile: URL { return termuxConfigDirectory.appendingPathComponent("termux.properties") }
    /// `~/.config/termux/termux.properties`
    public var secondaryPropertiesFile: URL { return termuxConfigDirectory2.appendingPathComponent("termux.properties") }
    /// `~/.termux/colors.properties`
    public var colorsPropertiesFile: URL { return termuxConfigDirectory.appendingPathComponent("colors.properties") }
    /// `~/.termux/font.ttf`
    public var fontFile: URL { return termuxConfigDirectory.appendingPathComponent("font.ttf") }
    /// `~/.termux/motd`: replaces the built-in message of the day if it exists.
    public var motdFile: URL { return termuxConfigDirectory.appendingPathComponent("motd") }
    /// `~/.hushlogin`: suppresses the message of the day, like in Termux.
    public var hushLoginFile: URL { return homeDirectory.appendingPathComponent(".hushlogin") }

    /// The termux.properties file that is used: like Termux, `~/.termux/termux.properties` if it
    /// exists, otherwise `~/.config/termux/termux.properties`.
    public var propertiesFile: URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: primaryPropertiesFile.path) { return primaryPropertiesFile }
        if fm.fileExists(atPath: secondaryPropertiesFile.path) { return secondaryPropertiesFile }
        return primaryPropertiesFile
    }

    /// Display a path relative to `$HOME` as `~/...`.
    public func displayPath(_ url: URL) -> String {
        let home = homeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// The bell behaviour (`bell-character`).
public enum BellBehaviour: String, CaseIterable {
    case vibrate
    case beep
    case ignore
}

/// The soft keyboard toggle behaviour (`soft-keyboard-toggle-behaviour`).
public enum SoftKeyboardToggleBehaviour: String {
    case showHide = "show/hide"
    case enableDisable = "enable/disable"
}

/// Actions for `shortcut.*` session shortcuts.
public enum SessionShortcutAction: Int {
    case createSession = 1
    case nextSession = 2
    case previousSession = 3
    case renameSession = 4
}

public struct SessionShortcut: Equatable {
    public let codePoint: Int
    public let action: SessionShortcutAction
}

/// Typed values of `termux.properties`. Port of `TermuxSharedProperties` /
/// `TermuxPropertyConstants`, restricted to the properties that make sense on iOS.
public struct TermuxProperties {

    // MARK: Keys

    public static let KEY_EXTRA_KEYS = "extra-keys"
    public static let KEY_EXTRA_KEYS_STYLE = "extra-keys-style"
    public static let KEY_EXTRA_KEYS_TEXT_ALL_CAPS = "extra-keys-text-all-caps"
    public static let KEY_BELL_BEHAVIOUR = "bell-character"
    public static let KEY_TERMINAL_TRANSCRIPT_ROWS = "terminal-transcript-rows"
    public static let KEY_TERMINAL_CURSOR_STYLE = "terminal-cursor-style"
    public static let KEY_TERMINAL_CURSOR_BLINK_RATE = "terminal-cursor-blink-rate"
    public static let KEY_TERMINAL_MARGIN_HORIZONTAL = "terminal-margin-horizontal"
    public static let KEY_TERMINAL_MARGIN_VERTICAL = "terminal-margin-vertical"
    public static let KEY_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR = "terminal-toolbar-height"
    public static let KEY_TERMINAL_ONCLICK_URL_OPEN = "terminal-onclick-url-open"
    public static let KEY_USE_BLACK_UI = "use-black-ui"
    public static let KEY_NIGHT_MODE = "night-mode"
    public static let KEY_USE_FULLSCREEN = "fullscreen"
    public static let KEY_HIDE_SOFT_KEYBOARD_ON_STARTUP = "hide-soft-keyboard-on-startup"
    public static let KEY_SOFT_KEYBOARD_TOGGLE_BEHAVIOUR = "soft-keyboard-toggle-behaviour"
    public static let KEY_DISABLE_HARDWARE_KEYBOARD_SHORTCUTS = "disable-hardware-keyboard-shortcuts"
    public static let KEY_DISABLE_TERMINAL_SESSION_CHANGE_TOAST = "disable-terminal-session-change-toast"
    public static let KEY_DEFAULT_WORKING_DIRECTORY = "default-working-directory"
    public static let KEY_SHORTCUT_CREATE_SESSION = "shortcut.create-session"
    public static let KEY_SHORTCUT_NEXT_SESSION = "shortcut.next-session"
    public static let KEY_SHORTCUT_PREVIOUS_SESSION = "shortcut.previous-session"
    public static let KEY_SHORTCUT_RENAME_SESSION = "shortcut.rename-session"

    // MARK: Ranges and defaults

    /// `TerminalEmulator.TERMINAL_CURSOR_STYLE_*` values.
    public static let TERMINAL_CURSOR_STYLE_BLOCK = 0
    public static let TERMINAL_CURSOR_STYLE_UNDERLINE = 1
    public static let TERMINAL_CURSOR_STYLE_BAR = 2
    public static let MAP_TERMINAL_CURSOR_STYLE: [String: Int] = [
        "block": TERMINAL_CURSOR_STYLE_BLOCK,
        "underline": TERMINAL_CURSOR_STYLE_UNDERLINE,
        "bar": TERMINAL_CURSOR_STYLE_BAR,
    ]
    public static let DEFAULT_IVALUE_TERMINAL_CURSOR_STYLE = TERMINAL_CURSOR_STYLE_BLOCK

    /// `TerminalView.TERMINAL_CURSOR_BLINK_RATE_MIN/MAX`, 0 disables blinking.
    public static let IVALUE_TERMINAL_CURSOR_BLINK_RATE_MIN = 100
    public static let IVALUE_TERMINAL_CURSOR_BLINK_RATE_MAX = 2000
    public static let DEFAULT_IVALUE_TERMINAL_CURSOR_BLINK_RATE = 0

    /// `TerminalEmulator.TERMINAL_TRANSCRIPT_ROWS_MIN/MAX`, `DEFAULT_TERMINAL_TRANSCRIPT_ROWS`.
    public static let IVALUE_TERMINAL_TRANSCRIPT_ROWS_MIN = 100
    public static let IVALUE_TERMINAL_TRANSCRIPT_ROWS_MAX = 50000
    public static let DEFAULT_IVALUE_TERMINAL_TRANSCRIPT_ROWS = 2000

    public static let IVALUE_TERMINAL_MARGIN_HORIZONTAL_MIN = 0
    public static let IVALUE_TERMINAL_MARGIN_HORIZONTAL_MAX = 100
    public static let DEFAULT_IVALUE_TERMINAL_MARGIN_HORIZONTAL = 3
    public static let IVALUE_TERMINAL_MARGIN_VERTICAL_MIN = 0
    public static let IVALUE_TERMINAL_MARGIN_VERTICAL_MAX = 100
    public static let DEFAULT_IVALUE_TERMINAL_MARGIN_VERTICAL = 0

    public static let IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR_MIN = 0.4
    public static let IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR_MAX = 3.0
    public static let DEFAULT_IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR = 1.0

    public static let DEFAULT_IVALUE_EXTRA_KEYS = ExtraKeysInfo.DEFAULT_EXTRA_KEYS
    public static let DEFAULT_IVALUE_EXTRA_KEYS_STYLE = ExtraKeysInfo.DEFAULT_EXTRA_KEYS_STYLE

    // MARK: Values

    /// The raw key/value pairs read from the file.
    public let rawProperties: [String: String]

    public var extraKeys: String
    public var extraKeysStyle: String
    public var extraKeysTextAllCaps: Bool
    public var bellBehaviour: BellBehaviour
    public var terminalTranscriptRows: Int
    public var terminalCursorStyle: Int
    public var terminalCursorBlinkRate: Int
    public var terminalMarginHorizontal: Int
    public var terminalMarginVertical: Int
    public var terminalToolbarHeightScaleFactor: Double
    public var terminalOnclickUrlOpen: Bool
    /// `night-mode`: "true", "false" or "system" (`use-black-ui=true` maps to "true").
    public var nightMode: String
    public var fullscreen: Bool
    public var hideSoftKeyboardOnStartup: Bool
    public var softKeyboardToggleBehaviour: SoftKeyboardToggleBehaviour
    public var hardwareKeyboardShortcutsDisabled: Bool
    public var terminalSessionChangeToastDisabled: Bool
    public var defaultWorkingDirectory: String?
    public var sessionShortcuts: [SessionShortcut]
    /// Problems found while parsing, to be logged or shown to the user.
    public var warnings: [String] = []

    /// The defaults (no termux.properties file).
    public init() {
        self.init(properties: [:])
    }

    public init(properties: [String: String]) {
        rawProperties = properties
        var warnings: [String] = []

        func string(_ key: String) -> String? {
            guard let value = properties[key] else { return nil }
            return value
        }

        func bool(_ key: String, default def: Bool) -> Bool {
            guard let value = string(key) else { return def }
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default:
                warnings.append("The value \"\(value)\" for the key \"\(key)\" is invalid, using \(def).")
                return def
            }
        }

        func int(_ key: String, default def: Int, min: Int, max: Int, allowZero: Bool = false) -> Int {
            guard let value = string(key) else { return def }
            guard let parsed = Int(value.trimmingCharacters(in: .whitespaces)) else {
                warnings.append("The value \"\(value)\" for the key \"\(key)\" is not an integer, using \(def).")
                return def
            }
            if allowZero && parsed == 0 { return 0 }
            if parsed < min || parsed > max {
                warnings.append("The value \"\(value)\" for the key \"\(key)\" is not between \(min) and \(max), using \(def).")
                return def
            }
            return parsed
        }

        // extra-keys / extra-keys-style: the value itself if not empty, otherwise the default.
        if let value = string(TermuxProperties.KEY_EXTRA_KEYS), !value.isEmpty {
            extraKeys = value
        } else {
            extraKeys = TermuxProperties.DEFAULT_IVALUE_EXTRA_KEYS
        }
        if let value = string(TermuxProperties.KEY_EXTRA_KEYS_STYLE), !value.isEmpty {
            extraKeysStyle = value
        } else {
            extraKeysStyle = TermuxProperties.DEFAULT_IVALUE_EXTRA_KEYS_STYLE
        }
        extraKeysTextAllCaps = bool(TermuxProperties.KEY_EXTRA_KEYS_TEXT_ALL_CAPS, default: true)

        if let value = string(TermuxProperties.KEY_BELL_BEHAVIOUR) {
            if let behaviour = BellBehaviour(rawValue: value.lowercased()) {
                bellBehaviour = behaviour
            } else {
                warnings.append("The value \"\(value)\" for the key \"\(TermuxProperties.KEY_BELL_BEHAVIOUR)\" is invalid, using \"vibrate\".")
                bellBehaviour = .vibrate
            }
        } else {
            bellBehaviour = .vibrate
        }

        terminalTranscriptRows = int(TermuxProperties.KEY_TERMINAL_TRANSCRIPT_ROWS,
                                     default: TermuxProperties.DEFAULT_IVALUE_TERMINAL_TRANSCRIPT_ROWS,
                                     min: TermuxProperties.IVALUE_TERMINAL_TRANSCRIPT_ROWS_MIN,
                                     max: TermuxProperties.IVALUE_TERMINAL_TRANSCRIPT_ROWS_MAX)

        if let value = string(TermuxProperties.KEY_TERMINAL_CURSOR_STYLE) {
            if let style = TermuxProperties.MAP_TERMINAL_CURSOR_STYLE[value.lowercased()] {
                terminalCursorStyle = style
            } else {
                warnings.append("The value \"\(value)\" for the key \"\(TermuxProperties.KEY_TERMINAL_CURSOR_STYLE)\" is invalid, using \"block\".")
                terminalCursorStyle = TermuxProperties.DEFAULT_IVALUE_TERMINAL_CURSOR_STYLE
            }
        } else {
            terminalCursorStyle = TermuxProperties.DEFAULT_IVALUE_TERMINAL_CURSOR_STYLE
        }

        terminalCursorBlinkRate = int(TermuxProperties.KEY_TERMINAL_CURSOR_BLINK_RATE,
                                      default: TermuxProperties.DEFAULT_IVALUE_TERMINAL_CURSOR_BLINK_RATE,
                                      min: TermuxProperties.IVALUE_TERMINAL_CURSOR_BLINK_RATE_MIN,
                                      max: TermuxProperties.IVALUE_TERMINAL_CURSOR_BLINK_RATE_MAX,
                                      allowZero: true)

        terminalMarginHorizontal = int(TermuxProperties.KEY_TERMINAL_MARGIN_HORIZONTAL,
                                       default: TermuxProperties.DEFAULT_IVALUE_TERMINAL_MARGIN_HORIZONTAL,
                                       min: TermuxProperties.IVALUE_TERMINAL_MARGIN_HORIZONTAL_MIN,
                                       max: TermuxProperties.IVALUE_TERMINAL_MARGIN_HORIZONTAL_MAX)
        terminalMarginVertical = int(TermuxProperties.KEY_TERMINAL_MARGIN_VERTICAL,
                                     default: TermuxProperties.DEFAULT_IVALUE_TERMINAL_MARGIN_VERTICAL,
                                     min: TermuxProperties.IVALUE_TERMINAL_MARGIN_VERTICAL_MIN,
                                     max: TermuxProperties.IVALUE_TERMINAL_MARGIN_VERTICAL_MAX)

        if let value = string(TermuxProperties.KEY_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR) {
            if let parsed = Double(value.trimmingCharacters(in: .whitespaces)),
               parsed >= TermuxProperties.IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR_MIN,
               parsed <= TermuxProperties.IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR_MAX {
                terminalToolbarHeightScaleFactor = parsed
            } else {
                warnings.append("The value \"\(value)\" for the key \"\(TermuxProperties.KEY_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR)\" is invalid, using 1.")
                terminalToolbarHeightScaleFactor = TermuxProperties.DEFAULT_IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR
            }
        } else {
            terminalToolbarHeightScaleFactor = TermuxProperties.DEFAULT_IVALUE_TERMINAL_TOOLBAR_HEIGHT_SCALE_FACTOR
        }

        terminalOnclickUrlOpen = bool(TermuxProperties.KEY_TERMINAL_ONCLICK_URL_OPEN, default: false)

        // night-mode, with the deprecated use-black-ui as fallback.
        if let value = string(TermuxProperties.KEY_NIGHT_MODE), ["true", "false", "system"].contains(value.lowercased()) {
            nightMode = value.lowercased()
        } else {
            if let value = string(TermuxProperties.KEY_NIGHT_MODE) {
                warnings.append("The value \"\(value)\" for the key \"\(TermuxProperties.KEY_NIGHT_MODE)\" is invalid, using \"system\".")
            }
            if let black = string(TermuxProperties.KEY_USE_BLACK_UI)?.lowercased(), black == "true" || black == "false" {
                nightMode = black
            } else {
                nightMode = "system"
            }
        }

        fullscreen = bool(TermuxProperties.KEY_USE_FULLSCREEN, default: false)
        hideSoftKeyboardOnStartup = bool(TermuxProperties.KEY_HIDE_SOFT_KEYBOARD_ON_STARTUP, default: false)
        if let value = string(TermuxProperties.KEY_SOFT_KEYBOARD_TOGGLE_BEHAVIOUR),
           let behaviour = SoftKeyboardToggleBehaviour(rawValue: value.lowercased()) {
            softKeyboardToggleBehaviour = behaviour
        } else {
            softKeyboardToggleBehaviour = .showHide
        }
        hardwareKeyboardShortcutsDisabled = bool(TermuxProperties.KEY_DISABLE_HARDWARE_KEYBOARD_SHORTCUTS, default: false)
        terminalSessionChangeToastDisabled = bool(TermuxProperties.KEY_DISABLE_TERMINAL_SESSION_CHANGE_TOAST, default: false)

        if let value = string(TermuxProperties.KEY_DEFAULT_WORKING_DIRECTORY), !value.isEmpty {
            defaultWorkingDirectory = value
        } else {
            defaultWorkingDirectory = nil
        }

        var shortcuts: [SessionShortcut] = []
        let shortcutKeys: [(String, SessionShortcutAction)] = [
            (TermuxProperties.KEY_SHORTCUT_CREATE_SESSION, .createSession),
            (TermuxProperties.KEY_SHORTCUT_NEXT_SESSION, .nextSession),
            (TermuxProperties.KEY_SHORTCUT_PREVIOUS_SESSION, .previousSession),
            (TermuxProperties.KEY_SHORTCUT_RENAME_SESSION, .renameSession),
        ]
        for (key, action) in shortcutKeys {
            guard let value = string(key) else { continue }
            if let codePoint = TermuxProperties.getCodePointForSessionShortcuts(value) {
                shortcuts.append(SessionShortcut(codePoint: codePoint, action: action))
            } else {
                warnings.append("Keyboard shortcut '\(key)' is not Ctrl+<something>")
            }
        }
        sessionShortcuts = shortcuts
        self.warnings = warnings
    }

    /// Port of `TermuxSharedProperties.getCodePointForSessionShortcuts()`: parse "ctrl + t".
    public static func getCodePointForSessionShortcuts(_ value: String) -> Int? {
        let parts = value.lowercased().trimmingCharacters(in: .whitespaces).components(separatedBy: "+")
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "ctrl" else { return nil }
        let input = parts[1].trimmingCharacters(in: .whitespaces)
        let scalars = Array(input.unicodeScalars)
        guard scalars.count == 1 else { return nil }
        return Int(scalars[0].value)
    }

    /// Load the properties from a file. A missing or unreadable file gives the defaults.
    public static func load(from url: URL) -> TermuxProperties {
        guard let properties = JavaPropertiesParser.parse(contentsOf: url) else {
            return TermuxProperties()
        }
        return TermuxProperties(properties: properties)
    }

    /// The session shortcut action for a code point typed with ctrl, if any.
    public func sessionShortcutAction(forCodePoint codePoint: Int) -> SessionShortcutAction? {
        let lower = TerminalInputLowercase.lowercase(codePoint)
        // Later shortcuts take precedence like in TermuxTerminalViewClient.
        for shortcut in sessionShortcuts.reversed() where shortcut.codePoint == lower {
            return shortcut.action
        }
        return nil
    }
}

enum TerminalInputLowercase {
    static func lowercase(_ codePoint: Int) -> Int {
        guard let scalar = Unicode.Scalar(UInt32(clamping: max(0, codePoint))) else { return codePoint }
        let lower = String(Character(scalar)).lowercased().unicodeScalars
        if lower.count == 1, let first = lower.first { return Int(first.value) }
        return codePoint
    }
}

import Foundation

public enum JavaPropertiesParser {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for logicalLine in logicalLines(text) {
            let (key, value) = splitKeyValue(logicalLine)
            result[key] = value
        }
        return result
    }

    public static func parse(contentsOf url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    private static func isWhitespace(_ character: Unicode.Scalar) -> Bool {
        return character == " " || character == "\t" || character == "\u{0C}"
    }

    static func logicalLines(_ text: String) -> [[Unicode.Scalar]] {
        var naturalLines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var previousWasCR = false
        for character in text.unicodeScalars {
            if character == "\n" {
                if previousWasCR {
                    previousWasCR = false
                    continue
                }
                naturalLines.append(current)
                current = []
            } else if character == "\r" {
                naturalLines.append(current)
                current = []
                previousWasCR = true
                continue
            } else {
                current.append(character)
            }
            previousWasCR = false
        }
        naturalLines.append(current)

        var result: [[Unicode.Scalar]] = []
        var lineIndex = 0
        while lineIndex < naturalLines.count {
            var line = Array(naturalLines[lineIndex].drop(while: isWhitespace))
            lineIndex += 1
            if line.isEmpty { continue }
            if line[0] == "#" || line[0] == "!" { continue }

            var logical: [Unicode.Scalar] = []
            while true {
                var backslashes = 0
                var backslashIndex = line.count - 1
                while backslashIndex >= 0 && line[backslashIndex] == "\\" {
                    backslashes += 1
                    backslashIndex -= 1
                }
                if backslashes % 2 == 1 {
                    logical.append(contentsOf: line.dropLast())
                    if lineIndex < naturalLines.count {
                        line = Array(naturalLines[lineIndex].drop(while: isWhitespace))
                        lineIndex += 1
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
        var keyLength = 0
        var valueStart = line.count
        var hasSeparator = false
        var precedingBackslash = false
        while keyLength < line.count {
            let character = line[keyLength]
            if (character == "=" || character == ":") && !precedingBackslash {
                valueStart = keyLength + 1
                hasSeparator = true
                break
            } else if isWhitespace(character) && !precedingBackslash {
                valueStart = keyLength + 1
                break
            }
            if character == "\\" {
                precedingBackslash = !precedingBackslash
            } else {
                precedingBackslash = false
            }
            keyLength += 1
        }
        while valueStart < line.count {
            let character = line[valueStart]
            if !isWhitespace(character) {
                if !hasSeparator && (character == "=" || character == ":") {
                    hasSeparator = true
                } else {
                    break
                }
            }
            valueStart += 1
        }
        let key = unescape(Array(line[0..<keyLength]))
        let value = valueStart < line.count ? unescape(Array(line[valueStart...])) : ""
        return (key, value)
    }

    static func unescape(_ characters: [Unicode.Scalar]) -> String {
        var output = String.UnicodeScalarView()
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character != "\\" {
                output.append(character)
                continue
            }
            guard index < characters.count else { break }
            let escaped = characters[index]
            index += 1
            switch escaped {
            case "t": output.append("\t")
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "f": output.append("\u{0C}")
            case "u":
                var value: UInt32 = 0
                var digits = 0
                while digits < 4 && index < characters.count, let digit = hexValue(characters[index]) {
                    value = value * 16 + digit
                    digits += 1
                    index += 1
                }
                if digits == 4, let scalar = Unicode.Scalar(value) {
                    output.append(scalar)
                }
            default:
                output.append(escaped)
            }
        }
        return String(output)
    }

    private static func hexValue(_ character: Unicode.Scalar) -> UInt32? {
        switch character.value {
        case 0x30...0x39: return character.value - 0x30
        case 0x41...0x46: return character.value - 0x41 + 10
        case 0x61...0x66: return character.value - 0x61 + 10
        default: return nil
        }
    }
}

public struct TermuxPaths {
    public let documentsDirectory: URL
    public let homeDirectory: URL

    public init(documentsDirectory: URL) {
        self.documentsDirectory = documentsDirectory
        self.homeDirectory = documentsDirectory.appendingPathComponent("home", isDirectory: true)
    }

    public static func appDefault() -> TermuxPaths {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return TermuxPaths(documentsDirectory: documents)
    }

    public var termuxConfigDirectory: URL { return homeDirectory.appendingPathComponent(".termux", isDirectory: true) }
    public var termuxConfigDirectory2: URL {
        return homeDirectory.appendingPathComponent(".config", isDirectory: true).appendingPathComponent("termux", isDirectory: true)
    }
    public var primaryPropertiesFile: URL { return termuxConfigDirectory.appendingPathComponent("termux.properties") }
    public var secondaryPropertiesFile: URL { return termuxConfigDirectory2.appendingPathComponent("termux.properties") }
    public var colorsPropertiesFile: URL { return termuxConfigDirectory.appendingPathComponent("colors.properties") }
    public var fontFile: URL { return termuxConfigDirectory.appendingPathComponent("font.ttf") }
    public var motdFile: URL { return termuxConfigDirectory.appendingPathComponent("motd") }
    public var hushLoginFile: URL { return homeDirectory.appendingPathComponent(".hushlogin") }

    public var propertiesFile: URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: primaryPropertiesFile.path) { return primaryPropertiesFile }
        if fileManager.fileExists(atPath: secondaryPropertiesFile.path) { return secondaryPropertiesFile }
        return primaryPropertiesFile
    }

    public func displayPath(_ url: URL) -> String {
        let home = homeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

public enum BellBehaviour: String, CaseIterable {
    case vibrate
    case beep
    case ignore
}

public enum SoftKeyboardToggleBehaviour: String {
    case showHide = "show/hide"
    case enableDisable = "enable/disable"
}

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

public struct TermuxProperties {
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

    public static let TERMINAL_CURSOR_STYLE_BLOCK = 0
    public static let TERMINAL_CURSOR_STYLE_UNDERLINE = 1
    public static let TERMINAL_CURSOR_STYLE_BAR = 2
    public static let MAP_TERMINAL_CURSOR_STYLE: [String: Int] = [
        "block": TERMINAL_CURSOR_STYLE_BLOCK,
        "underline": TERMINAL_CURSOR_STYLE_UNDERLINE,
        "bar": TERMINAL_CURSOR_STYLE_BAR,
    ]
    public static let DEFAULT_IVALUE_TERMINAL_CURSOR_STYLE = TERMINAL_CURSOR_STYLE_BLOCK

    public static let IVALUE_TERMINAL_CURSOR_BLINK_RATE_MIN = 100
    public static let IVALUE_TERMINAL_CURSOR_BLINK_RATE_MAX = 2000
    public static let DEFAULT_IVALUE_TERMINAL_CURSOR_BLINK_RATE = 0

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
    public var nightMode: String
    public var fullscreen: Bool
    public var hideSoftKeyboardOnStartup: Bool
    public var softKeyboardToggleBehaviour: SoftKeyboardToggleBehaviour
    public var hardwareKeyboardShortcutsDisabled: Bool
    public var terminalSessionChangeToastDisabled: Bool
    public var defaultWorkingDirectory: String?
    public var sessionShortcuts: [SessionShortcut]
    public var warnings: [String] = []

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

        func bool(_ key: String, default defaultValue: Bool) -> Bool {
            guard let value = string(key) else { return defaultValue }
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default:
                warnings.append("The value \"\(value)\" for the key \"\(key)\" is invalid, using \(defaultValue).")
                return defaultValue
            }
        }

        func int(_ key: String, default defaultValue: Int, min: Int, max: Int, allowZero: Bool = false) -> Int {
            guard let value = string(key) else { return defaultValue }
            guard let parsed = Int(value.trimmingCharacters(in: .whitespaces)) else {
                warnings.append("The value \"\(value)\" for the key \"\(key)\" is not an integer, using \(defaultValue).")
                return defaultValue
            }
            if allowZero && parsed == 0 { return 0 }
            if parsed < min || parsed > max {
                warnings.append("The value \"\(value)\" for the key \"\(key)\" is not between \(min) and \(max), using \(defaultValue).")
                return defaultValue
            }
            return parsed
        }

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

    public static func getCodePointForSessionShortcuts(_ value: String) -> Int? {
        let parts = value.lowercased().trimmingCharacters(in: .whitespaces).components(separatedBy: "+")
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "ctrl" else { return nil }
        let input = parts[1].trimmingCharacters(in: .whitespaces)
        let scalars = Array(input.unicodeScalars)
        guard scalars.count == 1 else { return nil }
        return Int(scalars[0].value)
    }

    public static func load(from url: URL) -> TermuxProperties {
        guard let properties = JavaPropertiesParser.parse(contentsOf: url) else {
            return TermuxProperties()
        }
        return TermuxProperties(properties: properties)
    }

    public func sessionShortcutAction(forCodePoint codePoint: Int) -> SessionShortcutAction? {
        let lower = TerminalInputLowercase.lowercase(codePoint)
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

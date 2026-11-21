import Foundation

// Port of `com.termux.shared.termux.extrakeys.ExtraKeysInfo` and `ExtraKeyButton`.
//
// UIKit-free so that it can be unit tested on any platform.

/// Error thrown while parsing an extra keys definition. Port of the `JSONException`s thrown by
/// the Java classes.
public struct ExtraKeysParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { return message }
}

/// A value of the lenient JSON dialect accepted by Android's `org.json` (`JSONTokener`), which
/// is what `termux.properties` `extra-keys` values are written in: strings may be single or double
/// quoted or not quoted at all, object keys need not be quoted, `=`/`=>` may be used instead of
/// `:` and `;` instead of `,`, and `#`, `//` and `/* */` comments are skipped.
public indirect enum LenientJSONValue: Equatable {
    case string(String)
    case object([String: LenientJSONValue])
    case array([LenientJSONValue])
    case null

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Minimal port of the Android `org.json.JSONTokener` parsing rules.
public struct LenientJSONParser {
    private let scalars: [Unicode.Scalar]
    private var pos = 0

    public init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    public static func parse(_ text: String) throws -> LenientJSONValue {
        var parser = LenientJSONParser(text)
        let value = try parser.nextValue()
        // Trailing garbage is ignored by org.json's JSONArray(String) as well, except for comments
        // and whitespace which nextClean() would skip anyway.
        return value
    }

    private mutating func nextClean() throws -> Unicode.Scalar? {
        while pos < scalars.count {
            let c = scalars[pos]
            pos += 1
            switch c {
            case "\t", " ", "\n", "\r", "\u{0C}":
                continue
            case "/":
                guard pos < scalars.count else { return c }
                let peek = scalars[pos]
                if peek == "*" {
                    pos += 1
                    var closed = false
                    while pos + 1 < scalars.count {
                        if scalars[pos] == "*" && scalars[pos + 1] == "/" {
                            pos += 2
                            closed = true
                            break
                        }
                        pos += 1
                    }
                    if !closed { throw ExtraKeysParseError("Unterminated comment") }
                    continue
                } else if peek == "/" {
                    pos += 1
                    skipToEndOfLine()
                    continue
                } else {
                    return c
                }
            case "#":
                skipToEndOfLine()
                continue
            default:
                if c.value < 32 { continue }
                return c
            }
        }
        return nil
    }

    private mutating func skipToEndOfLine() {
        while pos < scalars.count {
            let c = scalars[pos]
            pos += 1
            if c == "\r" || c == "\n" { break }
        }
    }

    public mutating func nextValue() throws -> LenientJSONValue {
        guard let c = try nextClean() else {
            throw ExtraKeysParseError("End of input")
        }
        switch c {
        case "{":
            return try readObject()
        case "[":
            return try readArray()
        case "'", "\"":
            return .string(try nextString(quote: c))
        default:
            pos -= 1
            return try readLiteral()
        }
    }

    private mutating func nextString(quote: Unicode.Scalar) throws -> String {
        var result = String.UnicodeScalarView()
        while pos < scalars.count {
            let c = scalars[pos]
            pos += 1
            if c == quote {
                return String(result)
            } else if c == "\\" {
                guard pos < scalars.count else { throw ExtraKeysParseError("Unterminated escape sequence") }
                let e = scalars[pos]
                pos += 1
                switch e {
                case "u":
                    guard pos + 4 <= scalars.count else { throw ExtraKeysParseError("Unterminated escape sequence") }
                    let hex = String(String.UnicodeScalarView(scalars[pos..<(pos + 4)]))
                    pos += 4
                    guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                        throw ExtraKeysParseError("Invalid escape sequence: \\u\(hex)")
                    }
                    result.append(scalar)
                case "t": result.append("\t")
                case "b": result.append("\u{08}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "f": result.append("\u{0C}")
                default: result.append(e) // includes ' " \ /
                }
            } else {
                result.append(c)
            }
        }
        throw ExtraKeysParseError("Unterminated string")
    }

    /// Reads a literal value terminated by whitespace or one of `{}[]/\:,=;#`.
    private mutating func readLiteral() throws -> LenientJSONValue {
        let terminators: Set<Unicode.Scalar> = ["{", "}", "[", "]", "/", "\\", ":", ",", "=", ";", "#", " ", "\t", "\u{0C}", "\r", "\n"]
        let start = pos
        while pos < scalars.count && !terminators.contains(scalars[pos]) {
            pos += 1
        }
        let literal = String(String.UnicodeScalarView(scalars[start..<pos]))
        if literal.isEmpty {
            throw ExtraKeysParseError("Expected literal value")
        }
        if literal == "null" { return .null }
        // Android's org.json would return booleans/numbers here (which then fail to be used as a
        // key), we are more lenient and treat every literal as a string, e.g. [1, 2, 3].
        return .string(literal)
    }

    private mutating func readArray() throws -> LenientJSONValue {
        var result: [LenientJSONValue] = []
        // To cover input that ends with ",]".
        var hasTrailingSeparator = false
        while true {
            guard let c = try nextClean() else {
                throw ExtraKeysParseError("Unterminated array")
            }
            switch c {
            case "]":
                if hasTrailingSeparator { result.append(.null) }
                return .array(result)
            case ",", ";":
                // A separator without a value first means "null".
                result.append(.null)
                hasTrailingSeparator = true
                continue
            default:
                pos -= 1
            }

            result.append(try nextValue())

            guard let d = try nextClean() else {
                throw ExtraKeysParseError("Unterminated array")
            }
            switch d {
            case "]":
                return .array(result)
            case ",", ";":
                hasTrailingSeparator = true
                continue
            default:
                throw ExtraKeysParseError("Unterminated array")
            }
        }
    }

    private mutating func readObject() throws -> LenientJSONValue {
        var result: [String: LenientJSONValue] = [:]
        // Peek to see if this is the empty object.
        if let first = try nextClean() {
            if first == "}" { return .object(result) }
            pos -= 1
        } else {
            throw ExtraKeysParseError("Unterminated object")
        }

        while true {
            let nameValue = try nextValue()
            let name: String
            switch nameValue {
            case .string(let s): name = s
            case .null: name = "null"
            default: throw ExtraKeysParseError("Names must be strings, but \(nameValue) is not")
            }

            // Expect ":", "=" or "=>".
            guard let separator = try nextClean() else { throw ExtraKeysParseError("Expected ':' after \(name)") }
            if separator == "=" {
                if pos < scalars.count && scalars[pos] == ">" { pos += 1 }
            } else if separator != ":" {
                throw ExtraKeysParseError("Expected ':' after \(name)")
            }

            result[name] = try nextValue()

            guard let d = try nextClean() else { throw ExtraKeysParseError("Unterminated object") }
            switch d {
            case "}":
                return .object(result)
            case ";", ",":
                continue
            default:
                throw ExtraKeysParseError("Unterminated object")
            }
        }
    }
}

/// Port of `ExtraKeyButton`: a single button of the extra keys row.
public final class ExtraKeyButton: Equatable, CustomStringConvertible {

    /// The key name for the name of the extra key if using a dict to define the extra key. {key: name, ...}
    public static let KEY_KEY_NAME = "key"
    /// The key name for the macro value of the extra key if using a dict to define the extra key. {macro: value, ...}
    public static let KEY_MACRO = "macro"
    /// The key name for the alternate display name of the extra key if using a dict to define the extra key. {display: name, ...}
    public static let KEY_DISPLAY_NAME = "display"
    /// The key name for the nested dict to define popup extra key info if using a dict to define the extra key. {popup: {key: name, ...}, ...}
    public static let KEY_POPUP = "popup"

    /// The key that will be sent to the terminal, either a control character, like defined in
    /// `ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS` (LEFT, RIGHT, PGUP...) or some text.
    public let key: String
    /// If the key is a macro, i.e. a sequence of keys separated by space.
    public let isMacro: Bool
    /// The text that will be shown on the button.
    public let display: String
    /// The information of the popup (triggered by swipe up).
    public let popup: ExtraKeyButton?

    public init(key: String, isMacro: Bool, display: String, popup: ExtraKeyButton?) {
        self.key = key
        self.isMacro = isMacro
        self.display = display
        self.popup = popup
    }

    /// Initialize an `ExtraKeyButton` from a config object (`{key: ..., display: ...}`).
    public convenience init(config: [String: LenientJSONValue], popup: ExtraKeyButton? = nil,
                            extraKeyDisplayMap: ExtraKeysConstants.ExtraKeyDisplayMap,
                            extraKeyAliasMap: ExtraKeysConstants.ExtraKeyDisplayMap) throws {
        let keyFromConfig = ExtraKeyButton.getStringFromJson(config, ExtraKeyButton.KEY_KEY_NAME)
        let macroFromConfig = ExtraKeyButton.getStringFromJson(config, ExtraKeyButton.KEY_MACRO)
        var keys: [String]
        let macro: Bool
        if let keyFromConfig = keyFromConfig, let macroFromConfig = macroFromConfig {
            throw ExtraKeysParseError("Both key and macro can't be set for the same key. key: \"\(keyFromConfig)\", macro: \"\(macroFromConfig)\"")
        } else if let keyFromConfig = keyFromConfig {
            keys = [keyFromConfig]
            macro = false
        } else if let macroFromConfig = macroFromConfig {
            // Java String.split(" ") drops trailing empty strings.
            keys = macroFromConfig.components(separatedBy: " ")
            while let last = keys.last, last.isEmpty { keys.removeLast() }
            macro = true
        } else {
            throw ExtraKeysParseError("All keys have to specify either key or macro")
        }

        keys = keys.map { ExtraKeyButton.replaceAlias(extraKeyAliasMap, $0) }

        let display: String
        if let displayFromConfig = ExtraKeyButton.getStringFromJson(config, ExtraKeyButton.KEY_DISPLAY_NAME) {
            display = displayFromConfig
        } else {
            display = keys.map { extraKeyDisplayMap[$0] ?? $0 }.joined(separator: " ")
        }

        self.init(key: keys.joined(separator: " "), isMacro: macro, display: display, popup: popup)
    }

    static func getStringFromJson(_ config: [String: LenientJSONValue], _ key: String) -> String? {
        return config[key]?.stringValue
    }

    /// Replace the alias with its actual key name if found in extraKeyAliasMap.
    public static func replaceAlias(_ extraKeyAliasMap: ExtraKeysConstants.ExtraKeyDisplayMap, _ key: String) -> String {
        return extraKeyAliasMap[key] ?? key
    }

    public static func == (lhs: ExtraKeyButton, rhs: ExtraKeyButton) -> Bool {
        return lhs.key == rhs.key && lhs.isMacro == rhs.isMacro && lhs.display == rhs.display && lhs.popup == rhs.popup
    }

    public var description: String {
        var s = "ExtraKeyButton(key: \(key), display: \(display)"
        if isMacro { s += ", macro" }
        if let popup = popup { s += ", popup: \(popup)" }
        return s + ")"
    }
}

/// Port of `ExtraKeysInfo`: the matrix of buttons for the extra keys rows.
public final class ExtraKeysInfo {

    /// Matrix of buttons to be displayed in `ExtraKeysView`.
    public let matrix: [[ExtraKeyButton]]

    /// The default extra keys of Termux (`TermuxPropertyConstants.DEFAULT_IVALUE_EXTRA_KEYS`).
    public static let DEFAULT_EXTRA_KEYS = "[['ESC','/',{key: '-', popup: '|'},'HOME','UP','END','PGUP'], ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]"

    /// The default extra keys style (`TermuxPropertyConstants.DEFAULT_IVALUE_EXTRA_KEYS_STYLE`).
    public static let DEFAULT_EXTRA_KEYS_STYLE = "default"

    public convenience init(propertiesInfo: String, style: String,
                            extraKeyAliasMap: ExtraKeysConstants.ExtraKeyDisplayMap = ExtraKeysConstants.CONTROL_CHARS_ALIASES) throws {
        try self.init(propertiesInfo: propertiesInfo,
                      extraKeyDisplayMap: ExtraKeysInfo.getCharDisplayMapForStyle(style),
                      extraKeyAliasMap: extraKeyAliasMap)
    }

    public init(propertiesInfo: String,
                extraKeyDisplayMap: ExtraKeysConstants.ExtraKeyDisplayMap,
                extraKeyAliasMap: ExtraKeysConstants.ExtraKeyDisplayMap) throws {
        matrix = try ExtraKeysInfo.initExtraKeysInfo(propertiesInfo, extraKeyDisplayMap, extraKeyAliasMap)
    }

    private static func initExtraKeysInfo(_ propertiesInfo: String,
                                          _ extraKeyDisplayMap: ExtraKeysConstants.ExtraKeyDisplayMap,
                                          _ extraKeyAliasMap: ExtraKeysConstants.ExtraKeyDisplayMap) throws -> [[ExtraKeyButton]] {
        // Convert String propertiesInfo to Array of Arrays
        guard case .array(let rows) = try LenientJSONParser.parse(propertiesInfo) else {
            throw ExtraKeysParseError("The extra keys must be an array of arrays")
        }

        var buttons: [[ExtraKeyButton]] = []
        for (i, rowValue) in rows.enumerated() {
            guard case .array(let line) = rowValue else {
                throw ExtraKeysParseError("Row \(i) of the extra keys is not an array")
            }
            var buttonRow: [ExtraKeyButton] = []
            for key in line {
                // Unlike Android, tolerate empty entries such as a trailing comma: "['ESC','TAB',]".
                if key == .null { continue }
                let jobject = try normalizeKeyConfig(key)
                let button: ExtraKeyButton
                if let popupValue = jobject[ExtraKeyButton.KEY_POPUP] {
                    // a popup
                    let popupJobject = try normalizeKeyConfig(popupValue)
                    let popup = try ExtraKeyButton(config: popupJobject, extraKeyDisplayMap: extraKeyDisplayMap,
                                                   extraKeyAliasMap: extraKeyAliasMap)
                    button = try ExtraKeyButton(config: jobject, popup: popup, extraKeyDisplayMap: extraKeyDisplayMap,
                                                extraKeyAliasMap: extraKeyAliasMap)
                } else {
                    // no popup
                    button = try ExtraKeyButton(config: jobject, extraKeyDisplayMap: extraKeyDisplayMap,
                                                extraKeyAliasMap: extraKeyAliasMap)
                }
                buttonRow.append(button)
            }
            buttons.append(buttonRow)
        }
        return buttons
    }

    /// Convert "value" -> {"key": "value"}. Required by `ExtraKeyButton(config:)`.
    private static func normalizeKeyConfig(_ key: LenientJSONValue) throws -> [String: LenientJSONValue] {
        switch key {
        case .string(let s):
            return [ExtraKeyButton.KEY_KEY_NAME: .string(s)]
        case .object(let o):
            return o
        default:
            throw ExtraKeysParseError("An key in the extra-key matrix must be a string or an object")
        }
    }

    /// The display map for an `extra-keys-style` value.
    public static func getCharDisplayMapForStyle(_ style: String?) -> ExtraKeysConstants.ExtraKeyDisplayMap {
        switch style {
        case "arrows-only":
            return ExtraKeysConstants.EXTRA_KEY_DISPLAY_MAPS.ARROWS_ONLY_CHAR_DISPLAY
        case "arrows-all":
            return ExtraKeysConstants.EXTRA_KEY_DISPLAY_MAPS.LOTS_OF_ARROWS_CHAR_DISPLAY
        case "all":
            return ExtraKeysConstants.EXTRA_KEY_DISPLAY_MAPS.FULL_ISO_CHAR_DISPLAY
        case "none":
            return [:]
        default:
            return ExtraKeysConstants.EXTRA_KEY_DISPLAY_MAPS.DEFAULT_CHAR_DISPLAY
        }
    }

    /// If the style is one of the known styles.
    public static func isValidStyle(_ style: String) -> Bool {
        return ["default", "arrows-only", "arrows-all", "all", "none"].contains(style)
    }

    /// Loads the extra keys like `TermuxTerminalExtraKeys.setExtraKeys()`: falls back to the default
    /// extra keys and style if the given value can't be parsed. Returns the info and an optional
    /// error message that should be shown to the user.
    public static func loadWithFallback(extraKeys: String?, style: String?) -> (info: ExtraKeysInfo?, error: String?) {
        var extraKeysStyle = (style?.isEmpty ?? true) ? DEFAULT_EXTRA_KEYS_STYLE : style!
        var errorMessage: String?
        if !isValidStyle(extraKeysStyle) {
            errorMessage = "The style \"\(extraKeysStyle)\" for the key \"extra-keys-style\" is invalid. Using default style instead."
            extraKeysStyle = DEFAULT_EXTRA_KEYS_STYLE
        }
        let value = (extraKeys?.isEmpty ?? true) ? DEFAULT_EXTRA_KEYS : extraKeys!
        do {
            return (try ExtraKeysInfo(propertiesInfo: value, style: extraKeysStyle), errorMessage)
        } catch {
            let message = "Could not load and set the \"extra-keys\" property from the properties file: \(error)"
            let info = try? ExtraKeysInfo(propertiesInfo: DEFAULT_EXTRA_KEYS, style: DEFAULT_EXTRA_KEYS_STYLE)
            return (info, message)
        }
    }

    /// Maximum row length of the matrix. Port of `ExtraKeysView.maximumLength()`.
    public var maximumRowLength: Int {
        return matrix.map { $0.count }.max() ?? 0
    }
}

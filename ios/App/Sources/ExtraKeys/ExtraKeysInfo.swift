import Foundation

public struct ExtraKeysParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { return message }
}

public indirect enum LenientJSONValue: Equatable {
    case string(String)
    case object([String: LenientJSONValue])
    case array([LenientJSONValue])
    case null

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public struct LenientJSONParser {
    private let scalars: [Unicode.Scalar]
    private var position = 0

    public init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    public static func parse(_ text: String) throws -> LenientJSONValue {
        var parser = LenientJSONParser(text)
        let value = try parser.nextValue()
        return value
    }

    private mutating func nextClean() throws -> Unicode.Scalar? {
        while position < scalars.count {
            let character = scalars[position]
            position += 1
            switch character {
            case "\t", " ", "\n", "\r", "\u{0C}":
                continue
            case "/":
                guard position < scalars.count else { return character }
                let peek = scalars[position]
                if peek == "*" {
                    position += 1
                    var closed = false
                    while position + 1 < scalars.count {
                        if scalars[position] == "*" && scalars[position + 1] == "/" {
                            position += 2
                            closed = true
                            break
                        }
                        position += 1
                    }
                    if !closed { throw ExtraKeysParseError("Unterminated comment") }
                    continue
                } else if peek == "/" {
                    position += 1
                    skipToEndOfLine()
                    continue
                } else {
                    return character
                }
            case "#":
                skipToEndOfLine()
                continue
            default:
                if character.value < 32 { continue }
                return character
            }
        }
        return nil
    }

    private mutating func skipToEndOfLine() {
        while position < scalars.count {
            let character = scalars[position]
            position += 1
            if character == "\r" || character == "\n" { break }
        }
    }

    public mutating func nextValue() throws -> LenientJSONValue {
        guard let character = try nextClean() else {
            throw ExtraKeysParseError("End of input")
        }
        switch character {
        case "{":
            return try readObject()
        case "[":
            return try readArray()
        case "'", "\"":
            return .string(try nextString(quote: character))
        default:
            position -= 1
            return try readLiteral()
        }
    }

    private mutating func nextString(quote: Unicode.Scalar) throws -> String {
        var result = String.UnicodeScalarView()
        while position < scalars.count {
            let character = scalars[position]
            position += 1
            if character == quote {
                return String(result)
            } else if character == "\\" {
                guard position < scalars.count else { throw ExtraKeysParseError("Unterminated escape sequence") }
                let escaped = scalars[position]
                position += 1
                switch escaped {
                case "u":
                    guard position + 4 <= scalars.count else { throw ExtraKeysParseError("Unterminated escape sequence") }
                    let hexDigits = String(String.UnicodeScalarView(scalars[position..<(position + 4)]))
                    position += 4
                    guard let codeUnit = UInt32(hexDigits, radix: 16), let scalar = Unicode.Scalar(codeUnit) else {
                        throw ExtraKeysParseError("Invalid escape sequence: \\u\(hexDigits)")
                    }
                    result.append(scalar)
                case "t": result.append("\t")
                case "b": result.append("\u{08}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "f": result.append("\u{0C}")
                default: result.append(escaped)
                }
            } else {
                result.append(character)
            }
        }
        throw ExtraKeysParseError("Unterminated string")
    }

    private mutating func readLiteral() throws -> LenientJSONValue {
        let terminators: Set<Unicode.Scalar> = ["{", "}", "[", "]", "/", "\\", ":", ",", "=", ";", "#", " ", "\t", "\u{0C}", "\r", "\n"]
        let start = position
        while position < scalars.count && !terminators.contains(scalars[position]) {
            position += 1
        }
        let literal = String(String.UnicodeScalarView(scalars[start..<position]))
        if literal.isEmpty {
            throw ExtraKeysParseError("Expected literal value")
        }
        if literal == "null" { return .null }
        return .string(literal)
    }

    private mutating func readArray() throws -> LenientJSONValue {
        var result: [LenientJSONValue] = []
        var hasTrailingSeparator = false
        while true {
            guard let character = try nextClean() else {
                throw ExtraKeysParseError("Unterminated array")
            }
            switch character {
            case "]":
                if hasTrailingSeparator { result.append(.null) }
                return .array(result)
            case ",", ";":
                result.append(.null)
                hasTrailingSeparator = true
                continue
            default:
                position -= 1
            }

            result.append(try nextValue())

            guard let separatorCharacter = try nextClean() else {
                throw ExtraKeysParseError("Unterminated array")
            }
            switch separatorCharacter {
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
        if let first = try nextClean() {
            if first == "}" { return .object(result) }
            position -= 1
        } else {
            throw ExtraKeysParseError("Unterminated object")
        }

        while true {
            let nameValue = try nextValue()
            let name: String
            switch nameValue {
            case .string(let value): name = value
            case .null: name = "null"
            default: throw ExtraKeysParseError("Names must be strings, but \(nameValue) is not")
            }

            guard let separator = try nextClean() else { throw ExtraKeysParseError("Expected ':' after \(name)") }
            if separator == "=" {
                if position < scalars.count && scalars[position] == ">" { position += 1 }
            } else if separator != ":" {
                throw ExtraKeysParseError("Expected ':' after \(name)")
            }

            result[name] = try nextValue()

            guard let separatorCharacter = try nextClean() else { throw ExtraKeysParseError("Unterminated object") }
            switch separatorCharacter {
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

public final class ExtraKeyButton: Equatable, CustomStringConvertible {
    public static let KEY_KEY_NAME = "key"
    public static let KEY_MACRO = "macro"
    public static let KEY_DISPLAY_NAME = "display"
    public static let KEY_POPUP = "popup"

    public let key: String
    public let isMacro: Bool
    public let display: String
    public let popup: ExtraKeyButton?

    public init(key: String, isMacro: Bool, display: String, popup: ExtraKeyButton?) {
        self.key = key
        self.isMacro = isMacro
        self.display = display
        self.popup = popup
    }

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

    public static func replaceAlias(_ extraKeyAliasMap: ExtraKeysConstants.ExtraKeyDisplayMap, _ key: String) -> String {
        return extraKeyAliasMap[key] ?? key
    }

    public static func == (left: ExtraKeyButton, right: ExtraKeyButton) -> Bool {
        return left.key == right.key && left.isMacro == right.isMacro && left.display == right.display && left.popup == right.popup
    }

    public var description: String {
        var value = "ExtraKeyButton(key: \(key), display: \(display)"
        if isMacro { value += ", macro" }
        if let popup = popup { value += ", popup: \(popup)" }
        return value + ")"
    }
}

public final class ExtraKeysInfo {
    public let matrix: [[ExtraKeyButton]]

    public static let DEFAULT_EXTRA_KEYS = "[['ESC','/',{key: '-', popup: '|'},'HOME','UP','END','PGUP'], ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]"

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
        guard case .array(let rows) = try LenientJSONParser.parse(propertiesInfo) else {
            throw ExtraKeysParseError("The extra keys must be an array of arrays")
        }

        var buttons: [[ExtraKeyButton]] = []
        for (rowIndex, rowValue) in rows.enumerated() {
            guard case .array(let line) = rowValue else {
                throw ExtraKeysParseError("Row \(rowIndex) of the extra keys is not an array")
            }
            var buttonRow: [ExtraKeyButton] = []
            for key in line {
                if key == .null { continue }
                let jobject = try normalizeKeyConfig(key)
                let button: ExtraKeyButton
                if let popupValue = jobject[ExtraKeyButton.KEY_POPUP] {
                    let popupJobject = try normalizeKeyConfig(popupValue)
                    let popup = try ExtraKeyButton(config: popupJobject, extraKeyDisplayMap: extraKeyDisplayMap,
                                                   extraKeyAliasMap: extraKeyAliasMap)
                    button = try ExtraKeyButton(config: jobject, popup: popup, extraKeyDisplayMap: extraKeyDisplayMap,
                                                extraKeyAliasMap: extraKeyAliasMap)
                } else {
                    button = try ExtraKeyButton(config: jobject, extraKeyDisplayMap: extraKeyDisplayMap,
                                                extraKeyAliasMap: extraKeyAliasMap)
                }
                buttonRow.append(button)
            }
            buttons.append(buttonRow)
        }
        return buttons
    }

    private static func normalizeKeyConfig(_ key: LenientJSONValue) throws -> [String: LenientJSONValue] {
        switch key {
        case .string(let value):
            return [ExtraKeyButton.KEY_KEY_NAME: .string(value)]
        case .object(let object):
            return object
        default:
            throw ExtraKeysParseError("An key in the extra-key matrix must be a string or an object")
        }
    }

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

    public static func isValidStyle(_ style: String) -> Bool {
        return ["default", "arrows-only", "arrows-all", "all", "none"].contains(style)
    }

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

    public var maximumRowLength: Int {
        return matrix.map { $0.count }.max() ?? 0
    }
}

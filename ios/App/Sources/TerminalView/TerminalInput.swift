import Foundation

public enum KeyEventSource: Int {
    case virtualKeyboard = -1
    case softKeyboard = 0
    case hardwareKeyboard = 1
}

public enum VirtualFunctionKeyResult: Equatable {
    case keyCode(Int)
    case codePoint(Int, altDown: Bool)
    case toggleKeyboard
    case consumed
    case none
}

public enum TerminalInput {
    public static let UNICODE_REPLACEMENT_CHAR = 0xFFFD

    public static func applyControl(_ codePoint: Int) -> Int {
        switch codePoint {
        case 0x61...0x7A:
            return codePoint - 0x61 + 1
        case 0x41...0x5A:
            return codePoint - 0x41 + 1
        case 0x20, 0x32:
            return 0
        case 0x5B, 0x33:
            return 27
        case 0x5C, 0x34:
            return 28
        case 0x5D, 0x35:
            return 29
        case 0x5E, 0x36:
            return 30
        case 0x5F, 0x37, 0x2F:
            return 31
        case 0x38:
            return 127
        default:
            return codePoint
        }
    }

    public static func fixHardwareKeyboardCodePoint(_ codePoint: Int) -> Int {
        switch codePoint {
        case 0x02DC: return 0x007E
        case 0x02CB: return 0x0060
        case 0x02C6: return 0x005E
        default: return codePoint
        }
    }

    public static func transformCodePoint(_ codePoint: Int, controlDown: Bool, source: KeyEventSource) -> Int? {
        var codePoint = codePoint
        if controlDown {
            codePoint = applyControl(codePoint)
        }
        guard codePoint > -1 else { return nil }
        if source.rawValue > KeyEventSource.softKeyboard.rawValue {
            codePoint = fixHardwareKeyboardCodePoint(codePoint)
        }
        return codePoint
    }

    public static func softKeyboardCodePoint(_ codePointIn: Int) -> (codePoint: Int, controlHeld: Bool) {
        var codePoint = codePointIn
        var controlHeld = false
        if codePoint <= 31 && codePoint != 27 {
            if codePoint == 10 {
                codePoint = 13
            }

            controlHeld = true
            switch codePoint {
            case 31: codePoint = 0x5F
            case 30: codePoint = 0x5E
            case 29: codePoint = 0x5D
            case 28: codePoint = 0x5C
            default: codePoint += 96
            }
        }
        return (codePoint, controlHeld)
    }

    public static func toUpperCase(_ codePoint: Int) -> Int {
        guard let scalar = Unicode.Scalar(UInt32(clamping: max(0, codePoint))) else { return codePoint }
        let upper = String(Character(scalar)).uppercased().unicodeScalars
        if upper.count == 1, let first = upper.first {
            return Int(first.value)
        }
        return codePoint
    }

    public static func codePoints(_ text: String) -> [Int] {
        return text.unicodeScalars.map { Int($0.value) }
    }

    public static func virtualFunctionKey(_ codePoint: Int) -> VirtualFunctionKeyResult {
        let lowerCase: Int
        if let scalar = Unicode.Scalar(UInt32(clamping: max(0, codePoint))),
           let lowerScalar = String(Character(scalar)).lowercased().unicodeScalars.first,
           String(Character(scalar)).lowercased().unicodeScalars.count == 1 {
            lowerCase = Int(lowerScalar.value)
        } else {
            lowerCase = codePoint
        }
        switch lowerCase {
        case 0x77: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_UP)
        case 0x61: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_LEFT)
        case 0x73: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_DOWN)
        case 0x64: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_RIGHT)
        case 0x70: return .keyCode(AndroidKeyEvent.KEYCODE_PAGE_UP)
        case 0x6E: return .keyCode(AndroidKeyEvent.KEYCODE_PAGE_DOWN)
        case 0x74: return .keyCode(AndroidKeyEvent.KEYCODE_TAB)
        case 0x69: return .keyCode(AndroidKeyEvent.KEYCODE_INSERT)
        case 0x68: return .codePoint(0x7E, altDown: false)
        case 0x75: return .codePoint(0x5F, altDown: false)
        case 0x6C: return .codePoint(0x7C, altDown: false)
        case 0x31...0x39: return .keyCode((codePoint - 0x31) + AndroidKeyEvent.KEYCODE_F1)
        case 0x30: return .keyCode(AndroidKeyEvent.KEYCODE_F10)
        case 0x65: return .codePoint(27, altDown: false)
        case 0x2E: return .codePoint(28, altDown: false)
        case 0x62, 0x66, 0x78:
            return .codePoint(lowerCase, altDown: true)
        case 0x76: return .consumed
        case 0x71, 0x6B: return .toggleKeyboard
        default: return .none
        }
    }
}

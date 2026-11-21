import Foundation

/// Where a code point that is input into the terminal came from. Port of
/// `TerminalView.KEY_EVENT_SOURCE_*`.
public enum KeyEventSource: Int {
    /// The extra keys row (`KeyCharacterMap.VIRTUAL_KEYBOARD` on Android).
    case virtualKeyboard = -1
    /// The software (on screen) keyboard.
    case softKeyboard = 0
    /// A hardware (e.g. bluetooth) keyboard.
    case hardwareKeyboard = 1
}

/// The result of mapping a key typed while the virtual FN key is held. Port of the
/// `mVirtualFnKeyDown` part of `TermuxTerminalViewClient.onCodePoint()`.
public enum VirtualFnKeyResult: Equatable {
    /// Send the escape sequence for this Android key code.
    case keyCode(Int)
    /// Send this code point, optionally prefixed with escape.
    case codePoint(Int, altDown: Bool)
    /// Toggle the soft keyboard ("writing mode" on Android).
    case toggleKeyboard
    /// The key has a meaning for FN on Android which does not exist on iOS (e.g. volume), consume it.
    case consumed
    /// No FN mapping, the code point should be input as is.
    case none
}

/// Pure input transformations of `TerminalView` (`inputCodePoint()`, the soft keyboard
/// `InputConnection.sendTextToTerminal()`) and `TermuxTerminalViewClient`.
///
/// UIKit-free so that it can be unit tested on any platform.
public enum TerminalInput {

    public static let UNICODE_REPLACEMENT_CHAR = 0xFFFD

    /// Apply the Ctrl modifier to a code point, like `TerminalView.inputCodePoint()`.
    public static func applyControl(_ codePoint: Int) -> Int {
        switch codePoint {
        case 0x61...0x7A: // 'a'...'z'
            return codePoint - 0x61 + 1
        case 0x41...0x5A: // 'A'...'Z'
            return codePoint - 0x41 + 1
        case 0x20, 0x32: // ' ', '2'
            return 0
        case 0x5B, 0x33: // '[', '3'
            return 27 // ^[ (Esc)
        case 0x5C, 0x34: // '\\', '4'
            return 28
        case 0x5D, 0x35: // ']', '5'
            return 29
        case 0x5E, 0x36: // '^', '6'
            return 30 // control-^
        case 0x5F, 0x37, 0x2F: // '_', '7', '/'
            // "Ctrl-/ sends 0x1f which is equivalent of Ctrl-_ since the days of VT102"
            return 31
        case 0x38: // '8'
            return 127 // DEL
        default:
            return codePoint
        }
    }

    /// Work around bluetooth keyboards sending funny unicode characters instead of the more normal
    /// ones from ASCII that terminal programs expect.
    public static func fixHardwareKeyboardCodePoint(_ codePoint: Int) -> Int {
        switch codePoint {
        case 0x02DC: return 0x007E // SMALL TILDE -> TILDE (~).
        case 0x02CB: return 0x0060 // MODIFIER LETTER GRAVE ACCENT -> GRAVE ACCENT (`).
        case 0x02C6: return 0x005E // MODIFIER LETTER CIRCUMFLEX ACCENT -> CIRCUMFLEX ACCENT (^).
        default: return codePoint
        }
    }

    /// The final code point to write for an input code point, given the effective modifiers.
    /// Returns `nil` if nothing should be written.
    public static func transformCodePoint(_ codePoint: Int, controlDown: Bool, source: KeyEventSource) -> Int? {
        var codePoint = codePoint
        if controlDown {
            codePoint = applyControl(codePoint)
        }
        guard codePoint > -1 else { return nil }
        // If not virtual or soft keyboard.
        if source.rawValue > KeyEventSource.softKeyboard.rawValue {
            codePoint = fixHardwareKeyboardCodePoint(codePoint)
        }
        return codePoint
    }

    /// Convert a control character typed via the soft keyboard into the letter with ctrl held,
    /// like `sendTextToTerminal()` in `TerminalView.onCreateInputConnection()`. The iOS keyboard
    /// sends "\n" for the return key, which is converted to "\r" (ctrl+m) like on Android.
    ///
    /// - Returns: The code point to input and whether ctrl should be held for it.
    public static func softKeyboardCodePoint(_ codePointIn: Int) -> (codePoint: Int, ctrlHeld: Bool) {
        var codePoint = codePointIn
        var ctrlHeld = false
        if codePoint <= 31 && codePoint != 27 {
            if codePoint == 10 {
                // The keyboard sends \n as text when the enter key is pressed. A terminal expects
                // \r for the enter key.
                codePoint = 13
            }

            // E.g. penti keyboard for ctrl input.
            ctrlHeld = true
            switch codePoint {
            case 31: codePoint = 0x5F // '_'
            case 30: codePoint = 0x5E // '^'
            case 29: codePoint = 0x5D // ']'
            case 28: codePoint = 0x5C // '\\'
            default: codePoint += 96
            }
        }
        return (codePoint, ctrlHeld)
    }

    /// Upper case a code point (`Character.toUpperCase(int)`), used when the extra keys SHIFT
    /// button is active.
    public static func toUpperCase(_ codePoint: Int) -> Int {
        guard let scalar = Unicode.Scalar(UInt32(clamping: max(0, codePoint))) else { return codePoint }
        let upper = String(Character(scalar)).uppercased().unicodeScalars
        if upper.count == 1, let first = upper.first {
            return Int(first.value)
        }
        return codePoint
    }

    /// The code points of a string. Lone surrogates can't occur in Swift strings.
    public static func codePoints(_ text: String) -> [Int] {
        return text.unicodeScalars.map { Int($0.value) }
    }

    /// Mapping of keys typed while the virtual FN key is down. Port of
    /// `TermuxTerminalViewClient.onCodePoint()` (volume up + key on Android; the FN extra key on iOS).
    public static func virtualFnKey(_ codePoint: Int) -> VirtualFnKeyResult {
        let lowerCase: Int
        if let scalar = Unicode.Scalar(UInt32(clamping: max(0, codePoint))),
           let lower = String(Character(scalar)).lowercased().unicodeScalars.first,
           String(Character(scalar)).lowercased().unicodeScalars.count == 1 {
            lowerCase = Int(lower.value)
        } else {
            lowerCase = codePoint
        }
        switch lowerCase {
        // Arrow keys.
        case 0x77: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_UP) // w
        case 0x61: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_LEFT) // a
        case 0x73: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_DOWN) // s
        case 0x64: return .keyCode(AndroidKeyEvent.KEYCODE_DPAD_RIGHT) // d
        // Page up and down.
        case 0x70: return .keyCode(AndroidKeyEvent.KEYCODE_PAGE_UP) // p
        case 0x6E: return .keyCode(AndroidKeyEvent.KEYCODE_PAGE_DOWN) // n
        // Some special keys:
        case 0x74: return .keyCode(AndroidKeyEvent.KEYCODE_TAB) // t
        case 0x69: return .keyCode(AndroidKeyEvent.KEYCODE_INSERT) // i
        case 0x68: return .codePoint(0x7E, altDown: false) // h -> '~'
        // Special characters to input.
        case 0x75: return .codePoint(0x5F, altDown: false) // u -> '_'
        case 0x6C: return .codePoint(0x7C, altDown: false) // l -> '|'
        // Function keys.
        case 0x31...0x39: return .keyCode((codePoint - 0x31) + AndroidKeyEvent.KEYCODE_F1) // 1-9
        case 0x30: return .keyCode(AndroidKeyEvent.KEYCODE_F10) // 0
        // Other special keys.
        case 0x65: return .codePoint(27, altDown: false) // e -> Escape
        case 0x2E: return .codePoint(28, altDown: false) // . -> ^.
        case 0x62, 0x66, 0x78: // b, f, x: alt+b, alt+f (readline), alt+x (emacs)
            return .codePoint(lowerCase, altDown: true)
        // Volume control (not possible on iOS).
        case 0x76: return .consumed // v
        // Writing mode:
        case 0x71, 0x6B: return .toggleKeyboard // q, k
        default: return .none
        }
    }
}

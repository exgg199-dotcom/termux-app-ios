import Foundation

/// Port of `com.termux.terminal.KeyHandler`.
///
/// iOS has no Android `KeyEvent` key codes, so the port defines the same numeric `KEYCODE_*` constants as
/// Android's `android.view.KeyEvent` (e.g. `KEYCODE_DPAD_UP = 19`). The UI maps iOS keys (`UIKeyCommand`,
/// `UIPress`, extra keys row) onto these codes and calls `getCode(keyCode:keyMode:cursorApp:keypadApplication:)`.
public enum KeyHandler {

    public static let KEYMOD_ALT = 0x80000000
    public static let KEYMOD_CTRL = 0x40000000
    public static let KEYMOD_SHIFT = 0x20000000
    public static let KEYMOD_NUM_LOCK = 0x10000000

    // MARK: - Android KeyEvent key codes (same numeric values as android.view.KeyEvent)

    public static let KEYCODE_UNKNOWN = 0
    public static let KEYCODE_SOFT_LEFT = 1
    public static let KEYCODE_SOFT_RIGHT = 2
    public static let KEYCODE_HOME = 3
    public static let KEYCODE_BACK = 4
    public static let KEYCODE_CALL = 5
    public static let KEYCODE_ENDCALL = 6
    public static let KEYCODE_0 = 7
    public static let KEYCODE_1 = 8
    public static let KEYCODE_2 = 9
    public static let KEYCODE_3 = 10
    public static let KEYCODE_4 = 11
    public static let KEYCODE_5 = 12
    public static let KEYCODE_6 = 13
    public static let KEYCODE_7 = 14
    public static let KEYCODE_8 = 15
    public static let KEYCODE_9 = 16
    public static let KEYCODE_STAR = 17
    public static let KEYCODE_POUND = 18
    public static let KEYCODE_DPAD_UP = 19
    public static let KEYCODE_DPAD_DOWN = 20
    public static let KEYCODE_DPAD_LEFT = 21
    public static let KEYCODE_DPAD_RIGHT = 22
    public static let KEYCODE_DPAD_CENTER = 23
    public static let KEYCODE_VOLUME_UP = 24
    public static let KEYCODE_VOLUME_DOWN = 25
    public static let KEYCODE_POWER = 26
    public static let KEYCODE_CAMERA = 27
    public static let KEYCODE_CLEAR = 28
    public static let KEYCODE_A = 29
    public static let KEYCODE_B = 30
    public static let KEYCODE_C = 31
    public static let KEYCODE_D = 32
    public static let KEYCODE_E = 33
    public static let KEYCODE_F = 34
    public static let KEYCODE_G = 35
    public static let KEYCODE_H = 36
    public static let KEYCODE_I = 37
    public static let KEYCODE_J = 38
    public static let KEYCODE_K = 39
    public static let KEYCODE_L = 40
    public static let KEYCODE_M = 41
    public static let KEYCODE_N = 42
    public static let KEYCODE_O = 43
    public static let KEYCODE_P = 44
    public static let KEYCODE_Q = 45
    public static let KEYCODE_R = 46
    public static let KEYCODE_S = 47
    public static let KEYCODE_T = 48
    public static let KEYCODE_U = 49
    public static let KEYCODE_V = 50
    public static let KEYCODE_W = 51
    public static let KEYCODE_X = 52
    public static let KEYCODE_Y = 53
    public static let KEYCODE_Z = 54
    public static let KEYCODE_COMMA = 55
    public static let KEYCODE_PERIOD = 56
    public static let KEYCODE_ALT_LEFT = 57
    public static let KEYCODE_ALT_RIGHT = 58
    public static let KEYCODE_SHIFT_LEFT = 59
    public static let KEYCODE_SHIFT_RIGHT = 60
    public static let KEYCODE_TAB = 61
    public static let KEYCODE_SPACE = 62
    public static let KEYCODE_SYM = 63
    public static let KEYCODE_EXPLORER = 64
    public static let KEYCODE_ENVELOPE = 65
    public static let KEYCODE_ENTER = 66
    public static let KEYCODE_DEL = 67
    public static let KEYCODE_GRAVE = 68
    public static let KEYCODE_MINUS = 69
    public static let KEYCODE_EQUALS = 70
    public static let KEYCODE_LEFT_BRACKET = 71
    public static let KEYCODE_RIGHT_BRACKET = 72
    public static let KEYCODE_BACKSLASH = 73
    public static let KEYCODE_SEMICOLON = 74
    public static let KEYCODE_APOSTROPHE = 75
    public static let KEYCODE_SLASH = 76
    public static let KEYCODE_AT = 77
    public static let KEYCODE_PLUS = 81
    public static let KEYCODE_MENU = 82
    public static let KEYCODE_PAGE_UP = 92
    public static let KEYCODE_PAGE_DOWN = 93
    public static let KEYCODE_ESCAPE = 111
    public static let KEYCODE_FORWARD_DEL = 112
    public static let KEYCODE_CTRL_LEFT = 113
    public static let KEYCODE_CTRL_RIGHT = 114
    public static let KEYCODE_CAPS_LOCK = 115
    public static let KEYCODE_SCROLL_LOCK = 116
    public static let KEYCODE_META_LEFT = 117
    public static let KEYCODE_META_RIGHT = 118
    public static let KEYCODE_FUNCTION = 119
    public static let KEYCODE_SYSRQ = 120
    public static let KEYCODE_BREAK = 121
    public static let KEYCODE_MOVE_HOME = 122
    public static let KEYCODE_MOVE_END = 123
    public static let KEYCODE_INSERT = 124
    public static let KEYCODE_FORWARD = 125
    public static let KEYCODE_F1 = 131
    public static let KEYCODE_F2 = 132
    public static let KEYCODE_F3 = 133
    public static let KEYCODE_F4 = 134
    public static let KEYCODE_F5 = 135
    public static let KEYCODE_F6 = 136
    public static let KEYCODE_F7 = 137
    public static let KEYCODE_F8 = 138
    public static let KEYCODE_F9 = 139
    public static let KEYCODE_F10 = 140
    public static let KEYCODE_F11 = 141
    public static let KEYCODE_F12 = 142
    public static let KEYCODE_NUM_LOCK = 143
    public static let KEYCODE_NUMPAD_0 = 144
    public static let KEYCODE_NUMPAD_1 = 145
    public static let KEYCODE_NUMPAD_2 = 146
    public static let KEYCODE_NUMPAD_3 = 147
    public static let KEYCODE_NUMPAD_4 = 148
    public static let KEYCODE_NUMPAD_5 = 149
    public static let KEYCODE_NUMPAD_6 = 150
    public static let KEYCODE_NUMPAD_7 = 151
    public static let KEYCODE_NUMPAD_8 = 152
    public static let KEYCODE_NUMPAD_9 = 153
    public static let KEYCODE_NUMPAD_DIVIDE = 154
    public static let KEYCODE_NUMPAD_MULTIPLY = 155
    public static let KEYCODE_NUMPAD_SUBTRACT = 156
    public static let KEYCODE_NUMPAD_ADD = 157
    public static let KEYCODE_NUMPAD_DOT = 158
    public static let KEYCODE_NUMPAD_COMMA = 159
    public static let KEYCODE_NUMPAD_ENTER = 160
    public static let KEYCODE_NUMPAD_EQUALS = 161
    public static let KEYCODE_NUMPAD_LEFT_PAREN = 162
    public static let KEYCODE_NUMPAD_RIGHT_PAREN = 163

    // terminfo: http://pubs.opengroup.org/onlinepubs/7990989799/xcurses/terminfo.html
    // termcap: http://man7.org/linux/man-pages/man5/termcap.5.html
    private static let TERMCAP_TO_KEYCODE: [String: Int] = [
        "%i": KEYMOD_SHIFT | KEYCODE_DPAD_RIGHT,
        "#2": KEYMOD_SHIFT | KEYCODE_MOVE_HOME, // Shifted home
        "#4": KEYMOD_SHIFT | KEYCODE_DPAD_LEFT,
        "*7": KEYMOD_SHIFT | KEYCODE_MOVE_END, // Shifted end key
        "k1": KEYCODE_F1,
        "k2": KEYCODE_F2,
        "k3": KEYCODE_F3,
        "k4": KEYCODE_F4,
        "k5": KEYCODE_F5,
        "k6": KEYCODE_F6,
        "k7": KEYCODE_F7,
        "k8": KEYCODE_F8,
        "k9": KEYCODE_F9,
        "k;": KEYCODE_F10,
        "F1": KEYCODE_F11,
        "F2": KEYCODE_F12,
        "F3": KEYMOD_SHIFT | KEYCODE_F1,
        "F4": KEYMOD_SHIFT | KEYCODE_F2,
        "F5": KEYMOD_SHIFT | KEYCODE_F3,
        "F6": KEYMOD_SHIFT | KEYCODE_F4,
        "F7": KEYMOD_SHIFT | KEYCODE_F5,
        "F8": KEYMOD_SHIFT | KEYCODE_F6,
        "F9": KEYMOD_SHIFT | KEYCODE_F7,
        "FA": KEYMOD_SHIFT | KEYCODE_F8,
        "FB": KEYMOD_SHIFT | KEYCODE_F9,
        "FC": KEYMOD_SHIFT | KEYCODE_F10,
        "FD": KEYMOD_SHIFT | KEYCODE_F11,
        "FE": KEYMOD_SHIFT | KEYCODE_F12,
        "kb": KEYCODE_DEL, // backspace key
        "kd": KEYCODE_DPAD_DOWN, // terminfo=kcud1, down-arrow key
        "kh": KEYCODE_MOVE_HOME,
        "kl": KEYCODE_DPAD_LEFT,
        "kr": KEYCODE_DPAD_RIGHT,
        "K1": KEYCODE_MOVE_HOME,
        "K3": KEYCODE_PAGE_UP,
        "K4": KEYCODE_MOVE_END,
        "K5": KEYCODE_PAGE_DOWN,
        "ku": KEYCODE_DPAD_UP,
        "kB": KEYMOD_SHIFT | KEYCODE_TAB, // termcap=kB, terminfo=kcbt: Back-tab
        "kD": KEYCODE_FORWARD_DEL, // terminfo=kdch1, delete-character key
        "kDN": KEYMOD_SHIFT | KEYCODE_DPAD_DOWN, // non-standard shifted arrow down
        "kF": KEYMOD_SHIFT | KEYCODE_DPAD_DOWN, // terminfo=kind, scroll-forward key
        "kI": KEYCODE_INSERT,
        "kP": KEYCODE_PAGE_UP,
        "kN": KEYCODE_PAGE_DOWN,
        "kR": KEYMOD_SHIFT | KEYCODE_DPAD_UP, // terminfo=kri, scroll-backward key
        "kUP": KEYMOD_SHIFT | KEYCODE_DPAD_UP, // non-standard shifted up
        "@7": KEYCODE_MOVE_END,
        "@8": KEYCODE_NUMPAD_ENTER,
    ]

    public static func getCodeFromTermcap(_ termcap: String, cursorKeysApplication: Bool, keypadApplication: Bool) -> String? {
        guard var keyCode = TERMCAP_TO_KEYCODE[termcap] else { return nil }
        var keyMod = 0
        if (keyCode & KEYMOD_SHIFT) != 0 {
            keyMod |= KEYMOD_SHIFT
            keyCode &= ~KEYMOD_SHIFT
        }
        if (keyCode & KEYMOD_CTRL) != 0 {
            keyMod |= KEYMOD_CTRL
            keyCode &= ~KEYMOD_CTRL
        }
        if (keyCode & KEYMOD_ALT) != 0 {
            keyMod |= KEYMOD_ALT
            keyCode &= ~KEYMOD_ALT
        }
        if (keyCode & KEYMOD_NUM_LOCK) != 0 {
            keyMod |= KEYMOD_NUM_LOCK
            keyCode &= ~KEYMOD_NUM_LOCK
        }
        return getCode(keyCode: keyCode, keyMode: keyMod, cursorApp: cursorKeysApplication, keypadApplication: keypadApplication)
    }

    public static func getCode(keyCode: Int, keyMode keyModeIn: Int, cursorApp: Bool, keypadApplication: Bool) -> String? {
        let numLockOn = (keyModeIn & KEYMOD_NUM_LOCK) != 0
        let keyMode = keyModeIn & ~KEYMOD_NUM_LOCK
        switch keyCode {
        case KEYCODE_DPAD_CENTER:
            return "\r"

        case KEYCODE_DPAD_UP:
            return (keyMode == 0) ? (cursorApp ? "\u{1B}OA" : "\u{1B}[A") : transformForModifiers("\u{1B}[1", keyMode, "A")
        case KEYCODE_DPAD_DOWN:
            return (keyMode == 0) ? (cursorApp ? "\u{1B}OB" : "\u{1B}[B") : transformForModifiers("\u{1B}[1", keyMode, "B")
        case KEYCODE_DPAD_RIGHT:
            return (keyMode == 0) ? (cursorApp ? "\u{1B}OC" : "\u{1B}[C") : transformForModifiers("\u{1B}[1", keyMode, "C")
        case KEYCODE_DPAD_LEFT:
            return (keyMode == 0) ? (cursorApp ? "\u{1B}OD" : "\u{1B}[D") : transformForModifiers("\u{1B}[1", keyMode, "D")

        case KEYCODE_MOVE_HOME:
            // Note that KEYCODE_HOME is handled by the system and never delivered to applications.
            // On a Logitech k810 keyboard KEYCODE_MOVE_HOME is sent by FN+LeftArrow.
            return (keyMode == 0) ? (cursorApp ? "\u{1B}OH" : "\u{1B}[H") : transformForModifiers("\u{1B}[1", keyMode, "H")
        case KEYCODE_MOVE_END:
            return (keyMode == 0) ? (cursorApp ? "\u{1B}OF" : "\u{1B}[F") : transformForModifiers("\u{1B}[1", keyMode, "F")

        // An xterm can send function keys F1 to F4 in two modes: vt100 compatible or
        // not. Because Vim may not know what the xterm is sending, both types of keys
        // are recognized. The same happens for the <Home> and <End> keys.
        case KEYCODE_F1:
            return (keyMode == 0) ? "\u{1B}OP" : transformForModifiers("\u{1B}[1", keyMode, "P")
        case KEYCODE_F2:
            return (keyMode == 0) ? "\u{1B}OQ" : transformForModifiers("\u{1B}[1", keyMode, "Q")
        case KEYCODE_F3:
            return (keyMode == 0) ? "\u{1B}OR" : transformForModifiers("\u{1B}[1", keyMode, "R")
        case KEYCODE_F4:
            return (keyMode == 0) ? "\u{1B}OS" : transformForModifiers("\u{1B}[1", keyMode, "S")
        case KEYCODE_F5:
            return transformForModifiers("\u{1B}[15", keyMode, "~")
        case KEYCODE_F6:
            return transformForModifiers("\u{1B}[17", keyMode, "~")
        case KEYCODE_F7:
            return transformForModifiers("\u{1B}[18", keyMode, "~")
        case KEYCODE_F8:
            return transformForModifiers("\u{1B}[19", keyMode, "~")
        case KEYCODE_F9:
            return transformForModifiers("\u{1B}[20", keyMode, "~")
        case KEYCODE_F10:
            return transformForModifiers("\u{1B}[21", keyMode, "~")
        case KEYCODE_F11:
            return transformForModifiers("\u{1B}[23", keyMode, "~")
        case KEYCODE_F12:
            return transformForModifiers("\u{1B}[24", keyMode, "~")

        case KEYCODE_SYSRQ:
            return "\u{1B}[32~" // Sys Request / Print
        // Is this Scroll lock? case Cancel: return "\033[33~";
        case KEYCODE_BREAK:
            return "\u{1B}[34~" // Pause/Break

        case KEYCODE_ESCAPE, KEYCODE_BACK:
            return "\u{1B}"

        case KEYCODE_INSERT:
            return transformForModifiers("\u{1B}[2", keyMode, "~")
        case KEYCODE_FORWARD_DEL:
            return transformForModifiers("\u{1B}[3", keyMode, "~")

        case KEYCODE_PAGE_UP:
            return transformForModifiers("\u{1B}[5", keyMode, "~")
        case KEYCODE_PAGE_DOWN:
            return transformForModifiers("\u{1B}[6", keyMode, "~")
        case KEYCODE_DEL:
            let prefix = ((keyMode & KEYMOD_ALT) == 0) ? "" : "\u{1B}"
            // Just do what xterm and gnome-terminal does:
            return prefix + (((keyMode & KEYMOD_CTRL) == 0) ? "\u{7F}" : "\u{08}")
        case KEYCODE_NUM_LOCK:
            if keypadApplication {
                return "\u{1B}OP"
            } else {
                return nil
            }
        case KEYCODE_SPACE:
            // If ctrl is not down, return null so that it goes through normal input processing (which may e.g. cause a
            // combining accent to be written):
            return ((keyMode & KEYMOD_CTRL) == 0) ? nil : "\u{0}"
        case KEYCODE_TAB:
            // This is back-tab when shifted:
            return (keyMode & KEYMOD_SHIFT) == 0 ? "\t" : "\u{1B}[Z"
        case KEYCODE_ENTER:
            return ((keyMode & KEYMOD_ALT) == 0) ? "\r" : "\u{1B}\r"

        case KEYCODE_NUMPAD_ENTER:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "M") : "\n"
        case KEYCODE_NUMPAD_MULTIPLY:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "j") : "*"
        case KEYCODE_NUMPAD_ADD:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "k") : "+"
        case KEYCODE_NUMPAD_COMMA:
            return ","
        case KEYCODE_NUMPAD_DOT:
            if numLockOn {
                return keypadApplication ? "\u{1B}On" : "."
            } else {
                // DELETE
                return transformForModifiers("\u{1B}[3", keyMode, "~")
            }
        case KEYCODE_NUMPAD_SUBTRACT:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "m") : "-"
        case KEYCODE_NUMPAD_DIVIDE:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "o") : "/"
        case KEYCODE_NUMPAD_0:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "p") : "0"
            } else {
                // INSERT
                return transformForModifiers("\u{1B}[2", keyMode, "~")
            }
        case KEYCODE_NUMPAD_1:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "q") : "1"
            } else {
                // END
                return (keyMode == 0) ? (cursorApp ? "\u{1B}OF" : "\u{1B}[F") : transformForModifiers("\u{1B}[1", keyMode, "F")
            }
        case KEYCODE_NUMPAD_2:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "r") : "2"
            } else {
                // DOWN
                return (keyMode == 0) ? (cursorApp ? "\u{1B}OB" : "\u{1B}[B") : transformForModifiers("\u{1B}[1", keyMode, "B")
            }
        case KEYCODE_NUMPAD_3:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "s") : "3"
            } else {
                // PGDN
                return "\u{1B}[6~"
            }
        case KEYCODE_NUMPAD_4:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "t") : "4"
            } else {
                // LEFT
                return (keyMode == 0) ? (cursorApp ? "\u{1B}OD" : "\u{1B}[D") : transformForModifiers("\u{1B}[1", keyMode, "D")
            }
        case KEYCODE_NUMPAD_5:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "u") : "5"
        case KEYCODE_NUMPAD_6:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "v") : "6"
            } else {
                // RIGHT
                return (keyMode == 0) ? (cursorApp ? "\u{1B}OC" : "\u{1B}[C") : transformForModifiers("\u{1B}[1", keyMode, "C")
            }
        case KEYCODE_NUMPAD_7:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "w") : "7"
            } else {
                // HOME
                return (keyMode == 0) ? (cursorApp ? "\u{1B}OH" : "\u{1B}[H") : transformForModifiers("\u{1B}[1", keyMode, "H")
            }
        case KEYCODE_NUMPAD_8:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "x") : "8"
            } else {
                // UP
                return (keyMode == 0) ? (cursorApp ? "\u{1B}OA" : "\u{1B}[A") : transformForModifiers("\u{1B}[1", keyMode, "A")
            }
        case KEYCODE_NUMPAD_9:
            if numLockOn {
                return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "y") : "9"
            } else {
                // PGUP
                return "\u{1B}[5~"
            }
        case KEYCODE_NUMPAD_EQUALS:
            return keypadApplication ? transformForModifiers("\u{1B}O", keyMode, "X") : "="
        default:
            return nil
        }
    }

    private static func transformForModifiers(_ start: String, _ keymod: Int, _ lastChar: Character) -> String {
        let modifier: Int
        switch keymod {
        case KEYMOD_SHIFT:
            modifier = 2
        case KEYMOD_ALT:
            modifier = 3
        case KEYMOD_SHIFT | KEYMOD_ALT:
            modifier = 4
        case KEYMOD_CTRL:
            modifier = 5
        case KEYMOD_SHIFT | KEYMOD_CTRL:
            modifier = 6
        case KEYMOD_ALT | KEYMOD_CTRL:
            modifier = 7
        case KEYMOD_SHIFT | KEYMOD_ALT | KEYMOD_CTRL:
            modifier = 8
        default:
            return start + String(lastChar)
        }
        return start + ";\(modifier)" + String(lastChar)
    }
}

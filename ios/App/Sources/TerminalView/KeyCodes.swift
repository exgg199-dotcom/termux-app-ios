import Foundation

public enum AndroidKeyEvent {
    public static let KEYCODE_UNKNOWN = 0
    public static let KEYCODE_HOME = 3
    public static let KEYCODE_BACK = 4
    public static let KEYCODE_DPAD_UP = 19
    public static let KEYCODE_DPAD_DOWN = 20
    public static let KEYCODE_DPAD_LEFT = 21
    public static let KEYCODE_DPAD_RIGHT = 22
    public static let KEYCODE_DPAD_CENTER = 23
    public static let KEYCODE_TAB = 61
    public static let KEYCODE_SPACE = 62
    public static let KEYCODE_ENTER = 66
    public static let KEYCODE_DEL = 67
    public static let KEYCODE_PAGE_UP = 92
    public static let KEYCODE_PAGE_DOWN = 93
    public static let KEYCODE_ESCAPE = 111
    public static let KEYCODE_FORWARD_DEL = 112
    public static let KEYCODE_SYSRQ = 120
    public static let KEYCODE_BREAK = 121
    public static let KEYCODE_MOVE_HOME = 122
    public static let KEYCODE_MOVE_END = 123
    public static let KEYCODE_INSERT = 124
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

    public static func isNumpadKey(_ keyCode: Int) -> Bool {
        return keyCode >= KEYCODE_NUMPAD_0 && keyCode <= KEYCODE_NUMPAD_EQUALS
    }
}

public enum HardwareKeyMapper {
    public static let HID_RETURN = 0x28
    public static let HID_ESCAPE = 0x29
    public static let HID_BACKSPACE = 0x2A
    public static let HID_TAB = 0x2B
    public static let HID_SPACE = 0x2C
    public static let HID_F1 = 0x3A
    public static let HID_F12 = 0x45
    public static let HID_PRINT_SCREEN = 0x46
    public static let HID_PAUSE = 0x48
    public static let HID_INSERT = 0x49
    public static let HID_HOME = 0x4A
    public static let HID_PAGE_UP = 0x4B
    public static let HID_DELETE_FORWARD = 0x4C
    public static let HID_END = 0x4D
    public static let HID_PAGE_DOWN = 0x4E
    public static let HID_RIGHT_ARROW = 0x4F
    public static let HID_LEFT_ARROW = 0x50
    public static let HID_DOWN_ARROW = 0x51
    public static let HID_UP_ARROW = 0x52
    public static let HID_KEYPAD_NUM_LOCK = 0x53
    public static let HID_KEYPAD_SLASH = 0x54
    public static let HID_KEYPAD_ASTERISK = 0x55
    public static let HID_KEYPAD_HYPHEN = 0x56
    public static let HID_KEYPAD_PLUS = 0x57
    public static let HID_KEYPAD_ENTER = 0x58
    public static let HID_KEYPAD_1 = 0x59
    public static let HID_KEYPAD_9 = 0x61
    public static let HID_KEYPAD_0 = 0x62
    public static let HID_KEYPAD_PERIOD = 0x63
    public static let HID_KEYPAD_EQUAL_SIGN = 0x67
    public static let HID_F13 = 0x68
    public static let HID_KEYPAD_COMMA = 0x85
    public static let HID_LEFT_CONTROL = 0xE0
    public static let HID_LEFT_SHIFT = 0xE1
    public static let HID_LEFT_ALT = 0xE2
    public static let HID_LEFT_GUI = 0xE3
    public static let HID_RIGHT_CONTROL = 0xE4
    public static let HID_RIGHT_SHIFT = 0xE5
    public static let HID_RIGHT_ALT = 0xE6
    public static let HID_RIGHT_GUI = 0xE7

    public static func androidKeyCode(forHIDUsage usage: Int) -> Int? {
        switch usage {
        case HID_RETURN: return AndroidKeyEvent.KEYCODE_ENTER
        case HID_ESCAPE: return AndroidKeyEvent.KEYCODE_ESCAPE
        case HID_BACKSPACE: return AndroidKeyEvent.KEYCODE_DEL
        case HID_TAB: return AndroidKeyEvent.KEYCODE_TAB
        case HID_F1...HID_F12: return AndroidKeyEvent.KEYCODE_F1 + (usage - HID_F1)
        case HID_PRINT_SCREEN: return AndroidKeyEvent.KEYCODE_SYSRQ
        case HID_PAUSE: return AndroidKeyEvent.KEYCODE_BREAK
        case HID_INSERT: return AndroidKeyEvent.KEYCODE_INSERT
        case HID_HOME: return AndroidKeyEvent.KEYCODE_MOVE_HOME
        case HID_PAGE_UP: return AndroidKeyEvent.KEYCODE_PAGE_UP
        case HID_DELETE_FORWARD: return AndroidKeyEvent.KEYCODE_FORWARD_DEL
        case HID_END: return AndroidKeyEvent.KEYCODE_MOVE_END
        case HID_PAGE_DOWN: return AndroidKeyEvent.KEYCODE_PAGE_DOWN
        case HID_RIGHT_ARROW: return AndroidKeyEvent.KEYCODE_DPAD_RIGHT
        case HID_LEFT_ARROW: return AndroidKeyEvent.KEYCODE_DPAD_LEFT
        case HID_DOWN_ARROW: return AndroidKeyEvent.KEYCODE_DPAD_DOWN
        case HID_UP_ARROW: return AndroidKeyEvent.KEYCODE_DPAD_UP
        case HID_KEYPAD_NUM_LOCK: return AndroidKeyEvent.KEYCODE_NUM_LOCK
        case HID_KEYPAD_SLASH: return AndroidKeyEvent.KEYCODE_NUMPAD_DIVIDE
        case HID_KEYPAD_ASTERISK: return AndroidKeyEvent.KEYCODE_NUMPAD_MULTIPLY
        case HID_KEYPAD_HYPHEN: return AndroidKeyEvent.KEYCODE_NUMPAD_SUBTRACT
        case HID_KEYPAD_PLUS: return AndroidKeyEvent.KEYCODE_NUMPAD_ADD
        case HID_KEYPAD_ENTER: return AndroidKeyEvent.KEYCODE_NUMPAD_ENTER
        case HID_KEYPAD_1...HID_KEYPAD_9: return AndroidKeyEvent.KEYCODE_NUMPAD_1 + (usage - HID_KEYPAD_1)
        case HID_KEYPAD_0: return AndroidKeyEvent.KEYCODE_NUMPAD_0
        case HID_KEYPAD_PERIOD: return AndroidKeyEvent.KEYCODE_NUMPAD_DOT
        case HID_KEYPAD_EQUAL_SIGN: return AndroidKeyEvent.KEYCODE_NUMPAD_EQUALS
        case HID_KEYPAD_COMMA: return AndroidKeyEvent.KEYCODE_NUMPAD_COMMA
        default: return nil
        }
    }

    public static func isModifierKey(_ usage: Int) -> Bool {
        return usage >= HID_LEFT_CONTROL && usage <= HID_RIGHT_GUI
    }

    public static func fallbackCodePoint(forKeyCode keyCode: Int) -> Int? {
        switch keyCode {
        case AndroidKeyEvent.KEYCODE_SPACE: return 32
        case AndroidKeyEvent.KEYCODE_ENTER: return 13
        case AndroidKeyEvent.KEYCODE_TAB: return 9
        case AndroidKeyEvent.KEYCODE_NUMPAD_0...AndroidKeyEvent.KEYCODE_NUMPAD_9:
            return 48 + (keyCode - AndroidKeyEvent.KEYCODE_NUMPAD_0)
        case AndroidKeyEvent.KEYCODE_NUMPAD_DIVIDE: return 47
        case AndroidKeyEvent.KEYCODE_NUMPAD_MULTIPLY: return 42
        case AndroidKeyEvent.KEYCODE_NUMPAD_SUBTRACT: return 45
        case AndroidKeyEvent.KEYCODE_NUMPAD_ADD: return 43
        case AndroidKeyEvent.KEYCODE_NUMPAD_DOT: return 46
        case AndroidKeyEvent.KEYCODE_NUMPAD_COMMA: return 44
        case AndroidKeyEvent.KEYCODE_NUMPAD_EQUALS: return 61
        default: return nil
        }
    }
}

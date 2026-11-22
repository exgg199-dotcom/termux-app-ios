import Foundation

public enum ExtraKeysConstants {
    public static let PRIMARY_REPETITIVE_KEYS: [String] = [
        "UP", "DOWN", "LEFT", "RIGHT",
        "BKSP", "DEL",
        "PGUP", "PGDN",
    ]

    public static let PRIMARY_KEY_CODES_FOR_STRINGS: [String: Int] = [
        "SPACE": AndroidKeyEvent.KEYCODE_SPACE,
        "ESC": AndroidKeyEvent.KEYCODE_ESCAPE,
        "TAB": AndroidKeyEvent.KEYCODE_TAB,
        "HOME": AndroidKeyEvent.KEYCODE_MOVE_HOME,
        "END": AndroidKeyEvent.KEYCODE_MOVE_END,
        "PGUP": AndroidKeyEvent.KEYCODE_PAGE_UP,
        "PGDN": AndroidKeyEvent.KEYCODE_PAGE_DOWN,
        "INS": AndroidKeyEvent.KEYCODE_INSERT,
        "DEL": AndroidKeyEvent.KEYCODE_FORWARD_DEL,
        "BKSP": AndroidKeyEvent.KEYCODE_DEL,
        "UP": AndroidKeyEvent.KEYCODE_DPAD_UP,
        "LEFT": AndroidKeyEvent.KEYCODE_DPAD_LEFT,
        "RIGHT": AndroidKeyEvent.KEYCODE_DPAD_RIGHT,
        "DOWN": AndroidKeyEvent.KEYCODE_DPAD_DOWN,
        "ENTER": AndroidKeyEvent.KEYCODE_ENTER,
        "F1": AndroidKeyEvent.KEYCODE_F1,
        "F2": AndroidKeyEvent.KEYCODE_F2,
        "F3": AndroidKeyEvent.KEYCODE_F3,
        "F4": AndroidKeyEvent.KEYCODE_F4,
        "F5": AndroidKeyEvent.KEYCODE_F5,
        "F6": AndroidKeyEvent.KEYCODE_F6,
        "F7": AndroidKeyEvent.KEYCODE_F7,
        "F8": AndroidKeyEvent.KEYCODE_F8,
        "F9": AndroidKeyEvent.KEYCODE_F9,
        "F10": AndroidKeyEvent.KEYCODE_F10,
        "F11": AndroidKeyEvent.KEYCODE_F11,
        "F12": AndroidKeyEvent.KEYCODE_F12,
    ]

    public typealias ExtraKeyDisplayMap = [String: String]

    public enum EXTRA_KEY_DISPLAY_MAPS {
        public static let CLASSIC_ARROWS_DISPLAY: ExtraKeyDisplayMap = [
            "LEFT": "←",
            "RIGHT": "→",
            "UP": "↑",
            "DOWN": "↓",
        ]

        public static let WELL_KNOWN_CHARACTERS_DISPLAY: ExtraKeyDisplayMap = [
            "ENTER": "↲",
            "TAB": "↹",
            "BKSP": "⌫",
            "DEL": "⌦",
            "DRAWER": "☰",
            "KEYBOARD": "⌨",
            "PASTE": "⎘",
            "SCROLL": "⇳",
        ]

        public static let LESS_KNOWN_CHARACTERS_DISPLAY: ExtraKeyDisplayMap = [
            "HOME": "⇱",
            "END": "⇲",
            "PGUP": "⇑",
            "PGDN": "⇓",
        ]

        public static let ARROW_TRIANGLE_VARIATION_DISPLAY: ExtraKeyDisplayMap = [
            "LEFT": "◀",
            "RIGHT": "▶",
            "UP": "▲",
            "DOWN": "▼",
        ]

        public static let NOT_KNOWN_ISO_CHARACTERS: ExtraKeyDisplayMap = [
            "CTRL": "⎈",
            "ALT": "⎇",
            "ESC": "⎋",
        ]

        public static let NICER_LOOKING_DISPLAY: ExtraKeyDisplayMap = [
            "-": "―",
        ]

        public static let FULL_ISO_CHAR_DISPLAY: ExtraKeyDisplayMap = merge(
            CLASSIC_ARROWS_DISPLAY, WELL_KNOWN_CHARACTERS_DISPLAY, LESS_KNOWN_CHARACTERS_DISPLAY,
            NICER_LOOKING_DISPLAY, NOT_KNOWN_ISO_CHARACTERS)

        public static let ARROWS_ONLY_CHAR_DISPLAY: ExtraKeyDisplayMap = merge(
            CLASSIC_ARROWS_DISPLAY, NICER_LOOKING_DISPLAY)

        public static let LOTS_OF_ARROWS_CHAR_DISPLAY: ExtraKeyDisplayMap = merge(
            CLASSIC_ARROWS_DISPLAY, WELL_KNOWN_CHARACTERS_DISPLAY, LESS_KNOWN_CHARACTERS_DISPLAY,
            NICER_LOOKING_DISPLAY)

        public static let DEFAULT_CHAR_DISPLAY: ExtraKeyDisplayMap = merge(
            CLASSIC_ARROWS_DISPLAY, WELL_KNOWN_CHARACTERS_DISPLAY, NICER_LOOKING_DISPLAY)

        static func merge(_ maps: ExtraKeyDisplayMap...) -> ExtraKeyDisplayMap {
            var result = ExtraKeyDisplayMap()
            for map in maps {
                result.merge(map) { _, new in new }
            }
            return result
        }
    }

    public static let CONTROL_CHARS_ALIASES: ExtraKeyDisplayMap = [
        "ESCAPE": "ESC",
        "CONTROL": "CTRL",
        "SHFT": "SHIFT",
        "RETURN": "ENTER",
        "FUNCTION": "FN",

        "LT": "LEFT",
        "RT": "RIGHT",
        "DN": "DOWN",

        "PAGEUP": "PGUP",
        "PAGE_UP": "PGUP",
        "PAGE UP": "PGUP",
        "PAGE-UP": "PGUP",

        "PAGEDOWN": "PGDN",
        "PAGE_DOWN": "PGDN",
        "PAGE-DOWN": "PGDN",

        "DELETE": "DEL",
        "BACKSPACE": "BKSP",

        "BACKSLASH": "\\",
        "QUOTE": "\"",
        "APOSTROPHE": "'",
    ]
}

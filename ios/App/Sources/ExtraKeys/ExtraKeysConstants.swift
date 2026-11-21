import Foundation

/// Port of `com.termux.shared.termux.extrakeys.ExtraKeysConstants`.
///
/// UIKit-free so that it can be unit tested on any platform.
public enum ExtraKeysConstants {

    /// Defines the repetitive keys that can be passed to `ExtraKeysView.repetitiveKeys`.
    public static let PRIMARY_REPETITIVE_KEYS: [String] = [
        "UP", "DOWN", "LEFT", "RIGHT",
        "BKSP", "DEL",
        "PGUP", "PGDN",
    ]

    /// Defines the key codes (Android `KeyEvent.KEYCODE_*` values, see `AndroidKeyEvent`) for
    /// the primary keys of the extra keys row.
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

    /// A map from key name to display text. Port of `ExtraKeyDisplayMap` (a `CleverMap`).
    public typealias ExtraKeyDisplayMap = [String: String]

    /// Port of `ExtraKeysConstants.EXTRA_KEY_DISPLAY_MAPS`.
    public enum EXTRA_KEY_DISPLAY_MAPS {
        /// Classic arrow keys (for ◀ ▶ ▲ ▼ see `ARROW_TRIANGLE_VARIATION_DISPLAY`).
        public static let CLASSIC_ARROWS_DISPLAY: ExtraKeyDisplayMap = [
            "LEFT": "←", // U+2190 ← LEFTWARDS ARROW
            "RIGHT": "→", // U+2192 → RIGHTWARDS ARROW
            "UP": "↑", // U+2191 ↑ UPWARDS ARROW
            "DOWN": "↓", // U+2193 ↓ DOWNWARDS ARROW
        ]

        public static let WELL_KNOWN_CHARACTERS_DISPLAY: ExtraKeyDisplayMap = [
            "ENTER": "↲", // U+21B2 ↲ DOWNWARDS ARROW WITH TIP LEFTWARDS
            "TAB": "↹", // U+21B9 ↹ LEFTWARDS ARROW TO BAR OVER RIGHTWARDS ARROW TO BAR
            "BKSP": "⌫", // U+232B ⌫ ERASE TO THE LEFT
            "DEL": "⌦", // U+2326 ⌦ ERASE TO THE RIGHT
            "DRAWER": "☰", // U+2630 ☰ TRIGRAM FOR HEAVEN
            "KEYBOARD": "⌨", // U+2328 ⌨ KEYBOARD
            "PASTE": "⎘", // U+2398
            "SCROLL": "⇳", // U+21F3
        ]

        public static let LESS_KNOWN_CHARACTERS_DISPLAY: ExtraKeyDisplayMap = [
            "HOME": "⇱", // U+21F1 ⇱ NORTH WEST ARROW TO CORNER
            "END": "⇲", // U+21F2 ⇲ SOUTH EAST ARROW TO CORNER
            "PGUP": "⇑", // U+21D1 ⇑ UPWARDS DOUBLE ARROW
            "PGDN": "⇓", // U+21D3 ⇓ DOWNWARDS DOUBLE ARROW
        ]

        public static let ARROW_TRIANGLE_VARIATION_DISPLAY: ExtraKeyDisplayMap = [
            "LEFT": "◀", // U+25C0 ◀ BLACK LEFT-POINTING TRIANGLE
            "RIGHT": "▶", // U+25B6 ▶ BLACK RIGHT-POINTING TRIANGLE
            "UP": "▲", // U+25B2 ▲ BLACK UP-POINTING TRIANGLE
            "DOWN": "▼", // U+25BC ▼ BLACK DOWN-POINTING TRIANGLE
        ]

        public static let NOT_KNOWN_ISO_CHARACTERS: ExtraKeyDisplayMap = [
            "CTRL": "⎈", // U+2388 ⎈ HELM SYMBOL
            "ALT": "⎇", // U+2387 ⎇ ALTERNATIVE KEY SYMBOL
            "ESC": "⎋", // U+238B ⎋ BROKEN CIRCLE WITH NORTHWEST ARROW
        ]

        public static let NICER_LOOKING_DISPLAY: ExtraKeyDisplayMap = [
            "-": "―", // U+2015 ― HORIZONTAL BAR
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

    /// Aliases for the key names, so that e.g. `ESCAPE` can be used instead of `ESC`.
    public static let CONTROL_CHARS_ALIASES: ExtraKeyDisplayMap = [
        "ESCAPE": "ESC",
        "CONTROL": "CTRL",
        "SHFT": "SHIFT",
        "RETURN": "ENTER", // Technically different keys, but most applications won't see the difference
        "FUNCTION": "FN",
        // no alias for ALT

        // Directions are sometimes written as first and last letter for brevity
        "LT": "LEFT",
        "RT": "RIGHT",
        "DN": "DOWN",
        // "UP" is already two letters

        "PAGEUP": "PGUP",
        "PAGE_UP": "PGUP",
        "PAGE UP": "PGUP",
        "PAGE-UP": "PGUP",

        // no alias for HOME
        // no alias for END

        "PAGEDOWN": "PGDN",
        "PAGE_DOWN": "PGDN",
        "PAGE-DOWN": "PGDN",

        "DELETE": "DEL",
        "BACKSPACE": "BKSP",

        // easier for writing in termux.properties
        "BACKSLASH": "\\",
        "QUOTE": "\"",
        "APOSTROPHE": "'",
    ]
}

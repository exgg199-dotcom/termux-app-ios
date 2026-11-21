import Foundation

/// Encodes effects, foreground and background colors into a 64 bit integer, which are stored for each cell in a
/// terminal row in `TerminalRow.style`.
///
/// The bit layout is:
/// - 16 flags (11 currently used).
/// - 24 for foreground color (only 9 first bits if a color index).
/// - 24 for background color (only 9 first bits if a color index).
///
/// Colors are `Int` values: either an index in [0, 259) or a truecolor value `0xff_RRGGBB`.
public enum TextStyle {

    public static let CHARACTER_ATTRIBUTE_BOLD = 1
    public static let CHARACTER_ATTRIBUTE_ITALIC = 1 << 1
    public static let CHARACTER_ATTRIBUTE_UNDERLINE = 1 << 2
    public static let CHARACTER_ATTRIBUTE_BLINK = 1 << 3
    public static let CHARACTER_ATTRIBUTE_INVERSE = 1 << 4
    public static let CHARACTER_ATTRIBUTE_INVISIBLE = 1 << 5
    public static let CHARACTER_ATTRIBUTE_STRIKETHROUGH = 1 << 6
    /// The selective erase control functions (DECSED and DECSEL) can only erase characters defined as erasable.
    ///
    /// This bit is set if DECSCA (Select Character Protection Attribute) has been used to define the characters that
    /// come after it as erasable from the screen.
    public static let CHARACTER_ATTRIBUTE_PROTECTED = 1 << 7
    /// Dim colors. Also known as faint or half intensity.
    public static let CHARACTER_ATTRIBUTE_DIM = 1 << 8
    /// If true (24-bit) color is used for the cell for foreground.
    static let CHARACTER_ATTRIBUTE_TRUECOLOR_FOREGROUND = 1 << 9
    /// If true (24-bit) color is used for the cell for background.
    static let CHARACTER_ATTRIBUTE_TRUECOLOR_BACKGROUND = 1 << 10
    /// If set, character represents a terminal bitmap slice, not text.
    /// NOTE: Bitmaps (sixel / iTerm images) are not rendered by the iOS port, so this bit is never set by the
    /// emulator, but the encoding helpers are kept for parity.
    public static let TERMINAL_BITMAP = 1 << 15

    public static let COLOR_INDEX_FOREGROUND = 256
    public static let COLOR_INDEX_BACKGROUND = 257
    public static let COLOR_INDEX_CURSOR = 258

    /// The 256 standard color entries and the three special (foreground, background and cursor) ones.
    public static let NUM_INDEXED_COLORS = 259

    /// Normal foreground and background colors and no effects.
    public static let NORMAL: Int64 = encode(foreColor: COLOR_INDEX_FOREGROUND, backColor: COLOR_INDEX_BACKGROUND, effect: 0)

    public static func encode(foreColor: Int, backColor: Int, effect: Int) -> Int64 {
        var result = Int64(effect & 0b111111111)
        if (0xff000000 & foreColor) == 0xff000000 {
            // 24-bit color.
            result |= Int64(CHARACTER_ATTRIBUTE_TRUECOLOR_FOREGROUND) | ((Int64(foreColor) & 0x00ffffff) << 40)
        } else {
            // Indexed color.
            result |= (Int64(foreColor) & 0b111111111) << 40
        }
        if (0xff000000 & backColor) == 0xff000000 {
            // 24-bit color.
            result |= Int64(CHARACTER_ATTRIBUTE_TRUECOLOR_BACKGROUND) | ((Int64(backColor) & 0x00ffffff) << 16)
        } else {
            // Indexed color.
            result |= (Int64(backColor) & 0b111111111) << 16
        }
        return result
    }

    public static func decodeForeColor(_ style: Int64) -> Int {
        if (style & Int64(CHARACTER_ATTRIBUTE_TRUECOLOR_FOREGROUND)) == 0 {
            return Int((style >> 40) & 0b111111111)
        } else {
            return 0xff000000 | Int((style >> 40) & 0x00ffffff)
        }
    }

    public static func decodeBackColor(_ style: Int64) -> Int {
        if (style & Int64(CHARACTER_ATTRIBUTE_TRUECOLOR_BACKGROUND)) == 0 {
            return Int((style >> 16) & 0b111111111)
        } else {
            return 0xff000000 | Int((style >> 16) & 0x00ffffff)
        }
    }

    public static func decodeEffect(_ style: Int64) -> Int {
        return Int(style & 0b11111111111)
    }

    public static func encodeTerminalBitmap(num: Int, x: Int, y: Int) -> Int64 {
        return (Int64(x) << 48) | (Int64(y) << 32) | (Int64(num) << 16) | Int64(TERMINAL_BITMAP)
    }

    public static func isTerminalBitmap(_ style: Int64) -> Bool {
        return (style & Int64(TERMINAL_BITMAP)) != 0
    }

    public static func getTerminalBitmapNum(_ style: Int64) -> Int {
        return (style & Int64(TERMINAL_BITMAP)) != 0 ? Int((style & 0xffff0000) >> 16) : -1
    }

    public static func getTerminalBitmapX(_ style: Int64) -> Int {
        return (style & Int64(TERMINAL_BITMAP)) != 0 ? Int((style >> 48) & 0xfff) : -1
    }

    public static func getTerminalBitmapY(_ style: Int64) -> Int {
        return (style & Int64(TERMINAL_BITMAP)) != 0 ? Int((style >> 32) & 0xfff) : -1
    }
}

import Foundation

/// Current terminal colors (if different from default).
public final class TerminalColors {

    /// Static data - a bit ugly but ok for now. (Java: `COLOR_SCHEME`.)
    public static var colorScheme = TerminalColorScheme()

    /// The current terminal colors (ARGB), which are normally set from the color theme, but may be set dynamically
    /// with the OSC 4 control sequence. Size `TextStyle.NUM_INDEXED_COLORS`.
    public var currentColors: [UInt32] = [UInt32](repeating: 0, count: TextStyle.NUM_INDEXED_COLORS)

    /// Create a new instance with default colors from the theme.
    public init() {
        reset()
    }

    /// Reset a particular indexed color with the default color from the color theme.
    public func reset(_ index: Int) {
        currentColors[index] = TerminalColors.colorScheme.defaultColors[index]
    }

    /// Reset all indexed colors with the default color from the color theme.
    public func reset() {
        currentColors = TerminalColors.colorScheme.defaultColors
    }

    /// Parse color according to http://manpages.ubuntu.com/manpages/intrepid/man3/XQueryColor.3.html
    ///
    /// Highest bit is set if successful, so return value is 0xFF${R}${G}${B}. Return 0 if failed.
    public static func parse(_ c: String) -> UInt32 {
        let chars = Array(c.utf16)
        if chars.isEmpty { return 0 }
        let skipInitial: Int
        let skipBetween: Int
        if chars[0] == UInt16(UInt8(ascii: "#")) {
            // #RGB, #RRGGBB, #RRRGGGBBB or #RRRRGGGGBBBB. Most significant bits.
            skipInitial = 1
            skipBetween = 0
        } else if c.hasPrefix("rgb:") {
            // rgb:<red>/<green>/<blue> where <red>, <green>, <blue> := h | hh | hhh | hhhh. Scaled.
            skipInitial = 4
            skipBetween = 1
        } else {
            return 0
        }
        let charsForColors = chars.count - skipInitial - 2 * skipBetween
        if charsForColors % 3 != 0 { return 0 } // Unequal lengths.
        let componentLength = charsForColors / 3
        if componentLength <= 0 { return 0 }
        let mult = 255 / (pow(2.0, Double(componentLength * 4)) - 1)

        func component(_ start: Int) -> Int? {
            if start < 0 || start + componentLength > chars.count { return nil }
            let s = String(decoding: chars[start..<(start + componentLength)], as: UTF16.self)
            guard let value = Int(s, radix: 16), value >= Int(Int32.min), value <= Int(Int32.max) else { return nil }
            return value
        }

        var currentPosition = skipInitial
        guard let rValue = component(currentPosition) else { return 0 }
        currentPosition += componentLength + skipBetween
        guard let gValue = component(currentPosition) else { return 0 }
        currentPosition += componentLength + skipBetween
        guard let bValue = component(currentPosition) else { return 0 }

        let r = Int(Double(rValue) * mult) & 0xFF
        let g = Int(Double(gValue) * mult) & 0xFF
        let b = Int(Double(bValue) * mult) & 0xFF
        return UInt32(0xFF << 24 | r << 16 | g << 8 | b)
    }

    /// Try parse a color from a text parameter and into a specified index.
    public func tryParseColor(_ intoIndex: Int, _ textParameter: String) {
        let c = TerminalColors.parse(textParameter)
        if c != 0 { currentColors[intoIndex] = c }
    }

    /// Get the perceived brightness of the color based on its RGB components.
    ///
    /// https://www.nbdtech.com/Blog/archive/2008/04/27/Calculating-the-Perceived-Brightness-of-a-Color.aspx
    /// http://alienryderflex.com/hsp.html
    ///
    /// - Parameter color: The ARGB color.
    /// - Returns: Value between 0-255.
    public static func getPerceivedBrightnessOfColor(_ color: UInt32) -> Int {
        let red = Double((color >> 16) & 0xFF)
        let green = Double((color >> 8) & 0xFF)
        let blue = Double(color & 0xFF)
        return Int(floor(sqrt(red * red * 0.241 + green * green * 0.691 + blue * blue * 0.068)))
    }
}

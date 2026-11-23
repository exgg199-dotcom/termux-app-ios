import Foundation

public final class TerminalColors {

    public static var colorScheme = TerminalColorScheme()

    public var currentColors: [UInt32] = [UInt32](repeating: 0, count: TextStyle.NUM_INDEXED_COLORS)

    public init() {
        reset()
    }

    public func reset(_ index: Int) {
        currentColors[index] = TerminalColors.colorScheme.defaultColors[index]
    }

    public func reset() {
        currentColors = TerminalColors.colorScheme.defaultColors
    }

    public static func parse(_ c: String) -> UInt32 {
        let chars = Array(c.utf16)
        if chars.isEmpty { return 0 }
        let skipInitial: Int
        let skipBetween: Int
        if chars[0] == UInt16(UInt8(ascii: "#")) {
            skipInitial = 1
            skipBetween = 0
        } else if c.hasPrefix("rgb:") {
            skipInitial = 4
            skipBetween = 1
        } else {
            return 0
        }
        let charsForColors = chars.count - skipInitial - 2 * skipBetween
        if charsForColors % 3 != 0 { return 0 }
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

    public func tryParseColor(_ intoIndex: Int, _ textParameter: String) {
        let c = TerminalColors.parse(textParameter)
        if c != 0 { currentColors[intoIndex] = c }
    }

    public static func getPerceivedBrightnessOfColor(_ color: UInt32) -> Int {
        let red = Double((color >> 16) & 0xFF)
        let green = Double((color >> 8) & 0xFF)
        let blue = Double(color & 0xFF)
        return Int(floor(sqrt(red * red * 0.241 + green * green * 0.691 + blue * blue * 0.068)))
    }
}

import Foundation

public final class TerminalRow {

    private static let SPARE_CAPACITY_FACTOR: Float = 1.5

    static let MAX_COMBINING_CHARACTERS_PER_COLUMN = 15

    let columns: Int
    public var text: [UInt16]
    public private(set) var spaceUsed: Int = 0
    public var lineWrap: Bool = false
    var style: [Int64]
    var hasNonOneWidthOrSurrogateChars = false
    public var hasTerminalBitmap = false

    public init(_ columns: Int, _ style: Int64) {
        self.columns = columns
        self.text = [UInt16](repeating: 0, count: Int(TerminalRow.SPARE_CAPACITY_FACTOR * Float(columns)))
        self.style = [Int64](repeating: 0, count: columns)
        clear(style)
    }

    public func copyInterval(_ line: TerminalRow, _ sourceX1In: Int, _ sourceX2: Int, _ destinationXIn: Int) {
        var sourceX1 = sourceX1In
        var destinationX = destinationXIn
        hasNonOneWidthOrSurrogateChars = hasNonOneWidthOrSurrogateChars || line.hasNonOneWidthOrSurrogateChars
        let x1 = line.findStartOfColumn(sourceX1)
        let x2 = line.findStartOfColumn(sourceX2)
        var startingFromSecondHalfOfWideChar = (sourceX1 > 0 && line.wideDisplayCharacterStartingAt(sourceX1 - 1))
        let sourceChars = line.text
        var latestNonCombiningWidth = 0
        var i = x1
        while i < x2 {
            let sourceChar = sourceChars[i]
            var codePoint: Int
            if UTF16Util.isHighSurrogate(sourceChar) {
                i += 1
                codePoint = UTF16Util.toCodePoint(sourceChar, sourceChars[i])
            } else {
                codePoint = Int(sourceChar)
            }
            if startingFromSecondHalfOfWideChar {
                codePoint = 32
                startingFromSecondHalfOfWideChar = false
            }
            let w = WcWidth.width(codePoint)
            if w > 0 {
                destinationX += latestNonCombiningWidth
                sourceX1 += latestNonCombiningWidth
                latestNonCombiningWidth = w
            }
            setChar(destinationX, codePoint, line.getStyle(sourceX1))
            i += 1
        }
    }

    public func findStartOfColumn(_ column: Int) -> Int {
        if column == columns { return spaceUsed }

        var currentColumn = 0
        var currentCharIndex = 0
        while true {
            var newCharIndex = currentCharIndex
            let c = text[newCharIndex]
            newCharIndex += 1
            let isHigh = UTF16Util.isHighSurrogate(c)
            let codePoint: Int
            if isHigh {
                codePoint = UTF16Util.toCodePoint(c, text[newCharIndex])
                newCharIndex += 1
            } else {
                codePoint = Int(c)
            }
            let wcwidth = WcWidth.width(codePoint)
            if wcwidth > 0 {
                currentColumn += wcwidth
                if currentColumn == column {
                    while newCharIndex < spaceUsed {
                        if UTF16Util.isHighSurrogate(text[newCharIndex]) {
                            if WcWidth.width(UTF16Util.toCodePoint(text[newCharIndex], text[newCharIndex + 1])) <= 0 {
                                newCharIndex += 2
                            } else {
                                break
                            }
                        } else if WcWidth.width(Int(text[newCharIndex])) <= 0 {
                            newCharIndex += 1
                        } else {
                            break
                        }
                    }
                    return newCharIndex
                } else if currentColumn > column {
                    return currentCharIndex
                }
            }
            currentCharIndex = newCharIndex
        }
    }

    private func wideDisplayCharacterStartingAt(_ column: Int) -> Bool {
        var currentCharIndex = 0
        var currentColumn = 0
        while currentCharIndex < spaceUsed {
            let c = text[currentCharIndex]
            currentCharIndex += 1
            let codePoint: Int
            if UTF16Util.isHighSurrogate(c) {
                codePoint = UTF16Util.toCodePoint(c, text[currentCharIndex])
                currentCharIndex += 1
            } else {
                codePoint = Int(c)
            }
            let wcwidth = WcWidth.width(codePoint)
            if wcwidth > 0 {
                if currentColumn == column && wcwidth == 2 { return true }
                currentColumn += wcwidth
                if currentColumn > column { return false }
            }
        }
        return false
    }

    public func clear(_ style: Int64) {
        for i in 0..<text.count { text[i] = 32 }
        for i in 0..<self.style.count { self.style[i] = style }
        spaceUsed = columns
        hasNonOneWidthOrSurrogateChars = false
        hasTerminalBitmap = false
    }

    public func setChar(_ columnToSetIn: Int, _ codePoint: Int, _ style: Int64) {
        var columnToSet = columnToSetIn
        if columnToSet < 0 || columnToSet >= self.style.count {
            preconditionFailure("TerminalRow.setChar(): columnToSet=\(columnToSet), codePoint=\(codePoint), style=\(style)")
        }

        self.style[columnToSet] = style

        if !hasTerminalBitmap && TextStyle.isTerminalBitmap(style) {
            hasTerminalBitmap = true
        }

        let newCodePointDisplayWidth = WcWidth.width(codePoint)

        if !hasNonOneWidthOrSurrogateChars {
            if codePoint >= UTF16Util.MIN_SUPPLEMENTARY_CODE_POINT || newCodePointDisplayWidth != 1 {
                hasNonOneWidthOrSurrogateChars = true
            } else {
                text[columnToSet] = UInt16(truncatingIfNeeded: codePoint)
                return
            }
        }

        let newIsCombining = newCodePointDisplayWidth <= 0

        let wasExtraColForWideChar = (columnToSet > 0) && wideDisplayCharacterStartingAt(columnToSet - 1)

        if newIsCombining {
            if wasExtraColForWideChar { columnToSet -= 1 }
        } else {
            if wasExtraColForWideChar { setChar(columnToSet - 1, 32, style) }
            let overwritingWideCharInNextColumn = newCodePointDisplayWidth == 2 && wideDisplayCharacterStartingAt(columnToSet + 1)
            if overwritingWideCharInNextColumn { setChar(columnToSet + 1, 32, style) }
        }

        let oldStartOfColumnIndex = findStartOfColumn(columnToSet)
        let oldCodePointDisplayWidth = WcWidth.width(text, oldStartOfColumnIndex)

        let oldCharactersUsedForColumn: Int
        if columnToSet + oldCodePointDisplayWidth < columns {
            let oldEndOfColumnIndex = findStartOfColumn(columnToSet + oldCodePointDisplayWidth)
            oldCharactersUsedForColumn = oldEndOfColumnIndex - oldStartOfColumnIndex
        } else {
            oldCharactersUsedForColumn = spaceUsed - oldStartOfColumnIndex
        }

        if newIsCombining {
            let combiningCharsCount = WcWidth.zeroWidthCharsCount(text, oldStartOfColumnIndex, oldStartOfColumnIndex + oldCharactersUsedForColumn)
            if combiningCharsCount >= TerminalRow.MAX_COMBINING_CHARACTERS_PER_COLUMN {
                return
            }
        }

        var newCharactersUsedForColumn = UTF16Util.charCount(codePoint)
        if newIsCombining {
            newCharactersUsedForColumn += oldCharactersUsedForColumn
        }

        let oldNextColumnIndex = oldStartOfColumnIndex + oldCharactersUsedForColumn
        let newNextColumnIndex = oldStartOfColumnIndex + newCharactersUsedForColumn

        let javaCharDifference = newCharactersUsedForColumn - oldCharactersUsedForColumn
        if javaCharDifference > 0 {
            let oldCharactersAfterColumn = spaceUsed - oldNextColumnIndex
            if spaceUsed + javaCharDifference > text.count {
                var newText = [UInt16](repeating: 0, count: text.count + columns)
                TerminalRow.arraycopy(text, 0, &newText, 0, oldNextColumnIndex)
                TerminalRow.arraycopy(text, oldNextColumnIndex, &newText, newNextColumnIndex, oldCharactersAfterColumn)
                text = newText
            } else {
                TerminalRow.arraycopyInPlace(&text, oldNextColumnIndex, newNextColumnIndex, oldCharactersAfterColumn)
            }
        } else if javaCharDifference < 0 {
            TerminalRow.arraycopyInPlace(&text, oldNextColumnIndex, newNextColumnIndex, spaceUsed - oldNextColumnIndex)
        }
        spaceUsed += javaCharDifference

        UTF16Util.toChars(codePoint, &text, oldStartOfColumnIndex + (newIsCombining ? oldCharactersUsedForColumn : 0))

        if oldCodePointDisplayWidth == 2 && newCodePointDisplayWidth == 1 {
            if spaceUsed + 1 > text.count {
                var newText = [UInt16](repeating: 0, count: text.count + columns)
                TerminalRow.arraycopy(text, 0, &newText, 0, newNextColumnIndex)
                TerminalRow.arraycopy(text, newNextColumnIndex, &newText, newNextColumnIndex + 1, spaceUsed - newNextColumnIndex)
                text = newText
            } else {
                TerminalRow.arraycopyInPlace(&text, newNextColumnIndex, newNextColumnIndex + 1, spaceUsed - newNextColumnIndex)
            }
            text[newNextColumnIndex] = 32

            spaceUsed += 1
        } else if oldCodePointDisplayWidth == 1 && newCodePointDisplayWidth == 2 {
            if columnToSet == columns - 1 {
                preconditionFailure("Cannot put wide character in last column")
            } else if columnToSet == columns - 2 {
                spaceUsed = newNextColumnIndex
            } else {
                let newNextNextColumnIndex = newNextColumnIndex + (UTF16Util.isHighSurrogate(text[newNextColumnIndex]) ? 2 : 1)
                let nextLen = newNextNextColumnIndex - newNextColumnIndex

                TerminalRow.arraycopyInPlace(&text, newNextNextColumnIndex, newNextColumnIndex, spaceUsed - newNextNextColumnIndex)
                spaceUsed -= nextLen
            }
        }
    }

    func isBlank() -> Bool {
        for charIndex in 0..<spaceUsed {
            if text[charIndex] != 32 { return false }
        }
        return true
    }

    public func getStyle(_ column: Int) -> Int64 {
        return style[column]
    }

    @inline(__always)
    static func arraycopy(_ src: [UInt16], _ srcPos: Int, _ dst: inout [UInt16], _ dstPos: Int, _ length: Int) {
        if length <= 0 { return }
        dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                for k in 0..<length { d[dstPos + k] = s[srcPos + k] }
            }
        }
    }

    @inline(__always)
    static func arraycopyInPlace(_ array: inout [UInt16], _ srcPos: Int, _ dstPos: Int, _ length: Int) {
        if length <= 0 || srcPos == dstPos { return }
        precondition(srcPos >= 0 && dstPos >= 0 && srcPos + length <= array.count && dstPos + length <= array.count,
                     "arraycopy out of bounds")
        array.withUnsafeMutableBufferPointer { a in
            if srcPos < dstPos {
                var k = length - 1
                while k >= 0 { a[dstPos + k] = a[srcPos + k]; k -= 1 }
            } else {
                for k in 0..<length { a[dstPos + k] = a[srcPos + k] }
            }
        }
    }
}

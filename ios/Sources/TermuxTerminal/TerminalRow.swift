import Foundation

/// A row in a terminal, composed of a fixed number of cells.
///
/// The text in the row is stored in a UTF-16 `[UInt16]` array, `text`, for quick access during rendering
/// (like the Java `char[] mText`).
public final class TerminalRow {

    private static let SPARE_CAPACITY_FACTOR: Float = 1.5

    /// Max combining characters that can exist in a column, that are separate from the base character
    /// itself. Any additional combining characters will be ignored and not added to the column.
    ///
    /// We choose the value 15 because it should be enough for terminal based applications and keep
    /// the memory usage low for a terminal row, won't affect performance or cause terminal to
    /// lag or hang, and will keep malicious applications from causing harm.
    static let MAX_COMBINING_CHARACTERS_PER_COLUMN = 15

    /// The number of columns in this terminal row.
    let columns: Int
    /// The text filling this terminal row (UTF-16 code units, like Java char[]).
    public var text: [UInt16]
    /// The number of UTF-16 code units used in `text`.
    public private(set) var spaceUsed: Int = 0
    /// If this row has been line wrapped due to text output at the end of line.
    public var lineWrap: Bool = false
    /// The style bits of each cell in the row. See `TextStyle`.
    var style: [Int64]
    /// If this row might contain chars with width != 1, used for deactivating fast path.
    var hasNonOneWidthOrSurrogateChars = false
    /// If this row has a terminal bitmap. Used for performance only. Never set on iOS (bitmaps are not supported).
    public var hasTerminalBitmap = false

    /// Construct a blank row (containing only whitespace, ' ') with a specified style.
    public init(_ columns: Int, _ style: Int64) {
        self.columns = columns
        self.text = [UInt16](repeating: 0, count: Int(TerminalRow.SPARE_CAPACITY_FACTOR * Float(columns)))
        self.style = [Int64](repeating: 0, count: columns)
        clear(style)
    }

    /// NOTE: The sourceX2 is exclusive.
    public func copyInterval(_ line: TerminalRow, _ sourceX1In: Int, _ sourceX2: Int, _ destinationXIn: Int) {
        var sourceX1 = sourceX1In
        var destinationX = destinationXIn
        hasNonOneWidthOrSurrogateChars = hasNonOneWidthOrSurrogateChars || line.hasNonOneWidthOrSurrogateChars
        let x1 = line.findStartOfColumn(sourceX1)
        let x2 = line.findStartOfColumn(sourceX2)
        var startingFromSecondHalfOfWideChar = (sourceX1 > 0 && line.wideDisplayCharacterStartingAt(sourceX1 - 1))
        // Value copy (copy-on-write), so this is safe also when line === self.
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
                // Just treat copying second half of wide char as copying whitespace.
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

    /// Note that the column may end of second half of wide character.
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
                        // Skip combining chars.
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
                    // Wide column going past end.
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

    // https://github.com/steven676/Android-Terminal-Emulator/commit/9a47042620bec87617f0b4f5d50568535668fe26
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

        // Fast path when we don't have any chars with width != 1
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
            // When standing at second half of wide character and inserting combining:
            if wasExtraColForWideChar { columnToSet -= 1 }
        } else {
            // Check if we are overwriting the second half of a wide character starting at the previous column:
            if wasExtraColForWideChar { setChar(columnToSet - 1, 32, style) }
            // Check if we are overwriting the first half of a wide character starting at the next column:
            let overwritingWideCharInNextColumn = newCodePointDisplayWidth == 2 && wideDisplayCharacterStartingAt(columnToSet + 1)
            if overwritingWideCharInNextColumn { setChar(columnToSet + 1, 32, style) }
        }

        let oldStartOfColumnIndex = findStartOfColumn(columnToSet)
        let oldCodePointDisplayWidth = WcWidth.width(text, oldStartOfColumnIndex)

        // Get the number of elements in the text array this column uses now
        let oldCharactersUsedForColumn: Int
        if columnToSet + oldCodePointDisplayWidth < columns {
            let oldEndOfColumnIndex = findStartOfColumn(columnToSet + oldCodePointDisplayWidth)
            oldCharactersUsedForColumn = oldEndOfColumnIndex - oldStartOfColumnIndex
        } else {
            // Last character.
            oldCharactersUsedForColumn = spaceUsed - oldStartOfColumnIndex
        }

        // If MAX_COMBINING_CHARACTERS_PER_COLUMN already exist in column, then ignore adding additional combining characters.
        if newIsCombining {
            let combiningCharsCount = WcWidth.zeroWidthCharsCount(text, oldStartOfColumnIndex, oldStartOfColumnIndex + oldCharactersUsedForColumn)
            if combiningCharsCount >= TerminalRow.MAX_COMBINING_CHARACTERS_PER_COLUMN {
                return
            }
        }

        // Find how many chars this column will need
        var newCharactersUsedForColumn = UTF16Util.charCount(codePoint)
        if newIsCombining {
            // Combining characters are added to the contents of the column instead of overwriting them, so that they
            // modify the existing contents.
            // FIXME: Unassigned characters also get width=0.
            newCharactersUsedForColumn += oldCharactersUsedForColumn
        }

        let oldNextColumnIndex = oldStartOfColumnIndex + oldCharactersUsedForColumn
        let newNextColumnIndex = oldStartOfColumnIndex + newCharactersUsedForColumn

        let javaCharDifference = newCharactersUsedForColumn - oldCharactersUsedForColumn
        if javaCharDifference > 0 {
            // Shift the rest of the line right.
            let oldCharactersAfterColumn = spaceUsed - oldNextColumnIndex
            if spaceUsed + javaCharDifference > text.count {
                // We need to grow the array
                var newText = [UInt16](repeating: 0, count: text.count + columns)
                TerminalRow.arraycopy(text, 0, &newText, 0, oldNextColumnIndex)
                TerminalRow.arraycopy(text, oldNextColumnIndex, &newText, newNextColumnIndex, oldCharactersAfterColumn)
                text = newText
            } else {
                TerminalRow.arraycopyInPlace(&text, oldNextColumnIndex, newNextColumnIndex, oldCharactersAfterColumn)
            }
        } else if javaCharDifference < 0 {
            // Shift the rest of the line left.
            TerminalRow.arraycopyInPlace(&text, oldNextColumnIndex, newNextColumnIndex, spaceUsed - oldNextColumnIndex)
        }
        spaceUsed += javaCharDifference

        // Store char. A combining character is stored at the end of the existing contents so that it modifies them:
        UTF16Util.toChars(codePoint, &text, oldStartOfColumnIndex + (newIsCombining ? oldCharactersUsedForColumn : 0))

        if oldCodePointDisplayWidth == 2 && newCodePointDisplayWidth == 1 {
            // Replace second half of wide char with a space. Which mean that we actually add a ' ' java character.
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
                // Truncate the line to the second part of this wide char:
                spaceUsed = newNextColumnIndex
            } else {
                // Overwrite the contents of the next column, which mean we actually remove java characters. Due to the
                // check at the beginning of this method we know that we are not overwriting a wide char.
                let newNextNextColumnIndex = newNextColumnIndex + (UTF16Util.isHighSurrogate(text[newNextColumnIndex]) ? 2 : 1)
                let nextLen = newNextNextColumnIndex - newNextColumnIndex

                // Shift the array leftwards.
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

    // MARK: - System.arraycopy equivalents

    @inline(__always)
    static func arraycopy(_ src: [UInt16], _ srcPos: Int, _ dst: inout [UInt16], _ dstPos: Int, _ length: Int) {
        if length <= 0 { return }
        dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                for k in 0..<length { d[dstPos + k] = s[srcPos + k] }
            }
        }
    }

    /// Overlap-safe copy within the same array, like `System.arraycopy(a, srcPos, a, dstPos, length)`.
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

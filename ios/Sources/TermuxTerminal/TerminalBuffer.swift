import Foundation

public final class TerminalBuffer {

    public static let LOG_TAG = "TerminalBuffer"

    private(set) var client: TerminalSessionClient?

    var lines: [TerminalRow?]
    var totalRows: Int
    public internal(set) var screenRows: Int
    public internal(set) var columns: Int
    public private(set) var activeTranscriptRows: Int = 0
    private var screenFirstRow = 0

    public convenience init(columns: Int, totalRows: Int, screenRows: Int) {
        self.init(client: nil, columns: columns, totalRows: totalRows, screenRows: screenRows)
    }

    public init(client: TerminalSessionClient?, columns: Int, totalRows: Int, screenRows: Int) {
        self.client = client
        self.columns = columns
        self.totalRows = totalRows
        self.screenRows = screenRows
        self.lines = [TerminalRow?](repeating: nil, count: totalRows)

        blockSet(0, 0, columns, screenRows, 32, TextStyle.NORMAL)
    }

    func updateClient(_ client: TerminalSessionClient?) {
        self.client = client
    }

    public var transcriptText: String {
        return getSelectedText(selX1: 0, selY1: -activeTranscriptRows, selX2: columns, selY2: screenRows).javaTrimmed()
    }

    public var transcriptTextWithoutJoinedLines: String {
        return getSelectedText(selX1: 0, selY1: -activeTranscriptRows, selX2: columns, selY2: screenRows, joinBackLines: false).javaTrimmed()
    }

    public var transcriptTextWithFullLinesJoined: String {
        return getSelectedText(selX1: 0, selY1: -activeTranscriptRows, selX2: columns, selY2: screenRows, joinBackLines: true, joinFullLines: true).javaTrimmed()
    }

    public func getSelectedText(selX1: Int, selY1: Int, selX2: Int, selY2: Int) -> String {
        return getSelectedText(selX1: selX1, selY1: selY1, selX2: selX2, selY2: selY2, joinBackLines: true, joinFullLines: false)
    }

    public func getSelectedText(selX1: Int, selY1: Int, selX2: Int, selY2: Int, joinBackLines: Bool, joinFullLines: Bool = false) -> String {
        return UTF16Util.string(getSelectedChars(selX1, selY1, selX2, selY2, joinBackLines, joinFullLines))
    }

    func getSelectedChars(_ selX1: Int, _ selY1In: Int, _ selX2: Int, _ selY2In: Int, _ joinBackLines: Bool, _ joinFullLines: Bool) -> [UInt16] {
        var builder = [UInt16]()
        let columns = self.columns
        var selY1 = selY1In
        var selY2 = selY2In

        if selY1 < -activeTranscriptRows { selY1 = -activeTranscriptRows }
        if selY2 >= screenRows { selY2 = screenRows - 1 }

        if selY1 > selY2 { return builder }
        for row in selY1...selY2 {
            let x1 = (row == selY1) ? selX1 : 0
            var x2: Int
            if row == selY2 {
                x2 = selX2 + 1
                if x2 > columns { x2 = columns }
            } else {
                x2 = columns
            }
            let lineObject = allocateFullLineIfNecessary(externalToInternalRow(row))
            let x1Index = lineObject.findStartOfColumn(x1)
            var x2Index = (x2 < self.columns) ? lineObject.findStartOfColumn(x2) : lineObject.spaceUsed
            if x2Index == x1Index {
                x2Index = lineObject.findStartOfColumn(x2 + 1)
            }
            let line = lineObject.text
            var lastPrintingCharIndex = -1
            let rowLineWrap = getLineWrap(row)
            if rowLineWrap && x2 == columns {
                lastPrintingCharIndex = x2Index - 1
            } else {
                var i = x1Index
                while i < x2Index {
                    if line[i] != 32 { lastPrintingCharIndex = i }
                    i += 1
                }
            }

            let len = lastPrintingCharIndex - x1Index + 1
            if lastPrintingCharIndex != -1 && len > 0 {
                builder.append(contentsOf: line[x1Index..<(x1Index + len)])
            }

            let lineFillsWidth = lastPrintingCharIndex == x2Index - 1
            if (!joinBackLines || !rowLineWrap) && (!joinFullLines || !lineFillsWidth)
                && row < selY2 && row < screenRows - 1 {
                builder.append(10)
            }
        }
        return builder
    }

    public func getWordAtLocation(x: Int, y: Int) -> String {
        var y1 = y
        var y2 = y
        while y1 > 0 && !getSelectedChars(0, y1 - 1, columns, y, true, true).contains(10) {
            y1 -= 1
        }
        while y2 < screenRows && !getSelectedChars(0, y, columns, y2 + 1, true, true).contains(10) {
            y2 += 1
        }

        let text = getSelectedChars(0, y1, columns, y2, true, true)
        let textOffset = (y - y1) * columns + x

        if textOffset >= text.count {
            return ""
        }

        var x1 = -1
        if textOffset >= 0 {
            var i = textOffset
            while i >= 0 { if text[i] == 32 { x1 = i; break }; i -= 1 }
        }
        var x2 = -1
        var j = max(0, textOffset)
        while j < text.count { if text[j] == 32 { x2 = j; break }; j += 1 }
        if x2 == -1 {
            x2 = text.count
        }

        if x1 == x2 {
            return ""
        }
        return UTF16Util.string(text[(x1 + 1)..<x2])
    }

    public var activeRows: Int {
        return activeTranscriptRows + screenRows
    }

    public func externalToInternalRow(_ externalRow: Int) -> Int {
        if externalRow < -activeTranscriptRows || externalRow > screenRows {
            preconditionFailure("extRow=\(externalRow), mScreenRows=\(screenRows), mActiveTranscriptRows=\(activeTranscriptRows)")
        }
        let internalRow = screenFirstRow + externalRow
        return (internalRow < 0) ? (totalRows + internalRow) : (internalRow % totalRows)
    }

    public func setLineWrap(_ row: Int) {
        allocateFullLineIfNecessary(externalToInternalRow(row)).lineWrap = true
    }

    public func getLineWrap(_ row: Int) -> Bool {
        return lines[externalToInternalRow(row)]?.lineWrap ?? false
    }

    public func clearLineWrap(_ row: Int) {
        lines[externalToInternalRow(row)]?.lineWrap = false
    }

    public func resize(_ newColumns: Int, _ newRows: Int, _ newTotalRows: Int, _ cursor: inout [Int], _ currentStyle: Int64, _ altScreen: Bool) {
        if newColumns == columns && newRows <= totalRows {
            var shiftDownOfTopRow = screenRows - newRows
            if shiftDownOfTopRow > 0 && shiftDownOfTopRow < screenRows {
                var i = screenRows - 1
                while i > 0 {
                    if cursor[1] >= i { break }
                    let r = externalToInternalRow(i)
                    if lines[r] == nil || lines[r]!.isBlank() {
                        shiftDownOfTopRow -= 1
                        if shiftDownOfTopRow == 0 { break }
                    }
                    i -= 1
                }
            } else if shiftDownOfTopRow < 0 {
                let actualShift = max(shiftDownOfTopRow, -activeTranscriptRows)
                if shiftDownOfTopRow != actualShift {
                    for i in 0..<(actualShift - shiftDownOfTopRow) {
                        allocateFullLineIfNecessary((screenFirstRow + screenRows + i) % totalRows).clear(currentStyle)
                    }
                    shiftDownOfTopRow = actualShift
                }
            }
            screenFirstRow += shiftDownOfTopRow
            screenFirstRow = (screenFirstRow < 0) ? (screenFirstRow + totalRows) : (screenFirstRow % totalRows)
            totalRows = newTotalRows
            activeTranscriptRows = altScreen ? 0 : max(0, activeTranscriptRows + shiftDownOfTopRow)
            cursor[1] -= shiftDownOfTopRow
            screenRows = newRows
        } else {
            let oldLines = lines
            lines = [TerminalRow?](repeating: nil, count: newTotalRows)
            for i in 0..<newTotalRows {
                lines[i] = TerminalRow(newColumns, currentStyle)
            }

            let oldActiveTranscriptRows = activeTranscriptRows
            let oldScreenFirstRow = screenFirstRow
            let oldScreenRows = screenRows
            let oldTotalRows = totalRows
            totalRows = newTotalRows
            screenRows = newRows
            activeTranscriptRows = 0
            screenFirstRow = 0
            columns = newColumns

            var newCursorRow = -1
            var newCursorColumn = -1
            let oldCursorRow = cursor[1]
            let oldCursorColumn = cursor[0]
            var newCursorPlaced = false

            var currentOutputExternalRow = 0
            var currentOutputExternalColumn = 0

            var skippedBlankLines = 0
            var externalOldRow = -oldActiveTranscriptRows
            while externalOldRow < oldScreenRows {
                defer { externalOldRow += 1 }
                var internalOldRow = oldScreenFirstRow + externalOldRow
                internalOldRow = (internalOldRow < 0) ? (oldTotalRows + internalOldRow) : (internalOldRow % oldTotalRows)

                let oldLineOpt = oldLines[internalOldRow]
                let cursorAtThisRow = externalOldRow == oldCursorRow
                guard let oldLine = oldLineOpt, (!newCursorPlaced && cursorAtThisRow) || !oldLine.isBlank() else {
                    skippedBlankLines += 1
                    continue
                }
                if skippedBlankLines > 0 {
                    for _ in 0..<skippedBlankLines {
                        if currentOutputExternalRow == screenRows - 1 {
                            scrollDownOneLine(0, screenRows, currentStyle)
                        } else {
                            currentOutputExternalRow += 1
                        }
                        currentOutputExternalColumn = 0
                    }
                    skippedBlankLines = 0
                }

                var lastNonSpaceIndex = 0
                var justToCursor = false
                if cursorAtThisRow || oldLine.lineWrap {
                    lastNonSpaceIndex = oldLine.spaceUsed
                    if cursorAtThisRow { justToCursor = true }
                } else {
                    for i in 0..<oldLine.spaceUsed {
                        if oldLine.text[i] != 32  {
                            lastNonSpaceIndex = i + 1
                        }
                    }
                }

                var currentOldCol = 0
                var styleAtCol: Int64 = 0
                var i = 0
                while i < lastNonSpaceIndex {
                    defer { i += 1 }
                    let c = oldLine.text[i]
                    let codePoint: Int
                    if UTF16Util.isHighSurrogate(c) {
                        i += 1
                        codePoint = UTF16Util.toCodePoint(c, oldLine.text[i])
                    } else {
                        codePoint = Int(c)
                    }
                    let displayWidth = WcWidth.width(codePoint)
                    if displayWidth > 0 { styleAtCol = oldLine.getStyle(currentOldCol) }

                    if currentOutputExternalColumn + displayWidth > columns {
                        setLineWrap(currentOutputExternalRow)
                        if currentOutputExternalRow == screenRows - 1 {
                            if newCursorPlaced { newCursorRow -= 1 }
                            scrollDownOneLine(0, screenRows, currentStyle)
                        } else {
                            currentOutputExternalRow += 1
                        }
                        currentOutputExternalColumn = 0
                    }

                    let offsetDueToCombiningChar = ((displayWidth <= 0 && currentOutputExternalColumn > 0) ? 1 : 0)
                    let outputColumn = currentOutputExternalColumn - offsetDueToCombiningChar
                    setChar(outputColumn, currentOutputExternalRow, codePoint, styleAtCol)

                    if displayWidth > 0 {
                        if oldCursorRow == externalOldRow && oldCursorColumn == currentOldCol {
                            newCursorColumn = currentOutputExternalColumn
                            newCursorRow = currentOutputExternalRow
                            newCursorPlaced = true
                        }
                        currentOldCol += displayWidth
                        currentOutputExternalColumn += displayWidth
                        if justToCursor && newCursorPlaced { break }
                    }
                }
                if externalOldRow != (oldScreenRows - 1) && !oldLine.lineWrap {
                    if currentOutputExternalRow == screenRows - 1 {
                        if newCursorPlaced { newCursorRow -= 1 }
                        scrollDownOneLine(0, screenRows, currentStyle)
                    } else {
                        currentOutputExternalRow += 1
                    }
                    currentOutputExternalColumn = 0
                }
            }

            cursor[0] = newCursorColumn
            cursor[1] = newCursorRow
        }

        if cursor[0] < 0 || cursor[1] < 0 {
            cursor[0] = 0
            cursor[1] = 0
        }
    }

    private func blockCopyLinesDown(_ srcInternal: Int, _ len: Int) {
        if len == 0 { return }
        let totalRows = self.totalRows

        let start = len - 1
        let lineToBeOverWritten = lines[(srcInternal + start + 1) % totalRows]
        var i = start
        while i >= 0 {
            lines[(srcInternal + i + 1) % totalRows] = lines[(srcInternal + i) % totalRows]
            i -= 1
        }
        lines[srcInternal % totalRows] = lineToBeOverWritten
    }

    public func scrollDownOneLine(_ topMargin: Int, _ bottomMargin: Int, _ style: Int64) {
        if topMargin > bottomMargin - 1 || topMargin < 0 || bottomMargin > screenRows {
            preconditionFailure("topMargin=\(topMargin), bottomMargin=\(bottomMargin), mScreenRows=\(screenRows)")
        }

        blockCopyLinesDown(screenFirstRow, topMargin)
        blockCopyLinesDown(externalToInternalRow(bottomMargin), screenRows - bottomMargin)

        screenFirstRow = (screenFirstRow + 1) % totalRows
        if activeTranscriptRows < totalRows - screenRows { activeTranscriptRows += 1 }

        let blankRow = externalToInternalRow(bottomMargin - 1)
        if let line = lines[blankRow] {
            line.clear(style)
        } else {
            lines[blankRow] = TerminalRow(columns, style)
        }
    }

    public func blockCopy(_ sx: Int, _ sy: Int, _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) {
        if w == 0 { return }
        if sx < 0 || sx + w > columns || sy < 0 || sy + h > screenRows || dx < 0 || dx + w > columns || dy < 0 || dy + h > screenRows {
            preconditionFailure("blockCopy(\(sx), \(sy), \(w), \(h), \(dx), \(dy)) out of bounds")
        }
        let copyingUp = sy > dy
        if h <= 0 { return }
        for y in 0..<h {
            let y2 = copyingUp ? y : (h - (y + 1))
            let sourceRow = allocateFullLineIfNecessary(externalToInternalRow(sy + y2))
            allocateFullLineIfNecessary(externalToInternalRow(dy + y2)).copyInterval(sourceRow, sx, sx + w, dx)
        }
    }

    public func blockSet(_ sx: Int, _ sy: Int, _ w: Int, _ h: Int, _ val: Int, _ style: Int64) {
        if sx < 0 || sx + w > columns || sy < 0 || sy + h > screenRows {
            preconditionFailure("Illegal arguments! blockSet(\(sx), \(sy), \(w), \(h), \(val), \(columns), \(screenRows))")
        }
        if h <= 0 { return }
        for y in 0..<h {
            if w > 0 {
                for x in 0..<w {
                    setChar(sx + x, sy + y, val, style)
                }
            }
            if sx + w == columns && val == 32 {
                clearLineWrap(sy + y)
            }
        }
    }

    public func allocateFullLineIfNecessary(_ row: Int) -> TerminalRow {
        if let line = lines[row] { return line }
        let line = TerminalRow(columns, 0)
        lines[row] = line
        return line
    }

    public func setChar(_ column: Int, _ row: Int, _ codePoint: Int, _ style: Int64) {
        if row < 0 || row >= screenRows || column < 0 || column >= columns {
            preconditionFailure("TerminalBuffer.setChar(): row=\(row), column=\(column), mScreenRows=\(screenRows), mColumns=\(columns)")
        }
        let internalRow = externalToInternalRow(row)
        allocateFullLineIfNecessary(internalRow).setChar(column, codePoint, style)
    }

    public func getStyleAt(externalRow: Int, column: Int) -> Int64 {
        return allocateFullLineIfNecessary(externalToInternalRow(externalRow)).getStyle(column)
    }

    public func setOrClearEffect(_ bits: Int, _ setOrClear: Bool, _ reverse: Bool, _ rectangular: Bool, _ leftMargin: Int, _ rightMargin: Int,
                                 _ top: Int, _ left: Int, _ bottom: Int, _ right: Int) {
        var y = top
        while y < bottom {
            defer { y += 1 }
            let line = allocateFullLineIfNecessary(externalToInternalRow(y))
            let startOfLine = (rectangular || y == top) ? left : leftMargin
            let endOfLine = (rectangular || y + 1 == bottom) ? right : rightMargin
            var x = startOfLine
            while x < endOfLine {
                let currentStyle = line.getStyle(x)
                let foreColor = TextStyle.decodeForeColor(currentStyle)
                let backColor = TextStyle.decodeBackColor(currentStyle)
                var effect = TextStyle.decodeEffect(currentStyle)
                if reverse {
                    effect = (effect & ~bits) | (bits & ~effect)
                } else if setOrClear {
                    effect |= bits
                } else {
                    effect &= ~bits
                }
                line.style[x] = TextStyle.encode(foreColor: foreColor, backColor: backColor, effect: effect)
                x += 1
            }
        }
    }

    public func clearTranscript() {
        if screenFirstRow < activeTranscriptRows {
            for i in (totalRows + screenFirstRow - activeTranscriptRows)..<totalRows { lines[i] = nil }
            for i in 0..<screenFirstRow { lines[i] = nil }
        } else {
            for i in (screenFirstRow - activeTranscriptRows)..<screenFirstRow { lines[i] = nil }
        }
        activeTranscriptRows = 0
    }

    func sixelStart(_ width: Int, _ height: Int) {}

    func sixelEnd(_ x: Int, _ y: Int, _ cellW: Int, _ cellH: Int) -> Int { return 0 }

    func sixelClear() {}

    func sixelIgnore() {}

    @discardableResult
    func sixelReadData(_ codePoint: Int, _ repeatCount: Int) -> Bool { return true }

    @discardableResult
    func sixelResize(_ sixelWidth: Int, _ sixelHeight: Int) -> Bool { return true }

    func sixelSetColor(_ color: Int) {}

    func sixelSetRGBColor(_ color: Int, _ r: Int, _ g: Int, _ b: Int) {}

    func doTerminalBitmapsGC(_ timeDelta: Int) {}
}

extension String {
    func javaTrimmed() -> String {
        let chars = Array(utf16)
        var start = 0
        var end = chars.count
        while start < end && chars[start] <= 32 { start += 1 }
        while end > start && chars[end - 1] <= 32 { end -= 1 }
        if start == 0 && end == chars.count { return self }
        return String(decoding: chars[start..<end], as: UTF16.self)
    }
}

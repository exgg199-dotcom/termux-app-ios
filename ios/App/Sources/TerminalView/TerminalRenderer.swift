import UIKit
import CoreText
import TermuxTerminal

final class TerminalRenderer {
    let fontSize: CGFloat
    let customFontData: Data?

    private let regularFont: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    private let boldItalicFont: CTFont
    private let fakeBold: Bool

    let metrics: TerminalCellMetrics
    private let underlinePosition: CGFloat
    private let underlineThickness: CGFloat

    private var widthCache: [Int: CGFloat] = [:]
    private var colorCache: [UInt32: CGColor] = [:]

    init(fontSize: CGFloat, customFontData: Data?) {
        self.fontSize = fontSize
        self.customFontData = customFontData

        var base: CTFont?
        if let data = customFontData, !data.isEmpty,
           let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            base = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        }

        let regular: CTFont
        var bold: CTFont?
        if let base = base {
            regular = base
            bold = CTFontCreateCopyWithSymbolicTraits(base, fontSize, nil, .traitBold, .traitBold)
        } else {
            regular = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) as CTFont
            bold = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold) as CTFont
        }
        regularFont = regular
        boldFont = bold ?? regular
        fakeBold = (bold == nil)

        var shear = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        italicFont = CTFontCreateCopyWithAttributes(regular, fontSize, &shear, nil)
        boldItalicFont = CTFontCreateCopyWithAttributes(boldFont, fontSize, &shear, nil)

        var characters: [UniChar] = [UniChar(UInt8(ascii: "X"))]
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(regular, &characters, &glyphs, 1)
        var advance = CGSize.zero
        let totalAdvance = CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyphs, &advance, 1)
        let fontWidth = totalAdvance > 0 ? CGFloat(totalAdvance) : fontSize * 0.6

        metrics = TerminalCellMetrics.fromFont(advance: fontWidth,
                                               ascent: CTFontGetAscent(regular),
                                               descent: CTFontGetDescent(regular),
                                               leading: CTFontGetLeading(regular))
        underlinePosition = CTFontGetUnderlinePosition(regular)
        underlineThickness = max(1, CTFontGetUnderlineThickness(regular))
    }

    var fontWidth: CGFloat { return metrics.cellWidth }
    var lineHeight: CGFloat { return metrics.lineHeight }

    private func measuredWidth(of codePoint: Int, text: [UInt16], index: Int, count: Int) -> CGFloat {
        if let cached = widthCache[codePoint] {
            return cached
        }
        var width: CGFloat
        var units = Array(text[index..<(index + count)])
        var glyphs = [CGGlyph](repeating: 0, count: count)
        if CTFontGetGlyphsForCharacters(regularFont, &units, &glyphs, count) {
            width = CGFloat(CTFontGetAdvancesForGlyphs(regularFont, .horizontal, &glyphs, nil, count))
        } else {
            let string = String(decoding: units, as: UTF16.self)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): regularFont,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        if width <= 0 && WcWidth.width(codePoint) > 0 {
            width = fontWidth * CGFloat(WcWidth.width(codePoint))
        }
        widthCache[codePoint] = width
        return width
    }

    private func cgColor(_ argb: UInt32) -> CGColor {
        if let cached = colorCache[argb] {
            return cached
        }
        let color = UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255.0,
                            green: CGFloat((argb >> 8) & 0xFF) / 255.0,
                            blue: CGFloat(argb & 0xFF) / 255.0,
                            alpha: 1).cgColor
        if colorCache.count > 4096 { colorCache.removeAll() }
        colorCache[argb] = color
        return color
    }

    static func uiColor(_ argb: UInt32) -> UIColor {
        return UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255.0,
                       green: CGFloat((argb >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(argb & 0xFF) / 255.0,
                       alpha: 1)
    }

    func render(emulator: TerminalEmulator, context: CGContext, topRow: Int,
                selectionY1: Int, selectionY2: Int, selectionX1: Int, selectionX2: Int,
                visibleRect: CGRect) {
        let reverseVideo = emulator.isReverseVideo
        let endRow = topRow + emulator.rows
        let columns = emulator.columns
        let cursorColumn = emulator.cursorCol
        let cursorRow = emulator.cursorRow
        let cursorVisible = emulator.shouldCursorBeVisible
        let screen = emulator.screen
        let palette = emulator.colors.currentColors
        let cursorShape = emulator.cursorStyle

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        if reverseVideo {
            context.setFillColor(cgColor(palette[TextStyle.COLOR_INDEX_FOREGROUND]))
            context.fill(visibleRect)
        }

        for row in topRow..<endRow {
            let lineTop = CGFloat(row - topRow) * metrics.lineHeight
            if lineTop > visibleRect.maxY || lineTop + metrics.lineHeight < visibleRect.minY {
                continue
            }

            let cursorX = (row == cursorRow && cursorVisible) ? cursorColumn : -1
            var selectionStartColumn = -1
            var selectionEndColumn = -1
            if row >= selectionY1 && row <= selectionY2 {
                if row == selectionY1 { selectionStartColumn = selectionX1 }
                selectionEndColumn = (row == selectionY2) ? selectionX2 : columns
            }

            let lineObject = screen.allocateFullLineIfNecessary(screen.externalToInternalRow(row))
            let line = lineObject.text
            let codeUnitsUsedInLine = lineObject.spaceUsed

            var lastRunStyle: Int64 = 0
            var lastRunInsideCursor = false
            var lastRunInsideSelection = false
            var lastRunStartColumn = -1
            var lastRunStartCodeUnitIndex = 0
            var lastRunFontWidthMismatch = false
            var currentCodeUnitIndex = 0
            var measuredWidthForRun: CGFloat = 0

            var column = 0
            while column < columns {
                if currentCodeUnitIndex >= line.count { break }
                let codeUnitAtIndex = line[currentCodeUnitIndex]
                let isHighSurrogate = UTF16.isLeadSurrogate(codeUnitAtIndex) && currentCodeUnitIndex + 1 < line.count
                let codeUnitsForCodePoint = isHighSurrogate ? 2 : 1
                let codePoint: Int
                if isHighSurrogate {
                    let low = line[currentCodeUnitIndex + 1]
                    codePoint = 0x10000 + ((Int(codeUnitAtIndex) - 0xD800) << 10) + (Int(low) - 0xDC00)
                } else {
                    codePoint = Int(codeUnitAtIndex)
                }
                let style = lineObject.getStyle(column)

                if TextStyle.isTerminalBitmap(style) {
                    column += 1
                    measuredWidthForRun = 0
                    lastRunStyle = 0
                    lastRunInsideCursor = false
                    lastRunStartColumn = -1
                    currentCodeUnitIndex += codeUnitsForCodePoint
                    lastRunStartCodeUnitIndex = currentCodeUnitIndex
                    lastRunFontWidthMismatch = false
                    continue
                }

                let codePointWcWidth = WcWidth.width(codePoint)
                let insideCursor = (cursorX == column || (codePointWcWidth == 2 && cursorX == column + 1))
                let insideSelection = column >= selectionStartColumn && column <= selectionEndColumn

                let measuredCodePointWidth = measuredWidth(of: codePoint, text: line, index: currentCodeUnitIndex, count: codeUnitsForCodePoint)
                let fontWidthMismatch = abs(measuredCodePointWidth / metrics.cellWidth - CGFloat(codePointWcWidth)) > 0.01

                if lastRunStartColumn < 0 || style != lastRunStyle || insideCursor != lastRunInsideCursor || insideSelection != lastRunInsideSelection
                    || fontWidthMismatch || lastRunFontWidthMismatch {
                    if column != 0 && column != lastRunStartColumn && lastRunStartColumn >= 0 {
                        let columnWidthSinceLastRun = column - lastRunStartColumn
                        let codeUnitsSinceLastRun = currentCodeUnitIndex - lastRunStartCodeUnitIndex
                        let cursorColor: UInt32 = lastRunInsideCursor ? palette[TextStyle.COLOR_INDEX_CURSOR] : 0
                        let invertCursorTextColor = lastRunInsideCursor && cursorShape == TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
                        drawTextRun(context, text: line, palette: palette, lineTop: lineTop, startColumn: lastRunStartColumn,
                                    runWidthColumns: columnWidthSinceLastRun, startCodeUnitIndex: lastRunStartCodeUnitIndex,
                                    runWidthCodeUnits: codeUnitsSinceLastRun, measuredWidth: measuredWidthForRun,
                                    cursorColor: cursorColor, cursorStyle: cursorShape, textStyle: lastRunStyle,
                                    reverseVideo: reverseVideo || invertCursorTextColor || lastRunInsideSelection)
                    }
                    measuredWidthForRun = 0
                    lastRunStyle = style
                    lastRunInsideCursor = insideCursor
                    lastRunInsideSelection = insideSelection
                    lastRunStartColumn = column
                    lastRunStartCodeUnitIndex = currentCodeUnitIndex
                    lastRunFontWidthMismatch = fontWidthMismatch
                }
                measuredWidthForRun += measuredCodePointWidth
                column += max(1, codePointWcWidth)
                currentCodeUnitIndex += codeUnitsForCodePoint
                while currentCodeUnitIndex < codeUnitsUsedInLine && currentCodeUnitIndex < line.count && WcWidth.width(line, currentCodeUnitIndex) <= 0 {
                    let isCombiningHighSurrogate = UTF16.isLeadSurrogate(line[currentCodeUnitIndex]) && currentCodeUnitIndex + 1 < line.count
                    currentCodeUnitIndex += isCombiningHighSurrogate ? 2 : 1
                }
            }

            if lastRunStartColumn < 0 || lastRunStartColumn >= columns { continue }
            let columnWidthSinceLastRun = columns - lastRunStartColumn
            let codeUnitsSinceLastRun = min(currentCodeUnitIndex, line.count) - lastRunStartCodeUnitIndex
            let cursorColor: UInt32 = lastRunInsideCursor ? palette[TextStyle.COLOR_INDEX_CURSOR] : 0
            let invertCursorTextColor = lastRunInsideCursor && cursorShape == TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
            drawTextRun(context, text: line, palette: palette, lineTop: lineTop, startColumn: lastRunStartColumn,
                        runWidthColumns: columnWidthSinceLastRun, startCodeUnitIndex: lastRunStartCodeUnitIndex,
                        runWidthCodeUnits: max(0, codeUnitsSinceLastRun), measuredWidth: measuredWidthForRun,
                        cursorColor: cursorColor, cursorStyle: cursorShape, textStyle: lastRunStyle,
                        reverseVideo: reverseVideo || invertCursorTextColor || lastRunInsideSelection)
        }
    }

    private func drawTextRun(_ context: CGContext, text: [UInt16], palette: [UInt32], lineTop: CGFloat,
                             startColumn: Int, runWidthColumns: Int, startCodeUnitIndex: Int, runWidthCodeUnits: Int,
                             measuredWidth measuredRunWidth: CGFloat, cursorColor: UInt32, cursorStyle: Int,
                             textStyle: Int64, reverseVideo: Bool) {
        var foreColorIndex = TextStyle.decodeForeColor(textStyle)
        let effect = TextStyle.decodeEffect(textStyle)
        let backColorIndex = TextStyle.decodeBackColor(textStyle)
        let bold = (effect & (TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_BLINK)) != 0
        let underline = (effect & TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE) != 0
        let italic = (effect & TextStyle.CHARACTER_ATTRIBUTE_ITALIC) != 0
        let strikeThrough = (effect & TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH) != 0
        let dim = (effect & TextStyle.CHARACTER_ATTRIBUTE_DIM) != 0

        var foreColor: UInt32
        if (foreColorIndex & 0xff000000) != 0xff000000 {
            if bold && foreColorIndex >= 0 && foreColorIndex < 8 { foreColorIndex += 8 }
            foreColor = (foreColorIndex >= 0 && foreColorIndex < palette.count) ? palette[foreColorIndex] : palette[TextStyle.COLOR_INDEX_FOREGROUND]
        } else {
            foreColor = UInt32(truncatingIfNeeded: foreColorIndex)
        }

        var backColor: UInt32
        if (backColorIndex & 0xff000000) != 0xff000000 {
            backColor = (backColorIndex >= 0 && backColorIndex < palette.count) ? palette[backColorIndex] : palette[TextStyle.COLOR_INDEX_BACKGROUND]
        } else {
            backColor = UInt32(truncatingIfNeeded: backColorIndex)
        }

        let reverseVideoHere = reverseVideo != ((effect & TextStyle.CHARACTER_ATTRIBUTE_INVERSE) != 0)
        if reverseVideoHere {
            let swapColor = foreColor
            foreColor = backColor
            backColor = swapColor
        }

        var left = CGFloat(startColumn) * metrics.cellWidth
        var right = left + CGFloat(runWidthColumns) * metrics.cellWidth

        let measuredColumns = measuredRunWidth / metrics.cellWidth
        var savedMatrix = false
        if measuredColumns > 0 && abs(measuredColumns - CGFloat(runWidthColumns)) > 0.01 {
            context.saveGState()
            context.scaleBy(x: CGFloat(runWidthColumns) / measuredColumns, y: 1)
            left *= measuredColumns / CGFloat(runWidthColumns)
            right *= measuredColumns / CGFloat(runWidthColumns)
            savedMatrix = true
        }

        let lineHeight = metrics.lineHeight
        if backColor != palette[TextStyle.COLOR_INDEX_BACKGROUND] {
            context.setShouldAntialias(false)
            context.setFillColor(cgColor(backColor))
            context.fill(CGRect(x: left, y: lineTop, width: right - left, height: lineHeight))
            context.setShouldAntialias(true)
        }

        if cursorColor != 0 {
            var cursorHeight = lineHeight
            var cursorRight = right
            if cursorStyle == TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE {
                cursorHeight /= 4
            } else if cursorStyle == TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR {
                cursorRight -= ((right - left) * 3) / 4
            }
            context.setFillColor(cgColor(cursorColor))
            context.fill(CGRect(x: left, y: lineTop + lineHeight - cursorHeight, width: cursorRight - left, height: cursorHeight))
        }

        if (effect & TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE) == 0 && runWidthCodeUnits > 0
            && startCodeUnitIndex >= 0 && startCodeUnitIndex + runWidthCodeUnits <= text.count {
            if dim {
                var red = Int(0xFF & (foreColor >> 16))
                var green = Int(0xFF & (foreColor >> 8))
                var blue = Int(0xFF & foreColor)
                red = red * 2 / 3
                green = green * 2 / 3
                blue = blue * 2 / 3
                foreColor = 0xFF000000 | (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
            }

            let baseline = lineTop + metrics.baselineOffset
            let units = text[startCodeUnitIndex..<(startCodeUnitIndex + runWidthCodeUnits)]
            if units.contains(where: { $0 != 32 }) {
                let string = String(decoding: units, as: UTF16.self)
                let font: CTFont
                switch (bold, italic) {
                case (true, true): font = boldItalicFont
                case (true, false): font = boldFont
                case (false, true): font = italicFont
                case (false, false): font = regularFont
                }
                let color = cgColor(foreColor)
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    NSAttributedString.Key(kCTLigatureAttributeName as String): NSNumber(value: 0),
                ]
                if bold && fakeBold {
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = NSNumber(value: -3.0)
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
                }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
                context.textPosition = CGPoint(x: left, y: baseline)
                CTLineDraw(line, context)
            }

            if underline || strikeThrough {
                context.setFillColor(cgColor(foreColor))
                if underline {
                    let y = baseline - underlinePosition
                    context.fill(CGRect(x: left, y: y, width: right - left, height: underlineThickness))
                }
                if strikeThrough {
                    let y = baseline - metrics.ascent * 0.35
                    context.fill(CGRect(x: left, y: y, width: right - left, height: underlineThickness))
                }
            }
        }

        if savedMatrix { context.restoreGState() }
    }
}

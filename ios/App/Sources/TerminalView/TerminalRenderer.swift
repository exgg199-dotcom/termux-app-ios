import UIKit
import CoreText
import TermuxTerminal

/// Renderer of a `TerminalEmulator` into a `CGContext` using CoreText. Port of
/// `com.termux.view.TerminalRenderer`.
///
/// Saves font metrics, so needs to be recreated each time the font or font size changes.
final class TerminalRenderer {

    let fontSize: CGFloat
    /// The custom font data (`~/.termux/font.ttf`), or nil for the system monospaced font.
    let customFontData: Data?

    private let regularFont: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    private let boldItalicFont: CTFont
    /// If no real bold face exists and bold has to be faked with a stroke.
    private let fakeBold: Bool

    let metrics: TerminalCellMetrics
    private let underlinePosition: CGFloat
    private let underlineThickness: CGFloat

    /// Measured advance (in points) of code points, see `measuredWidth(of:)`.
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

        // Like Android's `setTextSkewX(-0.35f)` italic is synthesized with a shear, since monospaced
        // fonts rarely have an italic face.
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        italicFont = CTFontCreateCopyWithAttributes(regular, fontSize, &shear, nil)
        boldItalicFont = CTFontCreateCopyWithAttributes(boldFont, fontSize, &shear, nil)

        // The width of a single mono spaced character, from the advance of "X".
        var chars: [UniChar] = [UniChar(UInt8(ascii: "X"))]
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(regular, &chars, &glyphs, 1)
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

    // MARK: - Measuring

    /// The measured advance of a code point. ASCII and other characters available in the primary
    /// font use the glyph advance, characters that need a fallback font are measured with CoreText.
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

    // MARK: - Colors

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

    // MARK: - Rendering

    /// Render the terminal to a context at a specified row scroll, and an optional rectangular
    /// selection. The context origin must be at the top left of the first terminal line.
    func render(emulator: TerminalEmulator, context ctx: CGContext, topRow: Int,
                selectionY1: Int, selectionY2: Int, selectionX1: Int, selectionX2: Int,
                visibleRect: CGRect) {
        let reverseVideo = emulator.isReverseVideo
        let endRow = topRow + emulator.rows
        let columns = emulator.columns
        let cursorCol = emulator.cursorCol
        let cursorRow = emulator.cursorRow
        let cursorVisible = emulator.shouldCursorBeVisible
        let screen = emulator.screen
        let palette = emulator.colors.currentColors
        let cursorShape = emulator.cursorStyle

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        if reverseVideo {
            ctx.setFillColor(cgColor(palette[TextStyle.COLOR_INDEX_FOREGROUND]))
            ctx.fill(visibleRect)
        }

        for row in topRow..<endRow {
            let lineTop = CGFloat(row - topRow) * metrics.lineHeight
            if lineTop > visibleRect.maxY || lineTop + metrics.lineHeight < visibleRect.minY {
                continue
            }

            let cursorX = (row == cursorRow && cursorVisible) ? cursorCol : -1
            var selx1 = -1
            var selx2 = -1
            if row >= selectionY1 && row <= selectionY2 {
                if row == selectionY1 { selx1 = selectionX1 }
                selx2 = (row == selectionY2) ? selectionX2 : columns
            }

            let lineObject = screen.allocateFullLineIfNecessary(screen.externalToInternalRow(row))
            let line = lineObject.text
            let charsUsedInLine = lineObject.spaceUsed

            var lastRunStyle: Int64 = 0
            var lastRunInsideCursor = false
            var lastRunInsideSelection = false
            var lastRunStartColumn = -1
            var lastRunStartIndex = 0
            var lastRunFontWidthMismatch = false
            var currentCharIndex = 0
            var measuredWidthForRun: CGFloat = 0

            var column = 0
            while column < columns {
                if currentCharIndex >= line.count { break }
                let charAtIndex = line[currentCharIndex]
                let charIsHighSurrogate = UTF16.isLeadSurrogate(charAtIndex) && currentCharIndex + 1 < line.count
                let charsForCodePoint = charIsHighSurrogate ? 2 : 1
                let codePoint: Int
                if charIsHighSurrogate {
                    let low = line[currentCharIndex + 1]
                    codePoint = 0x10000 + ((Int(charAtIndex) - 0xD800) << 10) + (Int(low) - 0xDC00)
                } else {
                    codePoint = Int(charAtIndex)
                }
                let style = lineObject.getStyle(column)

                if TextStyle.isTerminalBitmap(style) {
                    // Sixel images are not supported by the iOS renderer yet, the cell is left empty.
                    column += 1
                    measuredWidthForRun = 0
                    lastRunStyle = 0
                    lastRunInsideCursor = false
                    // Java sets this to `column + 1`, which leads to runs of negative width; start
                    // a fresh run at the next cell instead.
                    lastRunStartColumn = -1
                    currentCharIndex += charsForCodePoint
                    lastRunStartIndex = currentCharIndex
                    lastRunFontWidthMismatch = false
                    continue
                }

                let codePointWcWidth = WcWidth.width(codePoint)
                let insideCursor = (cursorX == column || (codePointWcWidth == 2 && cursorX == column + 1))
                let insideSelection = column >= selx1 && column <= selx2

                // Check if the measured text width for this code point is not the same as that
                // expected by wcwidth(). This could happen for some fonts which are not truly
                // monospace, or for more exotic characters such as smileys which are rendered as
                // wide. If this is detected, we draw this code point scaled to match what wcwidth()
                // expects.
                let measuredCodePointWidth = measuredWidth(of: codePoint, text: line, index: currentCharIndex, count: charsForCodePoint)
                let fontWidthMismatch = abs(measuredCodePointWidth / metrics.cellWidth - CGFloat(codePointWcWidth)) > 0.01

                if lastRunStartColumn < 0 || style != lastRunStyle || insideCursor != lastRunInsideCursor || insideSelection != lastRunInsideSelection
                    || fontWidthMismatch || lastRunFontWidthMismatch {
                    if column == 0 || column == lastRunStartColumn || lastRunStartColumn < 0 {
                        // Skip first column as there is nothing to draw, just record the current style.
                    } else {
                        let columnWidthSinceLastRun = column - lastRunStartColumn
                        let charsSinceLastRun = currentCharIndex - lastRunStartIndex
                        let cursorColor: UInt32 = lastRunInsideCursor ? palette[TextStyle.COLOR_INDEX_CURSOR] : 0
                        let invertCursorTextColor = lastRunInsideCursor && cursorShape == TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
                        drawTextRun(ctx, text: line, palette: palette, lineTop: lineTop, startColumn: lastRunStartColumn,
                                    runWidthColumns: columnWidthSinceLastRun, startCharIndex: lastRunStartIndex,
                                    runWidthChars: charsSinceLastRun, measuredWidth: measuredWidthForRun,
                                    cursorColor: cursorColor, cursorStyle: cursorShape, textStyle: lastRunStyle,
                                    reverseVideo: reverseVideo || invertCursorTextColor || lastRunInsideSelection)
                    }
                    measuredWidthForRun = 0
                    lastRunStyle = style
                    lastRunInsideCursor = insideCursor
                    lastRunInsideSelection = insideSelection
                    lastRunStartColumn = column
                    lastRunStartIndex = currentCharIndex
                    lastRunFontWidthMismatch = fontWidthMismatch
                }
                measuredWidthForRun += measuredCodePointWidth
                // Guard against an endless loop for a zero width character at the start of a column.
                column += max(1, codePointWcWidth)
                currentCharIndex += charsForCodePoint
                while currentCharIndex < charsUsedInLine && currentCharIndex < line.count && WcWidth.width(line, currentCharIndex) <= 0 {
                    // Eat combining chars so that they are treated as part of the last non-combining
                    // code point, instead of e.g. being considered inside the cursor in the next run.
                    let isHigh = UTF16.isLeadSurrogate(line[currentCharIndex]) && currentCharIndex + 1 < line.count
                    currentCharIndex += isHigh ? 2 : 1
                }
            }

            if lastRunStartColumn < 0 || lastRunStartColumn >= columns { continue }
            let columnWidthSinceLastRun = columns - lastRunStartColumn
            let charsSinceLastRun = min(currentCharIndex, line.count) - lastRunStartIndex
            let cursorColor: UInt32 = lastRunInsideCursor ? palette[TextStyle.COLOR_INDEX_CURSOR] : 0
            let invertCursorTextColor = lastRunInsideCursor && cursorShape == TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
            drawTextRun(ctx, text: line, palette: palette, lineTop: lineTop, startColumn: lastRunStartColumn,
                        runWidthColumns: columnWidthSinceLastRun, startCharIndex: lastRunStartIndex,
                        runWidthChars: max(0, charsSinceLastRun), measuredWidth: measuredWidthForRun,
                        cursorColor: cursorColor, cursorStyle: cursorShape, textStyle: lastRunStyle,
                        reverseVideo: reverseVideo || invertCursorTextColor || lastRunInsideSelection)
        }
    }

    private func drawTextRun(_ ctx: CGContext, text: [UInt16], palette: [UInt32], lineTop: CGFloat,
                             startColumn: Int, runWidthColumns: Int, startCharIndex: Int, runWidthChars: Int,
                             measuredWidth mesIn: CGFloat, cursorColor: UInt32, cursorStyle: Int,
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
            // Let bold have bright colors if applicable (one of the first 8):
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

        // Reverse video here if _one and only one_ of the reverse flags are set:
        let reverseVideoHere = reverseVideo != ((effect & TextStyle.CHARACTER_ATTRIBUTE_INVERSE) != 0)
        if reverseVideoHere {
            let tmp = foreColor
            foreColor = backColor
            backColor = tmp
        }

        var left = CGFloat(startColumn) * metrics.cellWidth
        var right = left + CGFloat(runWidthColumns) * metrics.cellWidth

        let mes = mesIn / metrics.cellWidth
        var savedMatrix = false
        if mes > 0 && abs(mes - CGFloat(runWidthColumns)) > 0.01 {
            ctx.saveGState()
            ctx.scaleBy(x: CGFloat(runWidthColumns) / mes, y: 1)
            left *= mes / CGFloat(runWidthColumns)
            right *= mes / CGFloat(runWidthColumns)
            savedMatrix = true
        }

        let lineHeight = metrics.lineHeight
        if backColor != palette[TextStyle.COLOR_INDEX_BACKGROUND] {
            // Only draw non-default background. Without anti aliasing so that adjacent runs
            // don't leave hairlines between them.
            ctx.setShouldAntialias(false)
            ctx.setFillColor(cgColor(backColor))
            ctx.fill(CGRect(x: left, y: lineTop, width: right - left, height: lineHeight))
            ctx.setShouldAntialias(true)
        }

        if cursorColor != 0 {
            var cursorHeight = lineHeight
            var cursorRight = right
            if cursorStyle == TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE {
                cursorHeight /= 4
            } else if cursorStyle == TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR {
                cursorRight -= ((right - left) * 3) / 4
            }
            ctx.setFillColor(cgColor(cursorColor))
            ctx.fill(CGRect(x: left, y: lineTop + lineHeight - cursorHeight, width: cursorRight - left, height: cursorHeight))
        }

        if (effect & TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE) == 0 && runWidthChars > 0
            && startCharIndex >= 0 && startCharIndex + runWidthChars <= text.count {
            if dim {
                var red = Int(0xFF & (foreColor >> 16))
                var green = Int(0xFF & (foreColor >> 8))
                var blue = Int(0xFF & foreColor)
                // Dim color handling used by libvte which in turn took it from xterm.
                red = red * 2 / 3
                green = green * 2 / 3
                blue = blue * 2 / 3
                foreColor = 0xFF000000 | (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
            }

            let baseline = lineTop + metrics.baselineOffset
            let units = text[startCharIndex..<(startCharIndex + runWidthChars)]
            // Skip drawing runs that consist only of spaces (most of the screen).
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
                ctx.textPosition = CGPoint(x: left, y: baseline)
                CTLineDraw(line, ctx)
            }

            if underline || strikeThrough {
                ctx.setFillColor(cgColor(foreColor))
                if underline {
                    // CoreText's underline position is negative (below the baseline).
                    let y = baseline - underlinePosition
                    ctx.fill(CGRect(x: left, y: y, width: right - left, height: underlineThickness))
                }
                if strikeThrough {
                    let y = baseline - metrics.ascent * 0.35
                    ctx.fill(CGRect(x: left, y: y, width: right - left, height: underlineThickness))
                }
            }
        }

        if savedMatrix { ctx.restoreGState() }
    }
}

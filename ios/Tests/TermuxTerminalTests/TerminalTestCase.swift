import XCTest
@testable import TermuxTerminal

func c(_ s: Unicode.Scalar) -> Int { return Int(s.value) }

func + (lhs: String, rhs: Int) -> String { return lhs + String(rhs) }
func + (lhs: Int, rhs: String) -> String { return String(lhs) + rhs }

func stringFromCodePoint(_ codePoint: Int) -> String {
    return String(Character(Unicode.Scalar(UInt32(codePoint))!))
}

class JUnitTestCase: XCTestCase {

    func assertEquals<T: Equatable>(_ expected: T, _ actual: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, actual, file: file, line: line)
    }

    func assertEquals<T: Equatable>(_ message: String, _ expected: T, _ actual: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, actual, message, file: file, line: line)
    }

    func assertEquals(_ expected: Int, _ actual: UInt16, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, Int(actual), file: file, line: line)
    }

    func assertEquals(_ expected: UInt16, _ actual: UInt16, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, actual, file: file, line: line)
    }

    func assertEquals(_ expected: Int, _ actual: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, Int(actual), file: file, line: line)
    }

    func assertEquals(_ expected: UInt32, _ actual: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Int(expected), actual, file: file, line: line)
    }

    func assertEquals(_ message: String, _ expected: Int, _ actual: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, Int(actual), message, file: file, line: line)
    }

    func assertEquals(_ message: String, _ expected: UInt32, _ actual: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected, actual, message, file: file, line: line)
    }

    func assertTrue(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, file: file, line: line)
    }

    func assertTrue(_ message: String, _ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    func assertFalse(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(condition, file: file, line: line)
    }

    func assertFalse(_ message: String, _ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(condition, message, file: file, line: line)
    }

    func assertNull<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, file: file, line: line)
    }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTFail(message, file: file, line: line)
    }
}

extension TerminalEmulator {
    func append(_ buffer: [UInt8], _ length: Int) {
        append(buffer, length: length)
    }

    func getSelectedText(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> String {
        return getSelectedText(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    func sendMouseEvent(_ mouseButton: Int, _ column: Int, _ row: Int, _ pressed: Bool) {
        sendMouseEvent(mouseButton, column: column, row: row, pressed: pressed)
    }

    func resize(_ columns: Int, _ rows: Int, _ cellWidthPixels: Int, _ cellHeightPixels: Int) {
        resize(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
    }
}

extension TerminalBuffer {
    func getSelectedText(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ joinBackLines: Bool, _ joinFullLines: Bool) -> String {
        return getSelectedText(selX1: x1, selY1: y1, selX2: x2, selY2: y2, joinBackLines: joinBackLines, joinFullLines: joinFullLines)
    }

    func getWordAtLocation(_ x: Int, _ y: Int) -> String {
        return getWordAtLocation(x: x, y: y)
    }
}

extension KeyHandler {
    static func getCode(_ keyCode: Int, _ keyMode: Int, _ cursorApp: Bool, _ keypadApplication: Bool) -> String? {
        return getCode(keyCode: keyCode, keyMode: keyMode, cursorApp: cursorApp, keypadApplication: keypadApplication)
    }

    static func getCodeFromTermcap(_ termcap: String, _ cursorKeysApplication: Bool, _ keypadApplication: Bool) -> String? {
        return getCodeFromTermcap(termcap, cursorKeysApplication: cursorKeysApplication, keypadApplication: keypadApplication)
    }
}

extension TextStyle {
    static func encode(_ foreColor: Int, _ backColor: Int, _ effect: Int) -> Int64 {
        return encode(foreColor: foreColor, backColor: backColor, effect: effect)
    }
}

class TerminalTestCase: JUnitTestCase {

    static let INITIAL_CELL_WIDTH_PIXELS = 13
    static let INITIAL_CELL_HEIGHT_PIXELS = 15

    struct ChangedTitle: Equatable, CustomStringConvertible {
        let oldTitle: String?
        let newTitle: String?

        init(_ oldTitle: String?, _ newTitle: String?) {
            self.oldTitle = oldTitle
            self.newTitle = newTitle
        }

        var description: String {
            return "ChangedTitle[oldTitle=\(oldTitle ?? "null"), newTitle=\(newTitle ?? "null")]"
        }
    }

    final class MockTerminalOutput: TerminalOutput {
        var baos = [UInt8]()
        var titleChanges = [ChangedTitle]()
        var clipboardPuts = [String]()
        var bellsRung = 0
        var colorsChanged = 0

        func write(_ data: [UInt8]) {
            baos.append(contentsOf: data)
        }

        func getOutputAndClear() -> String {
            let result = String(decoding: baos, as: UTF8.self)
            baos.removeAll()
            return result
        }

        func titleChanged(oldTitle: String?, newTitle: String?) {
            titleChanges.append(ChangedTitle(oldTitle, newTitle))
        }

        func onCopyTextToClipboard(_ text: String) {
            clipboardPuts.append(text)
        }

        func onPasteTextFromClipboard() {
        }

        func onBell() {
            bellsRung += 1
        }

        func onColorsChanged() {
            colorsChanged += 1
        }
    }

    var mTerminal: TerminalEmulator!
    var mOutput: MockTerminalOutput!

    override func setUp() {
        super.setUp()
        Logger.printLogsWithoutClient = false
        mOutput = MockTerminalOutput()
    }

    @discardableResult
    func enterString(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        let bytes = Array(s.utf8)
        mTerminal.append(bytes, length: bytes.count)
        assertInvariants(file: file, line: line)
        return self
    }

    func assertEnteringStringGivesResponse(_ input: String, _ expectedResponse: String, file: StaticString = #filePath, line: UInt = #line) {
        enterString(input, file: file, line: line)
        let response = mOutput.getOutputAndClear()
        XCTAssertEqual(expectedResponse, response, file: file, line: line)
    }

    @discardableResult
    func withTerminalSized(_ columns: Int, _ rows: Int) -> TerminalTestCase {
        mTerminal = TerminalEmulator(output: mOutput, columns: columns, rows: rows, cellWidthPixels: TerminalTestCase.INITIAL_CELL_WIDTH_PIXELS,
                                     cellHeightPixels: TerminalTestCase.INITIAL_CELL_HEIGHT_PIXELS, transcriptRows: rows * 2, client: nil)
        return self
    }

    func assertHistoryStartsWith(_ rows: String..., file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(mTerminal.screen.activeTranscriptRows >= rows.count,
                      "About to check \(rows.count) lines, but only \(mTerminal.screen.activeTranscriptRows) in history", file: file, line: line)
        for i in 0..<rows.count {
            assertLineIs(-i - 1, rows[i], file: file, line: line)
        }
    }

    @discardableResult
    func assertInvariants(file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        let screen = mTerminal.screen
        let lines = screen.lines

        var linesSet = Set<ObjectIdentifier>()
        for i in 0..<lines.count {
            guard let l = lines[i] else { continue }
            XCTAssertTrue(linesSet.insert(ObjectIdentifier(l)).inserted, "Line exists at multiple places: \(i)", file: file, line: line)
            let text = l.text
            let usedChars = l.spaceUsed
            var currentColumn = 0
            var j = 0
            while j < usedChars {
                let ch = text[j]
                var codePoint: Int
                if UTF16Util.isHighSurrogate(ch) {
                    j += 1
                    let lowSurrogate = text[j]
                    XCTAssertTrue(UTF16Util.isLowSurrogate(lowSurrogate), "High surrogate without following low surrogate", file: file, line: line)
                    codePoint = UTF16Util.toCodePoint(ch, lowSurrogate)
                } else {
                    XCTAssertFalse(UTF16Util.isLowSurrogate(ch), "Low surrogate without preceding high surrogate", file: file, line: line)
                    codePoint = Int(ch)
                }
                XCTAssertFalse(UTF16Util.isUnassignedOrSurrogate(codePoint), "Screen should never contain unassigned characters", file: file, line: line)
                let width = WcWidth.width(codePoint)
                XCTAssertFalse(currentColumn == 0 && width < 0, "The first column should not start with combining character", file: file, line: line)
                if width > 0 { currentColumn += width }
                j += 1
            }
            XCTAssertEqual(screen.columns, currentColumn,
                           "Line whose width does not match screens. line=\(UTF16Util.string(Array(l.text[0..<l.spaceUsed])))", file: file, line: line)
        }

        XCTAssertEqual(mTerminal.altBuffer.totalRows, mTerminal.altBuffer.screenRows, "The alt buffer should have have no history", file: file, line: line)
        if mTerminal.isAlternateBufferActive {
            XCTAssertEqual(mTerminal.rows, mTerminal.altBuffer.totalRows, "The alt buffer should be the same size as the screen", file: file, line: line)
        }

        return self
    }

    func assertLineIs(_ line: Int, _ expected: String, file: StaticString = #filePath, line callLine: UInt = #line) {
        let l = mTerminal.screen.allocateFullLineIfNecessary(mTerminal.screen.externalToInternalRow(line))
        let chars = l.text
        let textLen = l.spaceUsed
        let expectedChars = Array(expected.utf16)
        let actual = UTF16Util.string(Array(chars[0..<textLen]))
        if textLen != expectedChars.count {
            XCTFail("Expected '\(expected)' (len=\(expectedChars.count)), was='\(actual)' (len=\(textLen))", file: file, line: callLine)
            return
        }
        for i in 0..<textLen {
            if expectedChars[i] != chars[i] {
                XCTFail("Expected '\(expected)', was='\(actual)' - first different at index=\(i)", file: file, line: callLine)
                return
            }
        }
    }

    @discardableResult
    func assertLinesAre(_ lines: String..., file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        XCTAssertEqual(lines.count, mTerminal.screen.screenRows, file: file, line: line)
        if lines.count != mTerminal.screen.screenRows { return self }
        for i in 0..<lines.count {
            assertLineIs(i, lines[i], file: file, line: line)
        }
        return self
    }

    @discardableResult
    func resize(_ cols: Int, _ rows: Int, file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        mTerminal.resize(columns: cols, rows: rows, cellWidthPixels: TerminalTestCase.INITIAL_CELL_WIDTH_PIXELS, cellHeightPixels: TerminalTestCase.INITIAL_CELL_HEIGHT_PIXELS)
        assertInvariants(file: file, line: line)
        return self
    }

    @discardableResult
    func assertLineWraps(_ lines: Bool..., file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        for i in 0..<lines.count {
            let wrap = mTerminal.screen.lines[mTerminal.screen.externalToInternalRow(i)]!.lineWrap
            XCTAssertEqual(lines[i], wrap, "line=\(i)", file: file, line: line)
        }
        return self
    }

    @discardableResult
    func assertLineStartsWith(_ line: Int, _ codePoints: Int..., file: StaticString = #filePath, callLine: UInt = #line) -> TerminalTestCase {
        let chars = mTerminal.screen.lines[mTerminal.screen.externalToInternalRow(line)]!.text
        var charIndex = 0
        for i in 0..<codePoints.count {
            var lineCodePoint = Int(chars[charIndex])
            charIndex += 1
            if UTF16Util.isHighSurrogate(UInt16(lineCodePoint)) {
                lineCodePoint = UTF16Util.toCodePoint(UInt16(lineCodePoint), chars[charIndex])
                charIndex += 1
            }
            XCTAssertEqual(codePoints[i], lineCodePoint, "Differing a code point index=\(i)", file: file, line: callLine)
        }
        return self
    }

    @discardableResult
    func placeCursorAndAssert(_ row: Int, _ col: Int, file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        enterString("\u{1B}[\(row + 1);\(col + 1)H", file: file, line: line)
        assertCursorAt(row, col, file: file, line: line)
        return self
    }

    @discardableResult
    func assertCursorAt(_ row: Int, _ col: Int, file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        let actualRow = mTerminal.cursorRow
        let actualCol = mTerminal.cursorCol
        if !(row == actualRow && col == actualCol) {
            XCTFail("Expected cursor at (row,col)=(\(row), \(col)) but was (\(actualRow), \(actualCol))", file: file, line: line)
        }
        return self
    }

    func getStyleAt(_ externalRow: Int, _ column: Int) -> Int64 {
        return mTerminal.screen.getStyleAt(externalRow: externalRow, column: column)
    }

    struct EffectLine {
        let styles: [Int]
    }

    func effectLine(_ bits: Int...) -> EffectLine {
        return EffectLine(styles: bits)
    }

    @discardableResult
    func assertEffectAttributesSet(_ lines: EffectLine..., file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        XCTAssertEqual(lines.count, mTerminal.screen.screenRows, file: file, line: line)
        for i in 0..<lines.count {
            let l = lines[i].styles
            for j in 0..<l.count {
                let effectsAtCell = TextStyle.decodeEffect(getStyleAt(i, j))
                let attributes = l[j]
                if (effectsAtCell & attributes) != attributes {
                    XCTFail("Line=\(i), column=\(j), expected \(TerminalTestCase.describeStyle(attributes)) set, was \(TerminalTestCase.describeStyle(effectsAtCell))", file: file, line: line)
                }
            }
        }
        return self
    }

    @discardableResult
    func assertForegroundIndices(_ lines: EffectLine..., file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        XCTAssertEqual(lines.count, mTerminal.screen.screenRows, file: file, line: line)
        for i in 0..<lines.count {
            let l = lines[i].styles
            for j in 0..<l.count {
                let actualColor = TextStyle.decodeForeColor(getStyleAt(i, j))
                let expectedColor = l[j]
                if actualColor != expectedColor {
                    XCTFail("Line=\(i), column=\(j), expected color \(String(expectedColor, radix: 16)) set, was \(String(actualColor, radix: 16))", file: file, line: line)
                }
            }
        }
        return self
    }

    private static func describeStyle(_ styleBits: Int) -> String {
        return "'" + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_BLINK) != 0 ? ":BLINK:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_BOLD) != 0 ? ":BOLD:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_INVERSE) != 0 ? ":INVERSE:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE) != 0 ? ":INVISIBLE:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_ITALIC) != 0 ? ":ITALIC:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_PROTECTED) != 0 ? ":PROTECTED:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH) != 0 ? ":STRIKETHROUGH:" : "")
            + ((styleBits & TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE) != 0 ? ":UNDERLINE:" : "") + "'"
    }

    func assertForegroundColorAt(_ externalRow: Int, _ column: Int, _ color: Int, file: StaticString = #filePath, line: UInt = #line) {
        let style = mTerminal.screen.lines[mTerminal.screen.externalToInternalRow(externalRow)]!.getStyle(column)
        XCTAssertEqual(color, TextStyle.decodeForeColor(style), file: file, line: line)
    }

    func assertBackgroundColorAt(_ externalRow: Int, _ column: Int, _ color: Int, file: StaticString = #filePath, line: UInt = #line) {
        let style = mTerminal.screen.lines[mTerminal.screen.externalToInternalRow(externalRow)]!.getStyle(column)
        XCTAssertEqual(color, TextStyle.decodeBackColor(style), file: file, line: line)
    }

    @discardableResult
    func assertColor(_ colorIndex: Int, _ expected: UInt32, file: StaticString = #filePath, line: UInt = #line) -> TerminalTestCase {
        let actual = mTerminal.colors.currentColors[colorIndex]
        if expected != actual {
            XCTFail("Color index=\(colorIndex), expected=\(String(expected, radix: 16)), was=\(String(actual, radix: 16))", file: file, line: line)
        }
        return self
    }
}

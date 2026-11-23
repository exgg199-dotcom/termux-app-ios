import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class TerminalMetricsTests: XCTestCase {
    private let metrics = TerminalCellMetrics(cellWidth: 7.5, lineHeight: 15, ascent: 11, descent: 3)

    func testFromFont() {
        let fontMetrics = TerminalCellMetrics.fromFont(advance: 7.2, ascent: 11.4, descent: 2.9, leading: 0.2)
        XCTAssertEqual(fontMetrics.lineHeight, 15)
        XCTAssertEqual(fontMetrics.cellWidth, 7.2, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(fontMetrics.baselineOffset, fontMetrics.ascent)
        XCTAssertLessThanOrEqual(fontMetrics.baselineOffset + fontMetrics.descent, fontMetrics.lineHeight)
    }

    func testGridSize() {
        let size = metrics.gridSize(width: 600, height: 300)
        XCTAssertEqual(size.columns, 80)
        XCTAssertEqual(size.rows, 20)
        let tiny = metrics.gridSize(width: 10, height: 10)
        XCTAssertEqual(tiny.columns, 4)
        XCTAssertEqual(tiny.rows, 4)
        let fractional = metrics.gridSize(width: 607, height: 314)
        XCTAssertEqual(fractional.columns, 80)
        XCTAssertEqual(fractional.rows, 20)
    }

    func testCellPixelSize() {
        let pixels = metrics.cellPixelSize(scale: 3)
        XCTAssertEqual(pixels.width, 22)
        XCTAssertEqual(pixels.height, 45)
    }

    func testColumnAndRow() {
        let cell = metrics.columnAndRow(x: 16, y: 31, topRow: -5, relativeToScroll: false)
        XCTAssertEqual(cell.column, 2)
        XCTAssertEqual(cell.row, 2)
        let scrolled = metrics.columnAndRow(x: 16, y: 31, topRow: -5, relativeToScroll: true)
        XCTAssertEqual(scrolled.row, -3)
        XCTAssertEqual(metrics.pointX(column: 4, columns: 80), 30)
        XCTAssertEqual(metrics.pointX(column: 100, columns: 80), 600)
        XCTAssertEqual(metrics.pointY(row: -3, topRow: -5), 30)
        XCTAssertEqual(metrics.nearestColumnBorder(x: 11), 1)
        XCTAssertEqual(metrics.nearestColumnBorder(x: 12), 2)
    }
}

final class TerminalScrollMathTests: XCTestCase {
    func testScrollsToBottomOnOutput() {
        let result = TerminalScrollMath.onScreenUpdated(topRow: -10, rowsInHistory: 100, scrollCounter: 1,
                                                        isSelectingText: false, isAutoScrollDisabled: false)
        XCTAssertEqual(result.topRow, 0)
        XCTAssertTrue(result.awakenScrollBars)
        XCTAssertFalse(result.stopTextSelection)
    }

    func testNoAwakenForSmallScroll() {
        let result = TerminalScrollMath.onScreenUpdated(topRow: -2, rowsInHistory: 100, scrollCounter: 1,
                                                        isSelectingText: false, isAutoScrollDisabled: false)
        XCTAssertEqual(result.topRow, 0)
        XCTAssertFalse(result.awakenScrollBars)
    }

    func testStaysScrolledWhileSelecting() {
        let result = TerminalScrollMath.onScreenUpdated(topRow: -10, rowsInHistory: 100, scrollCounter: 3,
                                                        isSelectingText: true, isAutoScrollDisabled: false)
        XCTAssertEqual(result.topRow, -13)
        XCTAssertEqual(result.selectionShift, 3)
        XCTAssertFalse(result.stopTextSelection)
    }

    func testStopsSelectionAtEndOfTranscript() {
        let result = TerminalScrollMath.onScreenUpdated(topRow: -99, rowsInHistory: 100, scrollCounter: 3,
                                                        isSelectingText: true, isAutoScrollDisabled: false)
        XCTAssertTrue(result.stopTextSelection)
        XCTAssertEqual(result.topRow, 0)
    }

    func testAutoScrollDisabled() {
        let result = TerminalScrollMath.onScreenUpdated(topRow: -10, rowsInHistory: 100, scrollCounter: 2,
                                                        isSelectingText: false, isAutoScrollDisabled: true)
        XCTAssertEqual(result.topRow, -12)
        let atEnd = TerminalScrollMath.onScreenUpdated(topRow: -99, rowsInHistory: 100, scrollCounter: 3,
                                                       isSelectingText: false, isAutoScrollDisabled: true)
        XCTAssertEqual(atEnd.topRow, -100)
    }

    func testClampToHistory() {
        let result = TerminalScrollMath.onScreenUpdated(topRow: -50, rowsInHistory: 20, scrollCounter: 0,
                                                        isSelectingText: false, isAutoScrollDisabled: true)
        XCTAssertEqual(result.topRow, -20)
        XCTAssertEqual(TerminalScrollMath.clampTopRow(5, rowsInHistory: 10), 0)
        XCTAssertEqual(TerminalScrollMath.clampTopRow(-15, rowsInHistory: 10), -10)
    }

    func testRowsForScroll() {
        var result = TerminalScrollMath.rowsForScroll(distanceY: 20, remainder: 0, lineHeight: 15)
        XCTAssertEqual(result.rows, 1)
        XCTAssertEqual(result.remainder, 5, accuracy: 0.001)
        result = TerminalScrollMath.rowsForScroll(distanceY: 10, remainder: result.remainder, lineHeight: 15)
        XCTAssertEqual(result.rows, 1)
        XCTAssertEqual(result.remainder, 0, accuracy: 0.001)
        result = TerminalScrollMath.rowsForScroll(distanceY: -31, remainder: 0, lineHeight: 15)
        XCTAssertEqual(result.rows, -2)
        XCTAssertEqual(result.remainder, -1, accuracy: 0.001)
    }

    func testFlingDecay() {
        let velocity = TerminalScrollMath.decayedVelocity(1000, elapsed: 1.0 / 60.0)
        XCTAssertLessThan(velocity, 1000)
        XCTAssertGreaterThan(velocity, 960)
        XCTAssertEqual(TerminalScrollMath.decayedVelocity(1000, elapsed: 0), 1000, accuracy: 0.001)
    }
}

private struct FakeText: TerminalSelectionTextSource {
    let lines: [[String]]

    func selectionText(x1: Int, y1: Int, x2: Int, y2: Int) -> String {
        var result = ""
        for row in y1...y2 {
            guard row >= 0 && row < lines.count else { continue }
            let cells = lines[row]
            let start = row == y1 ? x1 : 0
            let end = row == y2 ? min(x2, cells.count - 1) : cells.count - 1
            if start <= end {
                for column in start...end where column >= 0 {
                    result += cells[column]
                }
            }
            if row != y2 { result += "\n" }
        }
        return result
    }
}

final class TerminalSelectionTests: XCTestCase {
    private func cells(_ string: String) -> [String] {
        return string.map { $0 == " " ? " " : String($0) }
    }

    func testInitialExpandsToWord() {
        let line = "ls -la /home".map { $0 == " " ? "" : String($0) }
        let text = FakeText(lines: [line])
        let selection = TerminalSelection.initial(column: 4, row: 0, columns: line.count, text: text)
        XCTAssertEqual(selection.x1, 3)
        XCTAssertEqual(selection.x2, 5)
        XCTAssertEqual(selection.y1, 0)
        XCTAssertEqual(selection.y2, 0)
    }

    func testInitialOnSpaceSelectsCell() {
        let text = FakeText(lines: [cells("a  b")])
        let selection = TerminalSelection.initial(column: 1, row: 0, columns: 4, text: text)
        XCTAssertEqual(selection, TerminalSelection(x1: 1, y1: 0, x2: 1, y2: 0))
    }

    func testUpdateClampsAndKeepsOrder() {
        let text = FakeText(lines: Array(repeating: cells("abcdefghij"), count: 5))
        var selection = TerminalSelection(x1: 2, y1: 1, x2: 5, y2: 3)
        var topRow = selection.update(handle: .start, column: 8, row: 4, rows: 5, activeRows: 5,
                                      isAlternateBufferActive: false, topRow: 0, text: text)
        XCTAssertEqual(selection.y1, 3)
        XCTAssertEqual(selection.x1, 5)
        XCTAssertEqual(topRow, 0)

        selection = TerminalSelection(x1: 2, y1: 1, x2: 5, y2: 3)
        topRow = selection.update(handle: .end, column: 0, row: 0, rows: 5, activeRows: 5,
                                  isAlternateBufferActive: false, topRow: 0, text: text)
        XCTAssertEqual(selection.y2, 1)
        XCTAssertEqual(selection.x2, 2)

        selection = TerminalSelection(x1: 0, y1: 0, x2: 1, y2: 0)
        _ = selection.update(handle: .end, column: 3, row: 10, rows: 5, activeRows: 5,
                             isAlternateBufferActive: false, topRow: 0, text: text)
        XCTAssertEqual(selection.y2, 4)
    }

    func testUpdateAutoScrollsIntoTranscript() {
        let text = FakeText(lines: [])
        var selection = TerminalSelection(x1: 0, y1: 0, x2: 3, y2: 2)
        let topRow = selection.update(handle: .start, column: 0, row: -2, rows: 5, activeRows: 15,
                                      isAlternateBufferActive: false, topRow: -2, text: text)
        XCTAssertEqual(topRow, -3)
        XCTAssertEqual(selection.y1, -2)
        var alt = TerminalSelection(x1: 0, y1: 0, x2: 3, y2: 2)
        let altTop = alt.update(handle: .start, column: 0, row: 0, rows: 5, activeRows: 5,
                                isAlternateBufferActive: true, topRow: 0, text: text)
        XCTAssertEqual(altTop, 0)
    }

    func testValidCursorXSnapsWideCharacters() {
        struct WideText: TerminalSelectionTextSource {
            func selectionText(x1: Int, y1: Int, x2: Int, y2: Int) -> String {
                let full = ["a", "中", "", "b"]
                return full[x1...min(x2, 3)].joined()
            }
        }
        XCTAssertEqual(TerminalSelection.validCursorX(text: WideText(), row: 0, column: 2), 3)
        XCTAssertEqual(TerminalSelection.validCursorX(text: WideText(), row: 0, column: 1), 1)
        XCTAssertEqual(TerminalSelection.validCursorX(text: WideText(), row: 0, column: 3), 3)
    }

    func testDecrementY() {
        var selection = TerminalSelection(x1: 0, y1: 2, x2: 3, y2: 4)
        selection.decrementY(by: 3)
        XCTAssertEqual(selection.y1, -1)
        XCTAssertEqual(selection.y2, 1)
        XCTAssertTrue(selection.isValid(rowsInHistory: 1))
        XCTAssertFalse(selection.isValid(rowsInHistory: 0))
    }
}

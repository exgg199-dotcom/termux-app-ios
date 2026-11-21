import Foundation
import TermuxTerminal

/// Access to the terminal text needed by the selection logic. `TerminalBuffer` conforms to it
/// (see `TerminalView.swift`), tests can use a fake.
public protocol TerminalSelectionTextSource {
    /// Text between two cells (inclusive), rows are external rows (negative = transcript).
    func selectionText(x1: Int, y1: Int, x2: Int, y2: Int) -> String
}

/// The text selection of the terminal view. Port of the selection math of
/// `TextSelectionCursorController` (selection coordinates `mSelX1`, `mSelY1`, `mSelX2`, `mSelY2`).
///
/// Rows are external rows (`0..<rows` is the screen, negative rows are in the transcript), columns
/// are inclusive on both ends.
public struct TerminalSelection: Equatable {
    public var x1: Int
    public var y1: Int
    public var x2: Int
    public var y2: Int

    public enum Handle {
        case start
        case end
    }

    public init(x1: Int, y1: Int, x2: Int, y2: Int) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// Port of `setInitialTextSelectionPosition()`: select the word at a cell, or just the cell if
    /// it's whitespace.
    public static func initial(column: Int, row: Int, columns: Int, text: TerminalSelectionTextSource) -> TerminalSelection {
        let column = max(0, min(columns - 1, column))
        var selection = TerminalSelection(x1: column, y1: row, x2: column, y2: row)
        if text.selectionText(x1: selection.x1, y1: selection.y1, x2: selection.x1, y2: selection.y1) != " " {
            // Selecting something other than whitespace. Expand to word.
            while selection.x1 > 0 && !text.selectionText(x1: selection.x1 - 1, y1: selection.y1, x2: selection.x1 - 1, y2: selection.y1).isEmpty {
                selection.x1 -= 1
            }
            while selection.x2 < columns - 1 && !text.selectionText(x1: selection.x2 + 1, y1: selection.y1, x2: selection.x2 + 1, y2: selection.y1).isEmpty {
                selection.x2 += 1
            }
        }
        return selection
    }

    /// Port of `TextSelectionCursorController.updatePosition()`: move a handle to a cell.
    ///
    /// - Parameters:
    ///   - handle: The handle being dragged.
    ///   - column: Column of the handle position (for the end handle, the last selected column).
    ///   - row: External row of the handle position.
    ///   - rows: Number of screen rows of the emulator.
    ///   - activeRows: `screen.activeRows` (screen + transcript rows).
    ///   - isAlternateBufferActive: The alternate buffer has no transcript, so no auto scroll.
    ///   - topRow: The current top row of the view.
    ///   - text: Text access to snap the column to wide characters.
    /// - Returns: The new top row of the view (auto scrolls when dragging past the visible area).
    public mutating func update(handle: Handle, column: Int, row: Int, rows: Int, activeRows: Int,
                                isAlternateBufferActive: Bool, topRow topRowIn: Int,
                                text: TerminalSelectionTextSource) -> Int {
        let scrollRows = activeRows - rows
        var topRow = topRowIn
        switch handle {
        case .start:
            x1 = max(0, column)
            y1 = row
            if y1 < -scrollRows {
                y1 = -scrollRows
            } else if y1 > rows - 1 {
                y1 = rows - 1
            }
            if y1 > y2 {
                y1 = y2
            }
            if y1 == y2 && x1 > x2 {
                x1 = x2
            }
            if !isAlternateBufferActive {
                if y1 <= topRow {
                    topRow -= 1
                    if topRow < -scrollRows { topRow = -scrollRows }
                } else if y1 >= topRow + rows {
                    topRow += 1
                    if topRow > 0 { topRow = 0 }
                }
            }
            x1 = TerminalSelection.validCursorX(text: text, cy: y1, cx: x1)

        case .end:
            x2 = max(0, column)
            y2 = row
            if y2 < -scrollRows {
                y2 = -scrollRows
            } else if y2 > rows - 1 {
                y2 = rows - 1
            }
            if y1 > y2 {
                y2 = y1
            }
            if y1 == y2 && x1 > x2 {
                x2 = x1
            }
            if !isAlternateBufferActive {
                if y2 <= topRow {
                    topRow -= 1
                    if topRow < -scrollRows { topRow = -scrollRows }
                } else if y2 >= topRow + rows {
                    topRow += 1
                    if topRow > 0 { topRow = 0 }
                }
            }
            x2 = TerminalSelection.validCursorX(text: text, cy: y2, cx: x2)
        }
        return topRow
    }

    /// Port of `getValidCurX()`: if the column is inside a wide character, move it to the end of it.
    public static func validCursorX(text: TerminalSelectionTextSource, cy: Int, cx: Int) -> Int {
        let line = Array(text.selectionText(x1: 0, y1: cy, x2: cx, y2: cy).unicodeScalars)
        if !line.isEmpty {
            var col = 0
            for scalar in line {
                if scalar.value == 0 { break }
                let wc = WcWidth.width(Int(scalar.value))
                let cend = col + wc
                if cx > col && cx < cend {
                    return cend
                }
                if cend == col {
                    return col
                }
                col = cend
            }
        }
        return cx
    }

    /// Port of `decrementYTextSelectionCursors()`.
    public mutating func decrementY(by decrement: Int) {
        y1 -= decrement
        y2 -= decrement
    }

    /// If the selection still exists in a transcript of `rowsInHistory` rows.
    public func isValid(rowsInHistory: Int) -> Bool {
        return y1 >= -rowsInHistory
    }
}

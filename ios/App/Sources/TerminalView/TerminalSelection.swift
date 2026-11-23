import Foundation
import TermuxTerminal

public protocol TerminalSelectionTextSource {
    func selectionText(x1: Int, y1: Int, x2: Int, y2: Int) -> String
}

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

    public static func initial(column: Int, row: Int, columns: Int, text: TerminalSelectionTextSource) -> TerminalSelection {
        let column = max(0, min(columns - 1, column))
        var selection = TerminalSelection(x1: column, y1: row, x2: column, y2: row)
        if text.selectionText(x1: selection.x1, y1: selection.y1, x2: selection.x1, y2: selection.y1) != " " {
            while selection.x1 > 0 && !text.selectionText(x1: selection.x1 - 1, y1: selection.y1, x2: selection.x1 - 1, y2: selection.y1).isEmpty {
                selection.x1 -= 1
            }
            while selection.x2 < columns - 1 && !text.selectionText(x1: selection.x2 + 1, y1: selection.y1, x2: selection.x2 + 1, y2: selection.y1).isEmpty {
                selection.x2 += 1
            }
        }
        return selection
    }

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
            x1 = TerminalSelection.validCursorX(text: text, row: y1, column: x1)

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
            x2 = TerminalSelection.validCursorX(text: text, row: y2, column: x2)
        }
        return topRow
    }

    public static func validCursorX(text: TerminalSelectionTextSource, row: Int, column: Int) -> Int {
        let line = Array(text.selectionText(x1: 0, y1: row, x2: column, y2: row).unicodeScalars)
        if !line.isEmpty {
            var cellStart = 0
            for scalar in line {
                if scalar.value == 0 { break }
                let width = WcWidth.width(Int(scalar.value))
                let cellEnd = cellStart + width
                if column > cellStart && column < cellEnd {
                    return cellEnd
                }
                if cellEnd == cellStart {
                    return cellStart
                }
                cellStart = cellEnd
            }
        }
        return column
    }

    public mutating func decrementY(by decrement: Int) {
        y1 -= decrement
        y2 -= decrement
    }

    public func isValid(rowsInHistory: Int) -> Bool {
        return y1 >= -rowsInHistory
    }
}

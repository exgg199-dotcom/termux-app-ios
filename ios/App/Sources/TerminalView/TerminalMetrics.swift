import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct TerminalCellMetrics: Equatable {
    public var cellWidth: CGFloat
    public var lineHeight: CGFloat
    public var ascent: CGFloat
    public var descent: CGFloat

    public init(cellWidth: CGFloat, lineHeight: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.cellWidth = max(1, cellWidth)
        self.lineHeight = max(1, lineHeight)
        self.ascent = ascent
        self.descent = descent
    }

    public static func fromFont(advance: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat) -> TerminalCellMetrics {
        let lineHeight = (ascent + descent + max(0, leading)).rounded(.up)
        return TerminalCellMetrics(cellWidth: advance, lineHeight: lineHeight, ascent: ascent, descent: descent)
    }

    public var baselineOffset: CGFloat {
        return ((lineHeight - (ascent + descent)) / 2).rounded(.down) + ascent
    }

    public func gridSize(width: CGFloat, height: CGFloat) -> (columns: Int, rows: Int) {
        let columns = max(4, Int((width / cellWidth).rounded(.down)))
        let rows = max(4, Int((height / lineHeight).rounded(.down)))
        return (columns, rows)
    }

    public func cellPixelSize(scale: CGFloat) -> (width: Int, height: Int) {
        return (max(1, Int((cellWidth * scale).rounded(.down))), max(1, Int((lineHeight * scale).rounded(.down))))
    }

    public func columnAndRow(x: CGFloat, y: CGFloat, topRow: Int, relativeToScroll: Bool) -> (column: Int, row: Int) {
        let column = Int((x / cellWidth).rounded(.down))
        var row = Int((y / lineHeight).rounded(.down))
        if relativeToScroll {
            row += topRow
        }
        return (column, row)
    }

    public func pointX(column: Int, columns: Int) -> CGFloat {
        return CGFloat(min(column, columns)) * cellWidth
    }

    public func pointY(row: Int, topRow: Int) -> CGFloat {
        return CGFloat(row - topRow) * lineHeight
    }

    public func nearestColumnBorder(x: CGFloat) -> Int {
        return Int((x / cellWidth).rounded())
    }
}

public struct ScreenUpdateScrollResult: Equatable {
    public var topRow: Int
    public var stopTextSelection: Bool
    public var selectionShift: Int
    public var awakenScrollBars: Bool
}

public enum TerminalScrollMath {
    public static func onScreenUpdated(topRow topRowIn: Int, rowsInHistory: Int, scrollCounter: Int,
                                       isSelectingText: Bool, isAutoScrollDisabled: Bool,
                                       skipScrolling skipScrollingIn: Bool = false) -> ScreenUpdateScrollResult {
        var topRow = topRowIn
        var skipScrolling = skipScrollingIn
        var stopSelection = false
        var selectionShift = 0
        var awaken = false

        if topRow < -rowsInHistory { topRow = -rowsInHistory }

        if isSelectingText || isAutoScrollDisabled {
            let rowShift = scrollCounter
            if -topRow + rowShift > rowsInHistory {
                if isSelectingText {
                    stopSelection = true
                }
                if isAutoScrollDisabled {
                    topRow = -rowsInHistory
                    skipScrolling = true
                }
            } else {
                skipScrolling = true
                topRow -= rowShift
                selectionShift = rowShift
            }
        }

        if !skipScrolling && topRow != 0 {
            if topRow < -3 {
                awaken = true
            }
            topRow = 0
        }

        return ScreenUpdateScrollResult(topRow: topRow, stopTextSelection: stopSelection,
                                        selectionShift: selectionShift, awakenScrollBars: awaken)
    }

    public static func clampTopRow(_ topRow: Int, rowsInHistory: Int) -> Int {
        return min(0, max(-rowsInHistory, topRow))
    }

    public static func rowsForScroll(distanceY: CGFloat, remainder: CGFloat, lineHeight: CGFloat) -> (rows: Int, remainder: CGFloat) {
        let total = distanceY + remainder
        let rows = Int(total / lineHeight)
        return (rows, total - CGFloat(rows) * lineHeight)
    }

    public static let FLING_DECELERATION_RATE_PER_MILLISECOND: CGFloat = 0.998

    public static let FLING_MIN_VELOCITY: CGFloat = 20

    public static func decayedVelocity(_ velocity: CGFloat, elapsed: CGFloat) -> CGFloat {
        return velocity * CGFloat(pow(Double(FLING_DECELERATION_RATE_PER_MILLISECOND), Double(elapsed * 1000)))
    }
}

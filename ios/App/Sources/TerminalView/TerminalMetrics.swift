import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Font metrics of the terminal renderer and the cell math derived from them. The `TerminalRenderer`
/// measures the font with CoreText and stores the result in this struct; everything here is pure
/// math so that it can be unit tested on any platform.
///
/// Unlike Android (which uses `Paint.getFontSpacing()` and the negative `ascent()`), line `i` of the
/// visible screen occupies the rectangle `y = i * lineHeight ..< (i + 1) * lineHeight` and its text
/// baseline is at `i * lineHeight + baselineOffset`.
public struct TerminalCellMetrics: Equatable {
    /// Width of a single monospaced cell, in points (advance of "X").
    public var cellWidth: CGFloat
    /// Height of a terminal line, in points (ascent + descent + leading, rounded up).
    public var lineHeight: CGFloat
    /// Font ascent, in points.
    public var ascent: CGFloat
    /// Font descent, in points (positive).
    public var descent: CGFloat

    public init(cellWidth: CGFloat, lineHeight: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.cellWidth = max(1, cellWidth)
        self.lineHeight = max(1, lineHeight)
        self.ascent = ascent
        self.descent = descent
    }

    /// Construct from raw font metrics.
    public static func fromFont(advance: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat) -> TerminalCellMetrics {
        let lineHeight = (ascent + descent + max(0, leading)).rounded(.up)
        return TerminalCellMetrics(cellWidth: advance, lineHeight: lineHeight, ascent: ascent, descent: descent)
    }

    /// Offset of the text baseline from the top of a line: the glyphs are vertically centered.
    public var baselineOffset: CGFloat {
        return ((lineHeight - (ascent + descent)) / 2).rounded(.down) + ascent
    }

    /// The terminal size for a view size. Port of `TerminalView.updateSize()`: at least 4x4.
    public func gridSize(width: CGFloat, height: CGFloat) -> (columns: Int, rows: Int) {
        let columns = max(4, Int((width / cellWidth).rounded(.down)))
        let rows = max(4, Int((height / lineHeight).rounded(.down)))
        return (columns, rows)
    }

    /// The cell size in pixels that is reported to the backend (`TIOCSWINSZ` `ws_xpixel`/`ws_ypixel`).
    public func cellPixelSize(scale: CGFloat) -> (width: Int, height: Int) {
        return (max(1, Int((cellWidth * scale).rounded(.down))), max(1, Int((lineHeight * scale).rounded(.down))))
    }

    /// Port of `TerminalView.getColumnAndRow()`: column and row of a point (in terminal content
    /// coordinates, i.e. relative to the top left of the first visible line).
    public func columnAndRow(x: CGFloat, y: CGFloat, topRow: Int, relativeToScroll: Bool) -> (column: Int, row: Int) {
        let column = Int((x / cellWidth).rounded(.down))
        var row = Int((y / lineHeight).rounded(.down))
        if relativeToScroll {
            row += topRow
        }
        return (column, row)
    }

    /// Port of `TerminalView.getPointX()`: the x coordinate of the left edge of a column.
    public func pointX(column: Int, columns: Int) -> CGFloat {
        return CGFloat(min(column, columns)) * cellWidth
    }

    /// Port of `TerminalView.getPointY()`: the y coordinate of the top edge of an external row.
    public func pointY(row: Int, topRow: Int) -> CGFloat {
        return CGFloat(row - topRow) * lineHeight
    }

    /// The column for a selection handle placed at a cell border with the given x coordinate.
    public func nearestColumnBorder(x: CGFloat) -> Int {
        return Int((x / cellWidth).rounded())
    }
}

/// The new scroll position after the screen was updated. Port of `TerminalView.onScreenUpdated()`.
public struct ScreenUpdateScrollResult: Equatable {
    /// The new top row.
    public var topRow: Int
    /// If the text selection must be stopped (the selected text scrolled out of the transcript).
    public var stopTextSelection: Bool
    /// The number of rows by which the text selection must be moved up.
    public var selectionShift: Int
    /// If a visible scroll indicator should be awakened (scrolled a noticeable amount).
    public var awakenScrollBars: Bool
}

public enum TerminalScrollMath {

    /// Port of `TerminalView.onScreenUpdated(boolean)`.
    ///
    /// - Parameters:
    ///   - topRow: Current top row (<= 0, negative when scrolled back into the transcript).
    ///   - rowsInHistory: `screen.activeTranscriptRows`.
    ///   - scrollCounter: `emulator.scrollCounter`, rows scrolled since the last update.
    ///   - isSelectingText: If text selection is active.
    ///   - isAutoScrollDisabled: `emulator.isAutoScrollDisabled`.
    ///   - skipScrolling: Skip scrolling to the bottom.
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
            // Do not scroll when selecting text.
            let rowShift = scrollCounter
            if -topRow + rowShift > rowsInHistory {
                // .. unless we're hitting the end of history transcript, in which
                // case we abort text selection and scroll to end.
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
            // Scroll down if not already there.
            if topRow < -3 {
                // Awaken scroll bars only if scrolling a noticeable amount
                // - we do not want visible scroll bars during normal typing
                // of one row at a time.
                awaken = true
            }
            topRow = 0
        }

        return ScreenUpdateScrollResult(topRow: topRow, stopTextSelection: stopSelection,
                                        selectionShift: selectionShift, awakenScrollBars: awaken)
    }

    /// Clamp a top row into the scrollable range `-rowsInHistory...0`.
    public static func clampTopRow(_ topRow: Int, rowsInHistory: Int) -> Int {
        return min(0, max(-rowsInHistory, topRow))
    }

    /// Convert a vertical finger movement into rows, keeping the remainder. Port of the
    /// `mScrollRemainder` handling of `TerminalView` `onScroll()`.
    ///
    /// - Parameters:
    ///   - distanceY: Distance scrolled, positive when the finger moves up (i.e. scroll towards
    ///     newer output), like Android's `onScroll` `distanceY`.
    ///   - remainder: Remainder of the previous call.
    /// - Returns: The rows to scroll down (negative = up into the history) and the new remainder.
    public static func rowsForScroll(distanceY: CGFloat, remainder: CGFloat, lineHeight: CGFloat) -> (rows: Int, remainder: CGFloat) {
        let total = distanceY + remainder
        let rows = Int(total / lineHeight)
        return (rows, total - CGFloat(rows) * lineHeight)
    }

    /// Fling deceleration rate per millisecond (matches `UIScrollView.DecelerationRate.normal`).
    public static let FLING_DECELERATION_RATE_PER_MS: CGFloat = 0.998

    /// Velocity (points/second) below which a fling stops.
    public static let FLING_MIN_VELOCITY: CGFloat = 20

    /// Decay a fling velocity over `dt` seconds.
    public static func decayedVelocity(_ velocity: CGFloat, dt: CGFloat) -> CGFloat {
        return velocity * CGFloat(pow(Double(FLING_DECELERATION_RATE_PER_MS), Double(dt * 1000)))
    }
}

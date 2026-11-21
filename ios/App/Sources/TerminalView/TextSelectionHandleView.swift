import UIKit

/// A draggable text selection handle. Port of `com.termux.view.textselection.TextSelectionHandleView`.
///
/// The handle is drawn below the selected line: a stem at the selection border and a knob below it.
/// The view's `anchorPoint` (in the terminal view's coordinates) is the top of the stem, i.e. the
/// bottom border of the selected cell, and is what `TerminalView` positions.
final class TextSelectionHandleView: UIView {

    enum Orientation {
        /// The start of the selection; the stem is at the left border of the first selected cell.
        case left
        /// The end of the selection; the stem is at the right border of the last selected cell.
        case right
    }

    static let knobDiameter: CGFloat = 18
    static let touchSize: CGFloat = 44

    let orientation: Orientation
    var handleColor: UIColor = UIColor.systemBlue {
        didSet { setNeedsDisplay() }
    }

    /// Called while dragging with the new anchor point in the superview's coordinates.
    var onDrag: ((TextSelectionHandleView, CGPoint, UIGestureRecognizer.State) -> Void)?

    private(set) var isDragging = false
    private var dragStartAnchor: CGPoint = .zero

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: CGRect(x: 0, y: 0, width: TextSelectionHandleView.touchSize, height: TextSelectionHandleView.touchSize))
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isHidden = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = orientation == .left ? "Selection start" : "Selection end"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The point (in superview coordinates) the handle points at.
    var anchorPoint: CGPoint {
        // The stem is at the horizontal center of the view, its top at the top of the view.
        return CGPoint(x: frame.midX, y: frame.minY)
    }

    /// Port of `positionAtCursor()`: move the handle so that it points at the given position.
    func position(at point: CGPoint) {
        frame.origin = CGPoint(x: point.x - bounds.width / 2, y: point.y)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let d = TextSelectionHandleView.knobDiameter
        let stemX = bounds.midX
        ctx.setFillColor(handleColor.cgColor)
        // Stem
        ctx.fill(CGRect(x: stemX - 1, y: 0, width: 2, height: d / 2))
        // Knob: offset to the outside of the selection like Android's teardrop handles.
        let knobX = orientation == .left ? stemX - d + 2 : stemX - 2
        ctx.fillEllipse(in: CGRect(x: knobX, y: d / 3, width: d, height: d))
        let corner = orientation == .left
            ? CGRect(x: stemX - d / 2, y: d / 3, width: d / 2, height: d / 2)
            : CGRect(x: stemX, y: d / 3, width: d / 2, height: d / 2)
        ctx.fill(corner)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        switch recognizer.state {
        case .began:
            isDragging = true
            dragStartAnchor = anchorPoint
            onDrag?(self, dragStartAnchor, .began)
        case .changed:
            let translation = recognizer.translation(in: superview)
            onDrag?(self, CGPoint(x: dragStartAnchor.x + translation.x, y: dragStartAnchor.y + translation.y), .changed)
        default:
            isDragging = false
            let translation = recognizer.translation(in: superview)
            onDrag?(self, CGPoint(x: dragStartAnchor.x + translation.x, y: dragStartAnchor.y + translation.y), recognizer.state)
        }
    }
}

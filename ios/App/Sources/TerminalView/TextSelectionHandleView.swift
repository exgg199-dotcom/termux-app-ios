import UIKit

final class TextSelectionHandleView: UIView {
    enum Orientation {
        case left
        case right
    }

    static let knobDiameter: CGFloat = 18
    static let touchSize: CGFloat = 44

    let orientation: Orientation
    var handleColor: UIColor = UIColor.systemBlue {
        didSet { setNeedsDisplay() }
    }

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

    var anchorPoint: CGPoint {
        return CGPoint(x: frame.midX, y: frame.minY)
    }

    func position(at point: CGPoint) {
        frame.origin = CGPoint(x: point.x - bounds.width / 2, y: point.y)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let diameter = TextSelectionHandleView.knobDiameter
        let stemX = bounds.midX
        context.setFillColor(handleColor.cgColor)
        context.fill(CGRect(x: stemX - 1, y: 0, width: 2, height: diameter / 2))
        let knobX = orientation == .left ? stemX - diameter + 2 : stemX - 2
        context.fillEllipse(in: CGRect(x: knobX, y: diameter / 3, width: diameter, height: diameter))
        let corner = orientation == .left
            ? CGRect(x: stemX - diameter / 2, y: diameter / 3, width: diameter / 2, height: diameter / 2)
            : CGRect(x: stemX, y: diameter / 3, width: diameter / 2, height: diameter / 2)
        context.fill(corner)
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

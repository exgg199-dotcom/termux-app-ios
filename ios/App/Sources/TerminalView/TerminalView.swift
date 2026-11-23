import UIKit
import TermuxTerminal

extension TerminalBuffer: TerminalSelectionTextSource {
    public func selectionText(x1: Int, y1: Int, x2: Int, y2: Int) -> String {
        return getSelectedText(selX1: x1, selY1: y1, selX2: x2, selY2: y2)
    }
}

final class TerminalView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    static let TERMINAL_CURSOR_BLINK_RATE_MIN = 100
    static let TERMINAL_CURSOR_BLINK_RATE_MAX = 2000

    private static let LOG_TAG = "TerminalView"

    weak var client: TerminalViewClient?

    private(set) var currentSession: TerminalSession?
    private(set) var emulator: TerminalEmulator?

    private(set) var renderer: TerminalRenderer

    private(set) var topRow = 0
    private var topRowCache: [String: Int] = [:]

    var terminalMargins: UIEdgeInsets = UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3) {
        didSet {
            if terminalMargins != oldValue {
                updateSize()
                invalidate()
            }
        }
    }

    var extraKeysView: UIView? {
        didSet { if isFirstResponder { reloadInputViews() } }
    }

    var isSoftKeyboardEnabled = true {
        didSet { if isFirstResponder && oldValue != isSoftKeyboardEnabled { reloadInputViews() } }
    }

    private let emptyInputView: UIView = {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }()

    override var inputView: UIView? {
        return isSoftKeyboardEnabled ? nil : emptyInputView
    }

    override var inputAccessoryView: UIView? {
        return extraKeysView
    }

    override var canBecomeFirstResponder: Bool { return true }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false

    private var selection: TerminalSelection?
    private var selectionShowTime: CFTimeInterval = 0
    private let startHandle = TextSelectionHandleView(orientation: .left)
    private let endHandle = TextSelectionHandleView(orientation: .right)
    private var longPressStartPoint: CGPoint = .zero
    private var editMenuInteractionStorage: AnyObject?

    private(set) var tapRecognizer: UITapGestureRecognizer!
    private(set) var panRecognizer: UIPanGestureRecognizer!
    private(set) var pinchRecognizer: UIPinchGestureRecognizer!
    private(set) var longPressRecognizer: UILongPressGestureRecognizer!

    private var scrollRemainder: CGFloat = 0
    private var lastPanTranslationY: CGFloat = 0
    private var mouseScrollStart: (x: Int, y: Int)?

    private var flingDisplayLink: CADisplayLink?
    private var flingVelocity: CGFloat = 0
    private var flingRemainder: CGFloat = 0
    private var flingPoint: CGPoint = .zero
    private var flingMouseTrackingAtStart = false
    private var flingRowsScrolled = 0
    private var flingLastTimestamp: CFTimeInterval?

    private var cursorBlinkTimer: Timer?
    private(set) var terminalCursorBlinkerRate = 0
    private var cursorBlinkVisible = false

    private var rightAltDown = false
    private var handledKeyUsages: Set<Int> = []
    private var keyRepeatTimer: Timer?
    private var repeatingUsage: Int?

    private let scrollIndicator = UIView()
    private var scrollIndicatorHideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        renderer = TerminalRenderer(fontSize: 12, customFontData: nil)
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        renderer = TerminalRenderer(fontSize: 12, customFontData: nil)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        isMultipleTouchEnabled = true
        clipsToBounds = true

        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityTraits = [.allowsDirectInteraction, .updatesFrequently]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        tapRecognizer = tap

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self
        addGestureRecognizer(longPress)
        longPressRecognizer = longPress
        tap.require(toFail: longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        addGestureRecognizer(pan)
        panRecognizer = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch

        for handle in [startHandle, endHandle] {
            handle.onDrag = { [weak self] handle, point, state in
                self?.handleSelectionHandleDrag(handle, to: point, state: state)
            }
            addSubview(handle)
        }

        scrollIndicator.backgroundColor = UIColor(white: 0.6, alpha: 0.8)
        scrollIndicator.layer.cornerRadius = 1.5
        scrollIndicator.alpha = 0
        scrollIndicator.isUserInteractionEnabled = false
        addSubview(scrollIndicator)
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        keyRepeatTimer?.invalidate()
        flingDisplayLink?.invalidate()
    }

    @discardableResult
    func attachSession(_ session: TerminalSession) -> Bool {
        if session === currentSession { return false }

        if let old = currentSession {
            topRowCache[old.handle] = topRow
        }
        forceStopTextSelectionMode()
        stopFling()

        currentSession = session
        emulator = nil
        topRow = 0

        updateSize()
        invalidate()
        return true
    }

    func sessionRemoved(_ session: TerminalSession) {
        topRowCache[session.handle] = nil
    }

    func onScreenUpdated(skipScrolling: Bool = false) {
        guard let emulator = emulator else { return }

        let result = TerminalScrollMath.onScreenUpdated(
            topRow: topRow, rowsInHistory: emulator.screen.activeTranscriptRows,
            scrollCounter: emulator.scrollCounter, isSelectingText: isSelectingText,
            isAutoScrollDisabled: emulator.isAutoScrollDisabled, skipScrolling: skipScrolling)
        if result.stopTextSelection {
            stopTextSelectionMode()
        }
        if result.selectionShift != 0 {
            selection?.decrementY(by: result.selectionShift)
        }
        topRow = result.topRow
        if result.awakenScrollBars {
            awakenScrollIndicator()
        }

        emulator.clearScrollCounter()
        invalidate()
    }

    func invalidate() {
        setNeedsDisplay()
        updateSelectionHandles()
    }

    func setFont(size: CGFloat, customFontData: Data?) {
        if size == renderer.fontSize && customFontData == renderer.customFontData { return }
        renderer = TerminalRenderer(fontSize: size, customFontData: customFontData)
        updateSize()
        invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSize()
        updateSelectionHandles()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            updateSize(force: true)
        }
    }

    private var contentSize: CGSize {
        return CGSize(width: max(0, bounds.width - terminalMargins.left - terminalMargins.right),
                      height: max(0, bounds.height - terminalMargins.top - terminalMargins.bottom))
    }

    func contentPoint(_ point: CGPoint) -> CGPoint {
        return CGPoint(x: point.x - terminalMargins.left, y: point.y - terminalMargins.top)
    }

    func updateSize(force: Bool = false) {
        let size = contentSize
        guard size.width > 0, size.height > 0, let session = currentSession else { return }

        let (newColumns, newRows) = renderer.metrics.gridSize(width: size.width, height: size.height)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pixels = renderer.metrics.cellPixelSize(scale: scale > 0 ? scale : 2)

        if force || emulator == nil || newColumns != emulator?.columns || newRows != emulator?.rows {
            session.updateSize(columns: newColumns, rows: newRows,
                               cellWidthPixels: pixels.width, cellHeightPixels: pixels.height)
            let emulatorWasNil = (emulator == nil)
            emulator = session.emulator
            client?.onEmulatorSet()

            if emulatorWasNil, let emulator = emulator {
                let rowsInHistory = emulator.screen.activeTranscriptRows
                if let cachedTopRow = topRowCache[session.handle], cachedTopRow >= -rowsInHistory {
                    topRow = cachedTopRow
                } else {
                    topRow = 0
                }
            } else if let emulator = emulator {
                topRow = TerminalScrollMath.clampTopRow(topRow, rowsInHistory: emulator.screen.activeTranscriptRows)
            }
            invalidate()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let background: UInt32
        if let emulator = emulator {
            background = emulator.colors.currentColors[TextStyle.COLOR_INDEX_BACKGROUND]
        } else {
            background = TerminalColors.colorScheme.defaultColors[TextStyle.COLOR_INDEX_BACKGROUND]
        }
        context.setFillColor(TerminalRenderer.uiColor(background).cgColor)
        context.fill(rect)

        guard let emulator = emulator else { return }

        let currentSelection = selection
        context.saveGState()
        context.translateBy(x: terminalMargins.left, y: terminalMargins.top)
        let visible = rect.offsetBy(dx: -terminalMargins.left, dy: -terminalMargins.top)
        renderer.render(emulator: emulator, context: context, topRow: topRow,
                        selectionY1: currentSelection?.y1 ?? -1, selectionY2: currentSelection?.y2 ?? -1,
                        selectionX1: currentSelection?.x1 ?? -1, selectionX2: currentSelection?.x2 ?? -1,
                        visibleRect: visible)
        context.restoreGState()
    }

    override var accessibilityValue: String? {
        get {
            guard let emulator = emulator else { return nil }
            return emulator.screen.getSelectedText(selX1: 0, selY1: topRow, selX2: emulator.columns, selY2: topRow + emulator.rows)
        }
        set { }
    }

    private func awakenScrollIndicator() {
        guard let emulator = emulator else { return }
        let rowsInHistory = emulator.screen.activeTranscriptRows
        guard rowsInHistory > 0 else { return }
        let totalRows = CGFloat(emulator.screen.activeRows)
        let height = max(20, bounds.height * CGFloat(emulator.rows) / totalRows)
        let offsetFraction = CGFloat(rowsInHistory + topRow) / CGFloat(rowsInHistory)
        let y = (bounds.height - height) * offsetFraction
        scrollIndicator.frame = CGRect(x: bounds.width - 5, y: y, width: 3, height: height)
        scrollIndicator.alpha = 1
        scrollIndicatorHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.scrollIndicator.alpha = 0 }
        }
        scrollIndicatorHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is TextSelectionHandleView {
            return false
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pinchRecognizer {
            return emulator != nil && !isSelectingText
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let emulator = emulator else { return }
        let point = contentPoint(recognizer.location(in: self))

        if isSelectingText {
            stopTextSelectionMode()
            return
        }

        if emulator.isMouseTrackingActive {
            sendMouseEventCode(at: point, button: TerminalEmulator.MOUSE_LEFT_BUTTON, pressed: true)
            sendMouseEventCode(at: point, button: TerminalEmulator.MOUSE_LEFT_BUTTON, pressed: false)
            return
        }

        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        client?.onSingleTapUp(self, at: point)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let emulator = emulator else { return }
        let point = contentPoint(recognizer.location(in: self))
        switch recognizer.state {
        case .began:
            stopFling()
            scrollRemainder = 0
            lastPanTranslationY = 0
            mouseScrollStart = nil
        case .changed:
            let translationY = recognizer.translation(in: self).y
            let delta = translationY - lastPanTranslationY
            lastPanTranslationY = translationY
            let result = TerminalScrollMath.rowsForScroll(distanceY: -delta, remainder: scrollRemainder,
                                                          lineHeight: renderer.lineHeight)
            scrollRemainder = result.remainder
            if result.rows != 0 {
                doScroll(rowsDown: result.rows, at: point)
            }
        case .ended:
            scrollRemainder = 0
            let velocity = -recognizer.velocity(in: self).y
            startFling(velocity: velocity, at: point, mouseTracking: emulator.isMouseTrackingActive)
        default:
            scrollRemainder = 0
            mouseScrollStart = nil
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard emulator != nil, !isSelectingText else { return }
        switch recognizer.state {
        case .changed:
            let newScale = client?.onScale(recognizer.scale) ?? recognizer.scale
            if newScale != recognizer.scale {
                recognizer.scale = newScale
            }
        default:
            break
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let emulator = emulator else { return }
        let point = contentPoint(recognizer.location(in: self))
        switch recognizer.state {
        case .began:
            if pinchRecognizer.state == .changed || pinchRecognizer.state == .began { return }
            if client?.onLongPress(at: point) == true { return }
            if !isSelectingText {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                longPressStartPoint = point
                startTextSelectionMode(at: point)
            }
        case .changed:
            guard var currentSelection = selection else { return }
            let deltaX = point.x - longPressStartPoint.x
            let deltaY = point.y - longPressStartPoint.y
            guard deltaX * deltaX + deltaY * deltaY > renderer.fontWidth * renderer.fontWidth else { return }
            hideEditMenu()
            let cell = renderer.metrics.columnAndRow(x: point.x, y: point.y, topRow: topRow, relativeToScroll: true)
            let column = max(0, min(emulator.columns - 1, cell.column))
            topRow = currentSelection.update(handle: .end, column: column, row: cell.row, rows: emulator.rows,
                                activeRows: emulator.screen.activeRows,
                                isAlternateBufferActive: emulator.isAlternateBufferActive,
                                topRow: topRow, text: emulator.screen)
            selection = currentSelection
            invalidate()
        case .ended:
            if isSelectingText {
                showEditMenu()
            }
        default:
            break
        }
    }

    private func sendMouseEventCode(at point: CGPoint, button: Int, pressed: Bool) {
        guard let emulator = emulator else { return }
        let cell = renderer.metrics.columnAndRow(x: point.x, y: point.y, topRow: topRow, relativeToScroll: false)
        var x = cell.column + 1
        var y = cell.row + 1
        if pressed && (button == TerminalEmulator.MOUSE_WHEELDOWN_BUTTON || button == TerminalEmulator.MOUSE_WHEELUP_BUTTON) {
            if let start = mouseScrollStart {
                x = start.x
                y = start.y
            } else {
                mouseScrollStart = (x, y)
            }
        }
        emulator.sendMouseEvent(button, column: x, row: y, pressed: pressed)
    }

    func doScroll(rowsDown: Int, at point: CGPoint = .zero) {
        guard let emulator = emulator else { return }
        let up = rowsDown < 0
        let amount = abs(rowsDown)
        var scrolledTranscript = false
        for _ in 0..<amount {
            if emulator.isMouseTrackingActive {
                sendMouseEventCode(at: point, button: up ? TerminalEmulator.MOUSE_WHEELUP_BUTTON : TerminalEmulator.MOUSE_WHEELDOWN_BUTTON, pressed: true)
            } else if emulator.isAlternateBufferActive {
                handleKeyCode(up ? AndroidKeyEvent.KEYCODE_DPAD_UP : AndroidKeyEvent.KEYCODE_DPAD_DOWN, keyModifiers: 0)
            } else {
                topRow = TerminalScrollMath.clampTopRow(topRow + (up ? -1 : 1), rowsInHistory: emulator.screen.activeTranscriptRows)
                scrolledTranscript = true
            }
        }
        if scrolledTranscript {
            awakenScrollIndicator()
            invalidate()
        }
    }

    private func startFling(velocity: CGFloat, at point: CGPoint, mouseTracking: Bool) {
        guard abs(velocity) > TerminalScrollMath.FLING_MIN_VELOCITY * 5 else {
            mouseScrollStart = nil
            return
        }
        stopFling()
        flingVelocity = velocity
        flingRemainder = 0
        flingPoint = point
        flingMouseTrackingAtStart = mouseTracking
        flingRowsScrolled = 0
        flingLastTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(flingStep(_:)))
        link.add(to: .main, forMode: .common)
        flingDisplayLink = link
    }

    private func stopFling() {
        flingDisplayLink?.invalidate()
        flingDisplayLink = nil
        flingVelocity = 0
    }

    @objc private func flingStep(_ link: CADisplayLink) {
        guard let emulator = emulator, emulator.isMouseTrackingActive == flingMouseTrackingAtStart else {
            stopFling()
            return
        }
        let elapsed: CGFloat
        if let last = flingLastTimestamp {
            elapsed = CGFloat(link.timestamp - last)
        } else {
            elapsed = CGFloat(link.duration)
        }
        flingLastTimestamp = link.timestamp

        let result = TerminalScrollMath.rowsForScroll(distanceY: flingVelocity * elapsed, remainder: flingRemainder,
                                                      lineHeight: renderer.lineHeight)
        flingRemainder = result.remainder
        var rows = result.rows
        if flingMouseTrackingAtStart {
            let limit = max(1, emulator.rows / 2)
            let remaining = limit - abs(flingRowsScrolled)
            if remaining <= 0 {
                stopFling()
                return
            }
            if abs(rows) > remaining { rows = rows < 0 ? -remaining : remaining }
        }
        if rows != 0 {
            flingRowsScrolled += rows
            doScroll(rowsDown: rows, at: flingPoint)
        }

        flingVelocity = TerminalScrollMath.decayedVelocity(flingVelocity, elapsed: elapsed)
        let atLimit = !emulator.isMouseTrackingActive && !emulator.isAlternateBufferActive
            && ((flingVelocity < 0 && topRow <= -emulator.screen.activeTranscriptRows) || (flingVelocity > 0 && topRow >= 0))
        if abs(flingVelocity) < TerminalScrollMath.FLING_MIN_VELOCITY || atLimit {
            stopFling()
            mouseScrollStart = nil
        }
    }

    var hasText: Bool {
        return true
    }

    func insertText(_ text: String) {
        guard emulator != nil else { return }
        stopTextSelectionMode()
        for codePointIn in TerminalInput.codePoints(text) {
            var codePoint = codePointIn
            if client?.readShiftKey() == true {
                codePoint = TerminalInput.toUpperCase(codePoint)
            }
            let converted = TerminalInput.softKeyboardCodePoint(codePoint)
            inputCodePoint(source: .softKeyboard, codePoint: converted.codePoint,
                           controlDownFromEvent: converted.controlHeld, leftAltDownFromEvent: false)
        }
    }

    func deleteBackward() {
        onKeyDown(AndroidKeyEvent.KEYCODE_DEL, source: .softKeyboard)
    }

    func inputCodePoint(source: KeyEventSource, codePoint: Int, controlDownFromEvent: Bool, leftAltDownFromEvent: Bool) {
        guard let session = currentSession else { return }

        emulator?.setCursorBlinkState(true)

        let controlDown = controlDownFromEvent || (client?.readControlKey() ?? false)
        let altDown = leftAltDownFromEvent || (client?.readAltKey() ?? false)

        if client?.onCodePoint(codePoint, controlDown: controlDown, session: session) == true { return }

        if let finalCodePoint = TerminalInput.transformCodePoint(codePoint, controlDown: controlDown, source: source) {
            session.writeCodePoint(prependEscape: altDown, codePoint: finalCodePoint)
        }
    }

    @discardableResult
    func onKeyDown(_ keyCode: Int, control: Bool = false, alt: Bool = false, shift: Bool = false, functionKey: Bool = false,
                   numLock: Bool = false, source: KeyEventSource, fallbackCodePoint: Int? = nil) -> Bool {
        guard let session = currentSession, emulator != nil else { return true }
        if isSelectingText {
            stopTextSelectionMode()
        }

        var eventKeyModifiers = 0
        if control { eventKeyModifiers |= KeyHandler.KEYMOD_CTRL }
        if alt { eventKeyModifiers |= KeyHandler.KEYMOD_ALT }
        if shift { eventKeyModifiers |= KeyHandler.KEYMOD_SHIFT }
        if client?.onKeyDown(keyCode, keyModifiers: eventKeyModifiers, session: session) == true {
            invalidate()
            return true
        }

        let controlDown = control || (client?.readControlKey() ?? false)
        let leftAltDown = alt || (client?.readAltKey() ?? false)
        let shiftDown = shift || (client?.readShiftKey() ?? false)
        let functionDown = functionKey || (client?.readFunctionKey() ?? false)

        var keyModifiers = 0
        if controlDown { keyModifiers |= KeyHandler.KEYMOD_CTRL }
        if leftAltDown { keyModifiers |= KeyHandler.KEYMOD_ALT }
        if shiftDown { keyModifiers |= KeyHandler.KEYMOD_SHIFT }
        if numLock { keyModifiers |= KeyHandler.KEYMOD_NUM_LOCK }

        var effectiveKeyCode = keyCode
        if functionDown {
            switch keyCode {
            case AndroidKeyEvent.KEYCODE_DPAD_UP: effectiveKeyCode = AndroidKeyEvent.KEYCODE_PAGE_UP
            case AndroidKeyEvent.KEYCODE_DPAD_DOWN: effectiveKeyCode = AndroidKeyEvent.KEYCODE_PAGE_DOWN
            case AndroidKeyEvent.KEYCODE_DPAD_LEFT: effectiveKeyCode = AndroidKeyEvent.KEYCODE_MOVE_HOME
            case AndroidKeyEvent.KEYCODE_DPAD_RIGHT: effectiveKeyCode = AndroidKeyEvent.KEYCODE_MOVE_END
            case AndroidKeyEvent.KEYCODE_DEL: effectiveKeyCode = AndroidKeyEvent.KEYCODE_FORWARD_DEL
            default: break
            }
        }

        if handleKeyCode(effectiveKeyCode, keyModifiers: keyModifiers) {
            return true
        }

        if let codePoint = fallbackCodePoint {
            inputCodePoint(source: source, codePoint: shiftDown ? TerminalInput.toUpperCase(codePoint) : codePoint,
                           controlDownFromEvent: controlDown, leftAltDownFromEvent: leftAltDown)
            return true
        }
        return false
    }

    @discardableResult
    func handleKeyCode(_ keyCode: Int, keyModifiers: Int) -> Bool {
        emulator?.setCursorBlinkState(true)

        if handleKeyCodeAction(keyCode, keyModifiers: keyModifiers) {
            return true
        }

        guard let session = currentSession, let sessionEmulator = session.emulator else { return false }
        guard let code = KeyHandler.getCode(keyCode: keyCode, keyMode: keyModifiers,
                                            cursorApp: sessionEmulator.isCursorKeysApplicationMode,
                                            keypadApplication: sessionEmulator.isKeypadApplicationMode) else {
            return false
        }
        session.write(code)
        return true
    }

    private func handleKeyCodeAction(_ keyCode: Int, keyModifiers: Int) -> Bool {
        let shiftDown = (keyModifiers & KeyHandler.KEYMOD_SHIFT) != 0
        switch keyCode {
        case AndroidKeyEvent.KEYCODE_PAGE_UP, AndroidKeyEvent.KEYCODE_PAGE_DOWN:
            if shiftDown, let emulator = emulator {
                doScroll(rowsDown: keyCode == AndroidKeyEvent.KEYCODE_PAGE_UP ? -emulator.rows : emulator.rows)
                return true
            }
        default:
            break
        }
        return false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = key.keyCode.rawValue
            if usage == HardwareKeyMapper.HID_RIGHT_ALT {
                rightAltDown = true
            }
            if handleHardwareKeyDown(key) {
                handledKeyUsages.insert(usage)
                startKeyRepeat(key)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(pressesEndedUnhandled(presses), with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(pressesEndedUnhandled(presses), with: event)
    }

    private func pressesEndedUnhandled(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = key.keyCode.rawValue
            if usage == HardwareKeyMapper.HID_RIGHT_ALT {
                rightAltDown = false
            }
            if repeatingUsage == usage {
                stopKeyRepeat()
            }
            if handledKeyUsages.remove(usage) == nil {
                unhandled.insert(press)
            }
        }
        return unhandled
    }

    private func handleHardwareKeyDown(_ key: UIKey) -> Bool {
        guard currentSession != nil, emulator != nil else { return false }
        let usage = key.keyCode.rawValue
        if HardwareKeyMapper.isModifierKey(usage) { return false }

        let flags = key.modifierFlags
        if flags.contains(.command) { return false }

        let control = flags.contains(.control)
        let alt = flags.contains(.alternate)
        let shift = flags.contains(.shift)
        let metaAlt = alt && !rightAltDown

        if let keyCode = HardwareKeyMapper.androidKeyCode(forHIDUsage: usage) {
            onKeyDown(keyCode, control: control, alt: alt, shift: shift,
                      numLock: AndroidKeyEvent.isNumpadKey(keyCode), source: .hardwareKeyboard,
                      fallbackCodePoint: HardwareKeyMapper.fallbackCodePoint(forKeyCode: keyCode))
            return true
        }

        if control || metaAlt {
            let scalars = Array(key.charactersIgnoringModifiers.unicodeScalars)
            guard scalars.count == 1 else { return false }
            var codePoint = Int(scalars[0].value)
            if shift && !control {
                codePoint = TerminalInput.toUpperCase(codePoint)
            }
            stopTextSelectionMode()
            inputCodePoint(source: .hardwareKeyboard, codePoint: codePoint,
                           controlDownFromEvent: control, leftAltDownFromEvent: metaAlt)
            return true
        }
        return false
    }

    private func startKeyRepeat(_ key: UIKey) {
        stopKeyRepeat()
        repeatingUsage = key.keyCode.rawValue
        keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, self.repeatingUsage == key.keyCode.rawValue else { return }
                _ = self.handleHardwareKeyDown(key)
            }
        }
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        repeatingUsage = nil
    }

    override func resignFirstResponder() -> Bool {
        stopKeyRepeat()
        handledKeyUsages.removeAll()
        rightAltDown = false
        return super.resignFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let paste = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(terminalPaste(_:)))
        paste.discoverabilityTitle = "Paste"
        var commands = [paste]
        if isSelectingText {
            let copy = UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(terminalCopy(_:)))
            copy.discoverabilityTitle = "Copy"
            commands.append(copy)
        }
        if client?.areHardwareKeyboardShortcutsEnabled == true {
            for shortcut in TerminalShortcut.allCases {
                let command = UIKeyCommand(input: shortcut.input, modifierFlags: shortcut.modifierFlags,
                                           action: #selector(performShortcutCommand(_:)))
                command.discoverabilityTitle = shortcut.title
                commands.append(command)
            }
        }
        return commands
    }

    @objc private func performShortcutCommand(_ command: UIKeyCommand) {
        guard let shortcut = TerminalShortcut.allCases.first(where: {
            $0.input == command.input && $0.modifierFlags == command.modifierFlags
        }) else { return }
        client?.performShortcut(shortcut)
    }

    @discardableResult
    func setTerminalCursorBlinkerRate(_ blinkRate: Int) -> Bool {
        let result: Bool
        if blinkRate != 0 && (blinkRate < TerminalView.TERMINAL_CURSOR_BLINK_RATE_MIN || blinkRate > TerminalView.TERMINAL_CURSOR_BLINK_RATE_MAX) {
            client?.log(.error, tag: TerminalView.LOG_TAG, "The cursor blink rate must be in between \(TerminalView.TERMINAL_CURSOR_BLINK_RATE_MIN)-\(TerminalView.TERMINAL_CURSOR_BLINK_RATE_MAX): \(blinkRate)")
            terminalCursorBlinkerRate = 0
            result = false
        } else {
            terminalCursorBlinkerRate = blinkRate
            result = true
        }
        if terminalCursorBlinkerRate == 0 {
            stopTerminalCursorBlinker()
        }
        return result
    }

    func setTerminalCursorBlinkerState(start: Bool, startOnlyIfCursorEnabled: Bool) {
        stopTerminalCursorBlinker()

        guard let emulator = emulator else { return }
        emulator.setCursorBlinkingEnabled(false)

        if start {
            if terminalCursorBlinkerRate < TerminalView.TERMINAL_CURSOR_BLINK_RATE_MIN || terminalCursorBlinkerRate > TerminalView.TERMINAL_CURSOR_BLINK_RATE_MAX {
                return
            } else if startOnlyIfCursorEnabled && !emulator.isCursorEnabled {
                return
            }

            emulator.setCursorBlinkingEnabled(true)
            cursorBlinkVisible = false
            toggleCursorBlink()
            let interval = TimeInterval(terminalCursorBlinkerRate) / 1000.0
            cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.toggleCursorBlink()
            }
        }
    }

    private func toggleCursorBlink() {
        guard let emulator = emulator else { return }
        cursorBlinkVisible.toggle()
        emulator.setCursorBlinkState(cursorBlinkVisible)
        setNeedsDisplay()
    }

    private func stopTerminalCursorBlinker() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
    }

    var isSelectingText: Bool { return selection != nil }

    var selectedText: String? {
        guard let currentSelection = selection, let emulator = emulator else { return nil }
        return emulator.getSelectedText(x1: currentSelection.x1, y1: currentSelection.y1, x2: currentSelection.x2, y2: currentSelection.y2)
    }

    func startTextSelectionMode(at point: CGPoint) {
        guard let emulator = emulator else { return }
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        let cell = renderer.metrics.columnAndRow(x: point.x, y: point.y, topRow: topRow, relativeToScroll: true)
        let row = min(max(cell.row, -emulator.screen.activeTranscriptRows), emulator.rows - 1)
        selection = TerminalSelection.initial(column: cell.column, row: row, columns: emulator.columns, text: emulator.screen)
        selectionShowTime = CACurrentMediaTime()
        client?.copyModeChanged(true)
        invalidate()
    }

    func stopTextSelectionMode() {
        if hideTextSelectionCursors(force: false) {
            client?.copyModeChanged(false)
            invalidate()
        }
    }

    private func forceStopTextSelectionMode() {
        if hideTextSelectionCursors(force: true) {
            client?.copyModeChanged(false)
            invalidate()
        }
    }

    private func hideTextSelectionCursors(force: Bool) -> Bool {
        guard selection != nil else { return false }
        if !force && CACurrentMediaTime() - selectionShowTime < 0.3 {
            return false
        }
        hideEditMenu()
        selection = nil
        startHandle.isHidden = true
        endHandle.isHidden = true
        return true
    }

    private func updateSelectionHandles() {
        guard let currentSelection = selection, let emulator = emulator else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let cellMetrics = renderer.metrics
        let visibleRows = topRow..<(topRow + emulator.rows)

        let startPoint = CGPoint(x: terminalMargins.left + cellMetrics.pointX(column: currentSelection.x1, columns: emulator.columns),
                                 y: terminalMargins.top + cellMetrics.pointY(row: currentSelection.y1 + 1, topRow: topRow))
        startHandle.position(at: startPoint)
        startHandle.isHidden = !visibleRows.contains(currentSelection.y1) && !startHandle.isDragging

        let endPoint = CGPoint(x: terminalMargins.left + cellMetrics.pointX(column: currentSelection.x2 + 1, columns: emulator.columns),
                               y: terminalMargins.top + cellMetrics.pointY(row: currentSelection.y2 + 1, topRow: topRow))
        endHandle.position(at: endPoint)
        endHandle.isHidden = !visibleRows.contains(currentSelection.y2) && !endHandle.isDragging

        let color = tintColor ?? UIColor.systemBlue
        startHandle.handleColor = color
        endHandle.handleColor = color
    }

    private func handleSelectionHandleDrag(_ handle: TextSelectionHandleView, to anchor: CGPoint, state: UIGestureRecognizer.State) {
        guard var currentSelection = selection, let emulator = emulator else { return }
        if state == .began {
            hideEditMenu()
            return
        }
        let point = contentPoint(anchor)
        let cellMetrics = renderer.metrics
        let row = Int(((point.y - cellMetrics.lineHeight / 2) / cellMetrics.lineHeight).rounded(.down)) + topRow
        let border = cellMetrics.nearestColumnBorder(x: point.x)
        let isStart = handle === startHandle
        let column = max(0, min(emulator.columns - 1, isStart ? border : border - 1))
        topRow = currentSelection.update(handle: isStart ? .start : .end, column: column, row: row, rows: emulator.rows,
                            activeRows: emulator.screen.activeRows,
                            isAlternateBufferActive: emulator.isAlternateBufferActive,
                            topRow: topRow, text: emulator.screen)
        selection = currentSelection
        invalidate()
        if state == .ended || state == .cancelled {
            showEditMenu()
        }
    }

    private var selectionRect: CGRect {
        guard let currentSelection = selection, let emulator = emulator else {
            return CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        }
        let cellMetrics = renderer.metrics
        var x1 = cellMetrics.pointX(column: currentSelection.x1, columns: emulator.columns)
        var x2 = cellMetrics.pointX(column: currentSelection.x2 + 1, columns: emulator.columns)
        if currentSelection.y1 != currentSelection.y2 {
            x1 = 0
            x2 = CGFloat(emulator.columns) * cellMetrics.cellWidth
        }
        let y1 = max(0, cellMetrics.pointY(row: currentSelection.y1, topRow: topRow))
        let y2 = min(contentSize.height, cellMetrics.pointY(row: currentSelection.y2 + 1, topRow: topRow))
        return CGRect(x: terminalMargins.left + min(x1, x2), y: terminalMargins.top + y1,
                      width: max(1, abs(x2 - x1)), height: max(1, y2 - y1))
    }

    private func showEditMenu() {
        let rect = selectionRect
        if #available(iOS 16.0, *) {
            let interaction: UIEditMenuInteraction
            if let existing = editMenuInteractionStorage as? UIEditMenuInteraction {
                interaction = existing
            } else {
                interaction = UIEditMenuInteraction(delegate: self)
                addInteraction(interaction)
                editMenuInteractionStorage = interaction
            }
            let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY))
            interaction.presentEditMenu(with: configuration)
        } else {
            let menu = UIMenuController.shared
            menu.menuItems = [
                UIMenuItem(title: "Copy", action: #selector(terminalCopy(_:))),
                UIMenuItem(title: "Paste", action: #selector(terminalPaste(_:))),
                UIMenuItem(title: "Select All", action: #selector(terminalSelectAll(_:))),
            ]
            menu.showMenu(from: self, rect: rect)
        }
    }

    private func hideEditMenu() {
        if #available(iOS 16.0, *) {
            (editMenuInteractionStorage as? UIEditMenuInteraction)?.dismissMenu()
        } else {
            UIMenuController.shared.hideMenu()
        }
    }

    fileprivate func editMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if isSelectingText {
            elements.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.terminalCopy(nil)
            })
        }
        if UIPasteboard.general.hasStrings {
            elements.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.terminalPaste(nil)
            })
        }
        elements.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            self?.terminalSelectAll(nil)
        })
        return elements
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(terminalCopy(_:)) {
            return isSelectingText
        } else if action == #selector(terminalPaste(_:)) {
            return UIPasteboard.general.hasStrings
        } else if action == #selector(terminalSelectAll(_:)) {
            return emulator != nil
        }
        return false
    }

    @objc func terminalCopy(_ sender: Any?) {
        guard let text = selectedText, let session = currentSession else { return }
        session.onCopyTextToClipboard(text)
        forceStopTextSelectionMode()
    }

    @objc func terminalPaste(_ sender: Any?) {
        forceStopTextSelectionMode()
        currentSession?.onPasteTextFromClipboard()
    }

    @objc func terminalSelectAll(_ sender: Any?) {
        guard let emulator = emulator else { return }
        let rowsInHistory = emulator.screen.activeTranscriptRows
        selection = TerminalSelection(x1: 0, y1: -rowsInHistory, x2: emulator.columns - 1, y2: emulator.rows - 1)
        selectionShowTime = CACurrentMediaTime()
        client?.copyModeChanged(true)
        invalidate()
        DispatchQueue.main.async { [weak self] in self?.showEditMenu() }
    }
}

@available(iOS 16.0, *)
extension TerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        return UIMenu(children: editMenuElements())
    }
}

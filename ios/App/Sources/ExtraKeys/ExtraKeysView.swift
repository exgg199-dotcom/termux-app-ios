import UIKit

/// The client of `ExtraKeysView`. Port of `ExtraKeysView.IExtraKeysView`.
protocol ExtraKeysViewClient: AnyObject {
    /// A (non special) extra key was clicked.
    func onExtraKeyButtonClick(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton)

    /// Return `true` if the client performed the haptic feedback itself, otherwise the default
    /// keyboard click is played.
    func performExtraKeyButtonHapticFeedback(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton) -> Bool
}

/// A view showing the extra keys (such as Escape, Ctrl, Alt) not normally available on a touch
/// screen keyboard. It is installed as the `inputAccessoryView` of the `TerminalView`.
/// Port of `com.termux.shared.termux.extrakeys.ExtraKeysView`.
///
/// * Tapping a special button (CTRL, ALT, SHIFT, FN) activates it for the next key, double tapping
///   or long pressing locks it until it is tapped again.
/// * Long pressing a repetitive key (arrows, BKSP, DEL, PGUP, PGDN) repeats it.
/// * Swiping up on a key with a popup sends the popup key instead.
final class ExtraKeysView: UIView, UIInputViewAudioFeedback {

    static let DEFAULT_BUTTON_TEXT_COLOR = UIColor.white
    static let DEFAULT_BUTTON_ACTIVE_TEXT_COLOR = UIColor(red: 0x80 / 255.0, green: 0xDE / 255.0, blue: 0xEA / 255.0, alpha: 1)
    static let DEFAULT_BUTTON_BACKGROUND_COLOR = UIColor.clear
    static let DEFAULT_BUTTON_ACTIVE_BACKGROUND_COLOR = UIColor(white: 0x7F / 255.0, alpha: 1)

    /// Android's `MIN/MAX_LONG_PRESS_DURATION` and `FALLBACK_LONG_PRESS_DURATION`.
    static let MIN_LONG_PRESS_DURATION: TimeInterval = 0.2
    static let MAX_LONG_PRESS_DURATION: TimeInterval = 3.0
    static let FALLBACK_LONG_PRESS_DURATION: TimeInterval = 0.4
    /// Android's `MIN/MAX_LONG_PRESS__REPEAT_DELAY` and `DEFAULT_LONG_PRESS_REPEAT_DELAY`.
    static let MIN_LONG_PRESS_REPEAT_DELAY: TimeInterval = 0.005
    static let MAX_LONG_PRESS_REPEAT_DELAY: TimeInterval = 2.0
    static let DEFAULT_LONG_PRESS_REPEAT_DELAY: TimeInterval = 0.08

    /// Height of one row of keys at a `terminal-toolbar-height` of 1 (Android: 37.5dp).
    static let DEFAULT_ROW_HEIGHT: CGFloat = 37.5

    weak var client: ExtraKeysViewClient?

    /// The state of the CTRL, ALT, SHIFT and FN toggles.
    let specialButtons = SpecialButtonsStateMachine()

    /// The keys that repeat while held.
    var repetitiveKeys: [String] = ExtraKeysConstants.PRIMARY_REPETITIVE_KEYS

    var buttonTextColor = ExtraKeysView.DEFAULT_BUTTON_TEXT_COLOR { didSet { updateAllButtonColors() } }
    var buttonActiveTextColor = ExtraKeysView.DEFAULT_BUTTON_ACTIVE_TEXT_COLOR { didSet { updateAllButtonColors() } }
    var buttonBackgroundColor = ExtraKeysView.DEFAULT_BUTTON_BACKGROUND_COLOR { didSet { updateAllButtonColors() } }
    var buttonActiveBackgroundColor = ExtraKeysView.DEFAULT_BUTTON_ACTIVE_BACKGROUND_COLOR
    var buttonTextAllCaps = true

    private(set) var longPressTimeout: TimeInterval = ExtraKeysView.FALLBACK_LONG_PRESS_DURATION
    private(set) var longPressRepeatDelay: TimeInterval = ExtraKeysView.DEFAULT_LONG_PRESS_REPEAT_DELAY

    private(set) var extraKeysInfo: ExtraKeysInfo?
    private var rowHeight: CGFloat = ExtraKeysView.DEFAULT_ROW_HEIGHT
    private var buttonViews: [[ExtraKeyButtonView]] = []
    private var columnCount = 0

    private var popupView: UILabel?
    private var repeatTimer: Timer?
    private var specialButtonLongHoldWork: DispatchWorkItem?
    private var longPressCount = 0

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = false
        specialButtons.onStateChanged = { [weak self] button, _ in
            self?.updateSpecialButtonColors(button)
        }
    }

    // MARK: Settings

    /// Port of `setLongPressTimeout()`.
    func setLongPressTimeout(_ duration: TimeInterval) {
        if duration >= ExtraKeysView.MIN_LONG_PRESS_DURATION && duration <= ExtraKeysView.MAX_LONG_PRESS_DURATION {
            longPressTimeout = duration
        } else {
            longPressTimeout = ExtraKeysView.FALLBACK_LONG_PRESS_DURATION
        }
    }

    /// Port of `setLongPressRepeatDelay()`.
    func setLongPressRepeatDelay(_ delay: TimeInterval) {
        if delay >= ExtraKeysView.MIN_LONG_PRESS_REPEAT_DELAY && delay <= ExtraKeysView.MAX_LONG_PRESS_REPEAT_DELAY {
            longPressRepeatDelay = delay
        } else {
            longPressRepeatDelay = ExtraKeysView.DEFAULT_LONG_PRESS_REPEAT_DELAY
        }
    }

    // MARK: UIInputViewAudioFeedback

    var enableInputClicksWhenVisible: Bool { return true }

    // MARK: Layout

    override var intrinsicContentSize: CGSize {
        let rows = CGFloat(buttonViews.count)
        return CGSize(width: UIView.noIntrinsicMetric, height: rows * rowHeight + safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: UIEdgeInsets(top: 0, left: safeAreaInsets.left, bottom: safeAreaInsets.bottom, right: safeAreaInsets.right))
        guard columnCount > 0, !buttonViews.isEmpty else { return }
        let width = area.width / CGFloat(columnCount)
        let height = area.height / CGFloat(buttonViews.count)
        for (row, views) in buttonViews.enumerated() {
            for (col, view) in views.enumerated() {
                view.frame = CGRect(x: area.minX + CGFloat(col) * width, y: area.minY + CGFloat(row) * height,
                                    width: width, height: height).integral
            }
        }
    }

    // MARK: Reload

    /// Reload this instance with new extra keys. Port of `reload()`.
    ///
    /// - Parameters:
    ///   - extraKeysInfo: The keys to show.
    ///   - heightScale: `terminal-toolbar-height` scale factor.
    func reload(_ extraKeysInfo: ExtraKeysInfo?, heightScale: CGFloat = 1) {
        guard let extraKeysInfo = extraKeysInfo else { return }
        self.extraKeysInfo = extraKeysInfo
        rowHeight = ExtraKeysView.DEFAULT_ROW_HEIGHT * heightScale

        stopScheduledExecutors()
        dismissPopup()
        specialButtons.resetCreated()
        for row in buttonViews {
            for view in row { view.removeFromSuperview() }
        }
        buttonViews = []

        let matrix = extraKeysInfo.matrix
        columnCount = extraKeysInfo.maximumRowLength
        for row in matrix {
            var views: [ExtraKeyButtonView] = []
            for buttonInfo in row {
                let view = ExtraKeyButtonView(buttonInfo: buttonInfo, extraKeysView: self)
                if specialButtons.isSpecialButton(buttonInfo), let special = SpecialButton.valueOf(buttonInfo.key) {
                    specialButtons.setCreated(special)
                }
                view.title = buttonTextAllCaps ? buttonInfo.display.uppercased() : buttonInfo.display
                addSubview(view)
                views.append(view)
            }
            buttonViews.append(views)
        }
        updateAllButtonColors()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    // MARK: Special buttons

    func isSpecialButton(_ button: ExtraKeyButton) -> Bool {
        return specialButtons.isSpecialButton(button)
    }

    /// Read whether a special button is active, deactivating it unless it's locked.
    /// Port of `readSpecialButton()`.
    func readSpecialButton(_ specialButton: SpecialButton, autoSetInActive: Bool) -> Bool? {
        return specialButtons.read(specialButton, autoSetInactive: autoSetInActive)
    }

    private func textColor(for buttonInfo: ExtraKeyButton) -> UIColor {
        if let special = SpecialButton.valueOf(buttonInfo.key), let state = specialButtons.state(for: special), state.isActive {
            return buttonActiveTextColor
        }
        return buttonTextColor
    }

    private func updateSpecialButtonColors(_ button: SpecialButton) {
        for row in buttonViews {
            for view in row where view.buttonInfo.key == button.key {
                view.textColor = textColor(for: view.buttonInfo)
                view.isLocked = specialButtons.state(for: button)?.isLocked ?? false
            }
        }
    }

    private func updateAllButtonColors() {
        for row in buttonViews {
            for view in row {
                view.textColor = textColor(for: view.buttonInfo)
                view.backgroundColor = buttonBackgroundColor
                if let special = SpecialButton.valueOf(view.buttonInfo.key) {
                    view.isLocked = specialButtons.state(for: special)?.isLocked ?? false
                }
            }
        }
    }

    // MARK: Clicks

    /// Port of `performExtraKeyButtonHapticFeedback()`.
    private func performExtraKeyButtonHapticFeedback(_ buttonInfo: ExtraKeyButton) {
        if client?.performExtraKeyButtonHapticFeedback(self, buttonInfo: buttonInfo) == true {
            return
        }
        UIDevice.current.playInputClick()
    }

    /// Port of `onAnyExtraKeyButtonClick()`.
    private func onAnyExtraKeyButtonClick(_ buttonInfo: ExtraKeyButton) {
        if isSpecialButton(buttonInfo) {
            if longPressCount > 0 { return }
            guard let special = SpecialButton.valueOf(buttonInfo.key) else { return }
            // Toggle active state and disable lock state if new state is not active, or lock on double tap.
            specialButtons.tap(special, at: CACurrentMediaTime())
        } else {
            client?.onExtraKeyButtonClick(self, buttonInfo: buttonInfo)
        }
    }

    // MARK: Touch handling (port of the button OnTouchListener)

    fileprivate func buttonTouchBegan(_ view: ExtraKeyButtonView) {
        view.backgroundColor = buttonActiveBackgroundColor
        // Start long press scheduled executors which will be stopped in next touch event.
        startScheduledExecutors(view.buttonInfo)
    }

    fileprivate func buttonTouchMoved(_ view: ExtraKeyButtonView, location: CGPoint) {
        guard let popup = view.buttonInfo.popup else { return }
        // Show popup on swipe up
        if popupView == nil && location.y < 0 {
            stopScheduledExecutors()
            view.backgroundColor = buttonBackgroundColor
            showPopup(above: view, popup: popup)
        }
        if popupView != nil && location.y > 0 {
            view.backgroundColor = buttonActiveBackgroundColor
            dismissPopup()
        }
    }

    fileprivate func buttonTouchCancelled(_ view: ExtraKeyButtonView) {
        view.backgroundColor = buttonBackgroundColor
        stopScheduledExecutors()
        dismissPopup()
    }

    fileprivate func buttonTouchEnded(_ view: ExtraKeyButtonView) {
        view.backgroundColor = buttonBackgroundColor
        stopScheduledExecutors()
        // If the touch up was not from a repetitive key or was with a key with a popup button
        if longPressCount == 0 || popupView != nil {
            // Trigger popup button click if swipe up complete
            if popupView != nil {
                dismissPopup()
                if let popup = view.buttonInfo.popup {
                    performExtraKeyButtonHapticFeedback(popup)
                    onAnyExtraKeyButtonClick(popup)
                }
            } else {
                performExtraKeyButtonHapticFeedback(view.buttonInfo)
                onAnyExtraKeyButtonClick(view.buttonInfo)
            }
        }
    }

    /// Port of `startScheduledExecutors()`.
    private func startScheduledExecutors(_ buttonInfo: ExtraKeyButton) {
        stopScheduledExecutors()
        longPressCount = 0
        if repetitiveKeys.contains(buttonInfo.key) {
            // Auto repeat key if long pressed until touch up stops it.
            repeatTimer = Timer.scheduledTimer(withTimeInterval: longPressTimeout, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.longPressCount += 1
                self.client?.onExtraKeyButtonClick(self, buttonInfo: buttonInfo)
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.longPressRepeatDelay, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.longPressCount += 1
                    self.client?.onExtraKeyButtonClick(self, buttonInfo: buttonInfo)
                }
            }
        } else if isSpecialButton(buttonInfo), let special = SpecialButton.valueOf(buttonInfo.key) {
            // Lock the key if long pressed. If the user does not long press, the touch up will cancel
            // the work item before it has a chance to run.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.specialButtons.longPress(special)
                self.longPressCount += 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            specialButtonLongHoldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressTimeout, execute: work)
        }
    }

    /// Port of `stopScheduledExecutors()`.
    private func stopScheduledExecutors() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        specialButtonLongHoldWork?.cancel()
        specialButtonLongHoldWork = nil
    }

    // MARK: Popup

    /// Port of `showPopup()`.
    private func showPopup(above view: ExtraKeyButtonView, popup: ExtraKeyButton) {
        let label = UILabel()
        label.text = buttonTextAllCaps ? popup.display.uppercased() : popup.display
        label.textAlignment = .center
        label.font = view.titleFont
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textColor = textColor(for: popup)
        label.backgroundColor = buttonActiveBackgroundColor
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        var frame = view.frame
        frame.origin.y -= frame.height
        if frame.minY < 0 {
            // No room above the first row (the accessory view may be clipped), overlay the key itself.
            frame.origin.y = view.frame.minY
        }
        label.frame = frame
        addSubview(label)
        popupView = label
    }

    /// Port of `dismissPopup()`.
    private func dismissPopup() {
        popupView?.removeFromSuperview()
        popupView = nil
    }
}

/// A single button of the extra keys row.
final class ExtraKeyButtonView: UIView {

    let buttonInfo: ExtraKeyButton
    private weak var extraKeysView: ExtraKeysView?
    private let label = UILabel()
    private let lockIndicator = UIView()

    var title: String? {
        get { return label.text }
        set { label.text = newValue }
    }

    var textColor: UIColor {
        get { return label.textColor }
        set {
            label.textColor = newValue
            lockIndicator.backgroundColor = newValue
        }
    }

    var titleFont: UIFont { return label.font }

    /// Show an underline when a special button is locked.
    var isLocked: Bool = false {
        didSet { lockIndicator.isHidden = !isLocked }
    }

    init(buttonInfo: ExtraKeyButton, extraKeysView: ExtraKeysView) {
        self.buttonInfo = buttonInfo
        self.extraKeysView = extraKeysView
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        isExclusiveTouch = false

        label.textAlignment = .center
        label.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.baselineAdjustment = .alignCenters
        label.isUserInteractionEnabled = false
        addSubview(label)

        lockIndicator.isHidden = true
        lockIndicator.isUserInteractionEnabled = false
        addSubview(lockIndicator)

        isAccessibilityElement = true
        accessibilityLabel = buttonInfo.display
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        lockIndicator.frame = CGRect(x: bounds.width * 0.3, y: bounds.height - 4, width: bounds.width * 0.4, height: 2)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        extraKeysView?.buttonTouchBegan(self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        extraKeysView?.buttonTouchMoved(self, location: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        extraKeysView?.buttonTouchEnded(self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        extraKeysView?.buttonTouchCancelled(self)
    }
}

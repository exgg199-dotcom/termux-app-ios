import UIKit

protocol ExtraKeysViewClient: AnyObject {
    func onExtraKeyButtonClick(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton)

    func performExtraKeyButtonHapticFeedback(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton) -> Bool
}

final class ExtraKeysView: UIView, UIInputViewAudioFeedback {
    static let DEFAULT_BUTTON_TEXT_COLOR = UIColor.white
    static let DEFAULT_BUTTON_ACTIVE_TEXT_COLOR = UIColor(red: 0x80 / 255.0, green: 0xDE / 255.0, blue: 0xEA / 255.0, alpha: 1)
    static let DEFAULT_BUTTON_BACKGROUND_COLOR = UIColor.clear
    static let DEFAULT_BUTTON_ACTIVE_BACKGROUND_COLOR = UIColor(white: 0x7F / 255.0, alpha: 1)

    static let MIN_LONG_PRESS_DURATION: TimeInterval = 0.2
    static let MAX_LONG_PRESS_DURATION: TimeInterval = 3.0
    static let FALLBACK_LONG_PRESS_DURATION: TimeInterval = 0.4
    static let MIN_LONG_PRESS_REPEAT_DELAY: TimeInterval = 0.005
    static let MAX_LONG_PRESS_REPEAT_DELAY: TimeInterval = 2.0
    static let DEFAULT_LONG_PRESS_REPEAT_DELAY: TimeInterval = 0.08

    static let DEFAULT_ROW_HEIGHT: CGFloat = 37.5

    weak var client: ExtraKeysViewClient?

    let specialButtons = SpecialButtonsStateMachine()

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

    func setLongPressTimeout(_ duration: TimeInterval) {
        if duration >= ExtraKeysView.MIN_LONG_PRESS_DURATION && duration <= ExtraKeysView.MAX_LONG_PRESS_DURATION {
            longPressTimeout = duration
        } else {
            longPressTimeout = ExtraKeysView.FALLBACK_LONG_PRESS_DURATION
        }
    }

    func setLongPressRepeatDelay(_ delay: TimeInterval) {
        if delay >= ExtraKeysView.MIN_LONG_PRESS_REPEAT_DELAY && delay <= ExtraKeysView.MAX_LONG_PRESS_REPEAT_DELAY {
            longPressRepeatDelay = delay
        } else {
            longPressRepeatDelay = ExtraKeysView.DEFAULT_LONG_PRESS_REPEAT_DELAY
        }
    }

    var enableInputClicksWhenVisible: Bool { return true }

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
            for (columnIndex, view) in views.enumerated() {
                view.frame = CGRect(x: area.minX + CGFloat(columnIndex) * width, y: area.minY + CGFloat(row) * height,
                                    width: width, height: height).integral
            }
        }
    }

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

    func isSpecialButton(_ button: ExtraKeyButton) -> Bool {
        return specialButtons.isSpecialButton(button)
    }

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

    private func performExtraKeyButtonHapticFeedback(_ buttonInfo: ExtraKeyButton) {
        if client?.performExtraKeyButtonHapticFeedback(self, buttonInfo: buttonInfo) == true {
            return
        }
        UIDevice.current.playInputClick()
    }

    private func onAnyExtraKeyButtonClick(_ buttonInfo: ExtraKeyButton) {
        if isSpecialButton(buttonInfo) {
            if longPressCount > 0 { return }
            guard let special = SpecialButton.valueOf(buttonInfo.key) else { return }
            specialButtons.tap(special, at: CACurrentMediaTime())
        } else {
            client?.onExtraKeyButtonClick(self, buttonInfo: buttonInfo)
        }
    }

    fileprivate func buttonTouchBegan(_ view: ExtraKeyButtonView) {
        view.backgroundColor = buttonActiveBackgroundColor
        startScheduledExecutors(view.buttonInfo)
    }

    fileprivate func buttonTouchMoved(_ view: ExtraKeyButtonView, location: CGPoint) {
        guard let popup = view.buttonInfo.popup else { return }
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
        if longPressCount == 0 || popupView != nil {
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

    private func startScheduledExecutors(_ buttonInfo: ExtraKeyButton) {
        stopScheduledExecutors()
        longPressCount = 0
        if repetitiveKeys.contains(buttonInfo.key) {
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

    private func stopScheduledExecutors() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        specialButtonLongHoldWork?.cancel()
        specialButtonLongHoldWork = nil
    }

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
            frame.origin.y = view.frame.minY
        }
        label.frame = frame
        addSubview(label)
        popupView = label
    }

    private func dismissPopup() {
        popupView?.removeFromSuperview()
        popupView = nil
    }
}

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

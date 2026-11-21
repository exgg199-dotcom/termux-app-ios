import UIKit
import AudioToolbox
import TermuxTerminal

/// The main screen: hosts the `TerminalView`, the `ExtraKeysView` (as keyboard accessory) and the
/// sessions drawer. Port of `TermuxActivity` together with its clients `TermuxTerminalViewClient`,
/// `TermuxTerminalSessionActivityClient` and `TermuxTerminalExtraKeys`.
final class TerminalViewController: UIViewController {

    private static let LOG_TAG = "TerminalViewController"

    private let environment: TermuxEnvironment
    private var sessionManager: SessionManager { return environment.sessionManager }
    private var properties: TermuxProperties { return environment.properties }
    private var preferences: AppPreferences { return environment.preferences }

    let terminalView = TerminalView(frame: .zero)
    let extraKeysView = ExtraKeysView(frame: CGRect(x: 0, y: 0, width: 320, height: 75))

    private let drawerView = SessionsDrawerView(frame: .zero)
    private let dimmingView = UIView()
    private var drawerLeadingConstraint: NSLayoutConstraint!
    private var drawerWidthConstraint: NSLayoutConstraint!
    private var edgePanRecognizer: UIScreenEdgePanGestureRecognizer!
    private var drawerPanStartConstant: CGFloat = 0
    private(set) var isDrawerOpen = false

    private var toastLabel: UILabel?
    private var toastHideWork: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []

    /// If the view is visible and the app is active, port of `TermuxActivity.isVisible()`.
    private var isVisible = false
    private var lastToastSessionHandle: String?

    private lazy var bellFeedback = UIImpactFeedbackGenerator(style: .medium)

    init(environment: TermuxEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.environment = .shared
        super.init(coder: coder)
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setUpTerminalView()
        setUpDrawer()

        sessionManager.delegate = self
        extraKeysView.client = self
        terminalView.client = self
        terminalView.extraKeysView = extraKeysView

        settingsObserver = NotificationCenter.default.addObserver(
            forName: TermuxEnvironment.settingsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onResume()
        })
        appObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onPause()
        })

        // Initial keyboard state, port of `hide-soft-keyboard-on-startup` / soft keyboard toggle.
        terminalView.isSoftKeyboardEnabled = !properties.hideSoftKeyboardOnStartup
            && (properties.softKeyboardToggleBehaviour == .showHide || preferences.softKeyboardEnabled)

        applySettings()

        // Attach the current session or create the first one.
        if sessionManager.sessions.isEmpty {
            sessionManager.addNewSession(name: nil)
        }
        if let session = sessionManager.currentSession {
            setCurrentSession(session, notify: false)
        }
        updateDrawer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onResume()
        if !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onPause()
    }

    /// Port of `TermuxActivity.onResume()` / `onStart()`.
    private func onResume() {
        guard viewIfLoaded?.window != nil, UIApplication.shared.applicationState != .background else { return }
        isVisible = true
        terminalView.onScreenUpdated()
        terminalView.setTerminalCursorBlinkerState(start: true, startOnlyIfCursorEnabled: true)
        updateBackgroundColor()
    }

    /// Port of `TermuxActivity.onStop()`.
    private func onPause() {
        isVisible = false
        terminalView.setTerminalCursorBlinkerState(start: false, startOnlyIfCursorEnabled: true)
    }

    override var prefersStatusBarHidden: Bool {
        return properties.fullscreen
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return isTerminalBackgroundDark ? .lightContent : .darkContent
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return properties.fullscreen
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.updateDrawerWidth(for: size)
            if !self.isDrawerOpen {
                self.drawerLeadingConstraint.constant = -self.drawerWidthConstraint.constant - 16
            }
            self.view.layoutIfNeeded()
        })
    }

    // MARK: - Setup

    private func setUpTerminalView() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        let bottomToKeyboard = terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        bottomToKeyboard.priority = .defaultHigh
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            terminalView.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
            bottomToKeyboard,
        ])
    }

    private func setUpDrawer() {
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimmingView.alpha = 0
        dimmingView.isHidden = true
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimmingView)
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeDrawerTapped)))

        drawerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawerView)
        drawerWidthConstraint = drawerView.widthAnchor.constraint(equalToConstant: 300)
        drawerLeadingConstraint = drawerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -316)
        let drawerBottom = drawerView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        drawerBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            drawerView.topAnchor.constraint(equalTo: view.topAnchor),
            drawerView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            drawerBottom,
            drawerWidthConstraint,
            drawerLeadingConstraint,
        ])
        drawerView.isHidden = true

        edgePanRecognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edgePanRecognizer.edges = .left
        view.addGestureRecognizer(edgePanRecognizer)
        terminalView.panRecognizer.require(toFail: edgePanRecognizer)

        let drawerPan = UIPanGestureRecognizer(target: self, action: #selector(handleDrawerPan(_:)))
        drawerView.addGestureRecognizer(drawerPan)

        drawerView.onSelectSession = { [weak self] index in
            guard let self = self, index < self.sessionManager.sessions.count else { return }
            self.setCurrentSession(self.sessionManager.sessions[index])
            self.closeDrawer(animated: true)
        }
        drawerView.onRenameSession = { [weak self] index in
            guard let self = self, index < self.sessionManager.sessions.count else { return }
            self.renameSession(self.sessionManager.sessions[index])
        }
        drawerView.onKillSession = { [weak self] index in
            guard let self = self, index < self.sessionManager.sessions.count else { return }
            self.killSession(self.sessionManager.sessions[index])
        }
        drawerView.onNewSession = { [weak self] in
            self?.addNewSession(name: nil)
            self?.closeDrawer(animated: true)
        }
        drawerView.onNewNamedSession = { [weak self] in
            self?.promptForNewNamedSession()
        }
        drawerView.onToggleKeyboard = { [weak self] in
            self?.onToggleSoftKeyboardRequest()
            self?.closeDrawer(animated: true)
        }
        drawerView.onSettings = { [weak self] in
            self?.closeDrawer(animated: true)
            self?.showSettings()
        }
        updateDrawerWidth(for: view.bounds.size)
    }

    private func updateDrawerWidth(for size: CGSize) {
        drawerWidthConstraint.constant = min(320, max(240, size.width * 0.8))
    }

    // MARK: - Settings

    /// Apply the loaded settings. Port of `TermuxActivity.reloadActivityStyling()`.
    private func applySettings() {
        let props = properties

        terminalView.setFont(size: CGFloat(preferences.fontSize), customFontData: environment.customFontData)
        terminalView.terminalMargins = UIEdgeInsets(top: CGFloat(props.terminalMarginVertical),
                                                    left: CGFloat(props.terminalMarginHorizontal),
                                                    bottom: CGFloat(props.terminalMarginVertical),
                                                    right: CGFloat(props.terminalMarginHorizontal))
        terminalView.setTerminalCursorBlinkerRate(props.terminalCursorBlinkRate)
        terminalView.setTerminalCursorBlinkerState(start: isVisible, startOnlyIfCursorEnabled: true)

        extraKeysView.buttonTextAllCaps = props.extraKeysTextAllCaps
        extraKeysView.reload(environment.extraKeysInfo, heightScale: CGFloat(props.terminalToolbarHeightScaleFactor))
        if let error = environment.extraKeysError {
            showToast(error, long: true)
        }

        applyTheme()
        updateBackgroundColor()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()

        if terminalView.isFirstResponder {
            terminalView.reloadInputViews()
        }
        terminalView.invalidate()
        updateDrawer()
    }

    /// The effective UI style: `AppTheme` from Settings, or `night-mode`/`use-black-ui` from
    /// termux.properties when the theme is "System".
    private var effectiveTheme: (style: UIUserInterfaceStyle, black: Bool) {
        switch preferences.theme {
        case .light: return (.light, false)
        case .dark: return (.dark, false)
        case .black: return (.dark, true)
        case .system:
            switch properties.nightMode {
            case "true": return (.dark, properties.rawProperties[TermuxProperties.KEY_USE_BLACK_UI]?.lowercased() == "true")
            case "false": return (.light, false)
            default: return (.unspecified, false)
            }
        }
    }

    private func applyTheme() {
        let theme = effectiveTheme
        view.window?.overrideUserInterfaceStyle = theme.style
        overrideUserInterfaceStyle = theme.style

        let isDark: Bool
        switch theme.style {
        case .dark: isDark = true
        case .light: isDark = false
        default: isDark = traitCollection.userInterfaceStyle == .dark
        }

        terminalView.keyboardAppearance = isDark ? .dark : .light
        if theme.black {
            drawerView.backgroundColor = .black
            extraKeysView.backgroundColor = .black
        } else if isDark {
            drawerView.backgroundColor = UIColor(white: 0.11, alpha: 1)
            extraKeysView.backgroundColor = UIColor(white: 0.13, alpha: 1)
        } else {
            drawerView.backgroundColor = .systemBackground
            extraKeysView.backgroundColor = UIColor(white: 0.93, alpha: 1)
        }
        extraKeysView.buttonTextColor = isDark ? .white : .black
        extraKeysView.buttonActiveTextColor = isDark ? ExtraKeysView.DEFAULT_BUTTON_ACTIVE_TEXT_COLOR : .systemBlue
        extraKeysView.buttonActiveBackgroundColor = isDark ? ExtraKeysView.DEFAULT_BUTTON_ACTIVE_BACKGROUND_COLOR : UIColor(white: 0.75, alpha: 1)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyTheme()
        }
    }

    private var terminalBackgroundColor: UInt32 {
        if let emulator = terminalView.emulator {
            return emulator.colors.currentColors[TextStyle.COLOR_INDEX_BACKGROUND]
        }
        return TerminalColors.colorScheme.defaultColors[TextStyle.COLOR_INDEX_BACKGROUND]
    }

    private var isTerminalBackgroundDark: Bool {
        return TerminalColors.getPerceivedBrightnessOfColor(terminalBackgroundColor) < 130
    }

    /// Port of `updateBackgroundColor()`.
    private func updateBackgroundColor() {
        view.backgroundColor = TerminalRenderer.uiColor(terminalBackgroundColor)
        terminalView.backgroundColor = view.backgroundColor
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showSettings() {
        let settings = SettingsViewController(environment: environment)
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    /// Port of `TermuxTerminalViewClient.changeFontSize()`.
    func changeFontSize(increase: Bool) {
        preferences.changeFontSize(increase: increase)
        terminalView.setFont(size: CGFloat(preferences.fontSize), customFontData: environment.customFontData)
    }

    // MARK: - Sessions

    var currentSession: TerminalSession? {
        return terminalView.currentSession
    }

    /// Port of `TermuxTerminalSessionActivityClient.setCurrentSession()`.
    func setCurrentSession(_ session: TerminalSession, notify: Bool = true) {
        if terminalView.attachSession(session) {
            // Notify about switched session if not already displaying the session.
            if notify {
                notifyOfSessionChange()
            }
        }
        sessionManager.currentSessionHandle = session.handle
        updateDrawer()
        updateBackgroundColor()
        updateTitle()
    }

    private func notifyOfSessionChange() {
        guard !properties.terminalSessionChangeToastDisabled, let session = currentSession else { return }
        showToast(sessionManager.displayName(of: session), long: false)
    }

    /// Port of `addNewSession()`.
    func addNewSession(name: String?) {
        let session = sessionManager.addNewSession(name: name)
        setCurrentSession(session)
    }

    /// Port of `switchToSession(boolean forward)`.
    func switchToSession(forward: Bool) {
        let sessions = sessionManager.sessions
        guard sessions.count > 1, let current = currentSession, var index = sessionManager.index(of: current) else { return }
        if forward {
            index += 1
            if index >= sessions.count { index = 0 }
        } else {
            index -= 1
            if index < 0 { index = sessions.count - 1 }
        }
        setCurrentSession(sessions[index])
    }

    /// Port of `switchToSession(int index)`.
    func switchToSession(index: Int) {
        let sessions = sessionManager.sessions
        guard index >= 0 && index < sessions.count else { return }
        setCurrentSession(sessions[index])
    }

    /// Port of `renameSession()`.
    func renameSession(_ session: TerminalSession) {
        let alert = UIAlertController(title: "Set session name", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = session.sessionName
            field.placeholder = "Session name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            self?.sessionManager.renameSession(session, to: alert?.textFields?.first?.text)
            self?.updateTitle()
        })
        presentOnTop(alert)
    }

    private func promptForNewNamedSession() {
        let alert = UIAlertController(title: "New named session", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Session name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            self?.addNewSession(name: alert?.textFields?.first?.text)
            self?.closeDrawer(animated: true)
        })
        presentOnTop(alert)
    }

    private func presentOnTop(_ controller: UIViewController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(controller, animated: true)
    }

    /// Kill a session (from the drawer or Cmd+W).
    func killSession(_ session: TerminalSession) {
        removeFinishedSession(session)
    }

    /// Port of `removeFinishedSession()`.
    func removeFinishedSession(_ finishedSession: TerminalSession) {
        let wasCurrent = finishedSession === currentSession
        guard let index = sessionManager.removeSession(finishedSession) else { return }
        terminalView.sessionRemoved(finishedSession)

        if sessionManager.sessions.isEmpty {
            // There are no sessions left: unlike Android the app can't finish itself, so start a
            // new session instead.
            addNewSession(name: nil)
        } else if wasCurrent {
            let newIndex = min(max(0, index - 1), sessionManager.sessions.count - 1)
            setCurrentSession(sessionManager.sessions[newIndex])
        } else {
            updateDrawer()
        }
    }

    private func updateTitle() {
        let title = currentSession.map { sessionManager.displayName(of: $0) } ?? "Termux"
        self.title = title
        view.window?.windowScene?.title = title
    }

    // MARK: - Drawer

    private func updateDrawer() {
        let current = currentSession
        drawerView.items = sessionManager.sessions.map { session in
            SessionsDrawerView.Item(title: sessionManager.displayName(of: session),
                                    subtitle: session.title,
                                    isCurrent: session === current,
                                    isRunning: session.isRunning,
                                    exitStatus: session.exitStatus)
        }
        drawerView.setKeyboardButtonTitle(terminalView.isSoftKeyboardEnabled && terminalView.isFirstResponder ? "Hide keyboard" : "Keyboard")
    }

    func toggleDrawer() {
        if isDrawerOpen {
            closeDrawer(animated: true)
        } else {
            openDrawer(animated: true)
        }
    }

    func openDrawer(animated: Bool) {
        updateDrawer()
        drawerView.isHidden = false
        dimmingView.isHidden = false
        isDrawerOpen = true
        drawerLeadingConstraint.constant = 0
        drawerView.scrollToCurrentSession()
        UIView.animate(withDuration: animated ? 0.25 : 0, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.dimmingView.alpha = 1
            self.view.layoutIfNeeded()
        })
        UIAccessibility.post(notification: .screenChanged, argument: drawerView)
    }

    func closeDrawer(animated: Bool) {
        guard isDrawerOpen || !drawerView.isHidden else { return }
        isDrawerOpen = false
        drawerLeadingConstraint.constant = -drawerWidthConstraint.constant - 16
        UIView.animate(withDuration: animated ? 0.25 : 0, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            self.dimmingView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            if !self.isDrawerOpen {
                self.drawerView.isHidden = true
                self.dimmingView.isHidden = true
            }
        })
        UIAccessibility.post(notification: .screenChanged, argument: terminalView)
    }

    @objc private func closeDrawerTapped() {
        closeDrawer(animated: true)
    }

    @objc private func handleEdgePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        let width = drawerWidthConstraint.constant
        switch recognizer.state {
        case .began:
            updateDrawer()
            drawerView.isHidden = false
            dimmingView.isHidden = false
        case .changed:
            let x = min(width, max(0, recognizer.translation(in: view).x))
            drawerLeadingConstraint.constant = x - width
            dimmingView.alpha = x / width
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).x
            let x = recognizer.translation(in: view).x
            if recognizer.state == .ended && (velocity > 300 || x > width / 2) {
                openDrawer(animated: true)
            } else {
                isDrawerOpen = true
                closeDrawer(animated: true)
            }
        default:
            break
        }
    }

    @objc private func handleDrawerPan(_ recognizer: UIPanGestureRecognizer) {
        let width = drawerWidthConstraint.constant
        switch recognizer.state {
        case .began:
            drawerPanStartConstant = drawerLeadingConstraint.constant
        case .changed:
            let constant = min(0, max(-width, drawerPanStartConstant + recognizer.translation(in: view).x))
            drawerLeadingConstraint.constant = constant
            dimmingView.alpha = (width + constant) / width
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).x
            if velocity < -300 || drawerLeadingConstraint.constant < -width / 2 {
                closeDrawer(animated: true)
            } else {
                openDrawer(animated: true)
            }
        default:
            break
        }
    }

    // MARK: - Keyboard

    /// Called when the soft keyboard should be toggled ("KEYBOARD" extra key, drawer button).
    /// Port of `onToggleSoftKeyboardRequest()`.
    func onToggleSoftKeyboardRequest() {
        if !terminalView.isFirstResponder {
            terminalView.isSoftKeyboardEnabled = true
            _ = terminalView.becomeFirstResponder()
        } else {
            terminalView.isSoftKeyboardEnabled.toggle()
        }
        if properties.softKeyboardToggleBehaviour == .enableDisable {
            preferences.softKeyboardEnabled = terminalView.isSoftKeyboardEnabled
        }
        updateDrawer()
    }

    /// Paste the clipboard into the current session, with bracketed paste if enabled.
    /// Port of `onPasteTextFromClipboard()`.
    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        terminalView.emulator?.paste(text)
    }

    // MARK: - Toast

    func showToast(_ text: String, long: Bool) {
        toastHideWork?.cancel()
        toastLabel?.removeFromSuperview()

        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.2, alpha: 0.9)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
            label.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor, constant: -24),
        ])
        toastLabel = label
        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }

        let work = DispatchWorkItem { [weak label] in
            UIView.animate(withDuration: 0.3, animations: { label?.alpha = 0 }, completion: { _ in label?.removeFromSuperview() })
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (long ? 3.5 : 2.0), execute: work)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - Hardware keyboard shortcuts

    override var canBecomeFirstResponder: Bool { return false }

    override var keyCommands: [UIKeyCommand]? {
        if properties.hardwareKeyboardShortcutsDisabled { return nil }
        var commands: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector, _ title: String) {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.discoverabilityTitle = title
            commands.append(command)
        }
        add("t", .command, #selector(newSessionCommand(_:)), "New Session")
        add("w", .command, #selector(closeSessionCommand(_:)), "Close Session")
        add("]", [.command, .shift], #selector(nextSessionCommand(_:)), "Next Session")
        add("[", [.command, .shift], #selector(previousSessionCommand(_:)), "Previous Session")
        // Ctrl+Alt+arrows (switch sessions, open/close the drawer) are handled in onKeyDown() like on Android.
        add("r", [.command, .shift], #selector(renameSessionCommand(_:)), "Rename Session")
        add("=", .command, #selector(increaseFontCommand(_:)), "Bigger Font")
        add("+", .command, #selector(increaseFontCommand(_:)), "Bigger Font")
        add("-", .command, #selector(decreaseFontCommand(_:)), "Smaller Font")
        add("k", [.command, .shift], #selector(toggleKeyboardCommand(_:)), "Toggle Keyboard")
        add(",", .command, #selector(settingsCommand(_:)), "Settings")
        for i in 1...9 {
            add("\(i)", .command, #selector(switchSessionCommand(_:)), "Session \(i)")
        }
        return commands
    }

    @objc private func newSessionCommand(_ sender: UIKeyCommand) { addNewSession(name: nil) }
    @objc private func closeSessionCommand(_ sender: UIKeyCommand) {
        if let session = currentSession { killSession(session) }
    }
    @objc private func nextSessionCommand(_ sender: UIKeyCommand) { switchToSession(forward: true) }
    @objc private func previousSessionCommand(_ sender: UIKeyCommand) { switchToSession(forward: false) }
    @objc private func renameSessionCommand(_ sender: UIKeyCommand) {
        if let session = currentSession { renameSession(session) }
    }
    @objc private func increaseFontCommand(_ sender: UIKeyCommand) { changeFontSize(increase: true) }
    @objc private func decreaseFontCommand(_ sender: UIKeyCommand) { changeFontSize(increase: false) }
    @objc private func toggleKeyboardCommand(_ sender: UIKeyCommand) { onToggleSoftKeyboardRequest() }
    @objc private func settingsCommand(_ sender: UIKeyCommand) { showSettings() }
    @objc private func switchSessionCommand(_ sender: UIKeyCommand) {
        if let input = sender.input, let number = Int(input) {
            switchToSession(index: number - 1)
        }
    }

    // MARK: - URL opening

    /// Port of the `terminal-onclick-url-open` handling of `onSingleTapUp()`.
    private func openURL(at point: CGPoint) -> Bool {
        guard let emulator = terminalView.emulator else { return false }
        let cell = terminalView.renderer.metrics.columnAndRow(x: point.x, y: point.y, topRow: terminalView.topRow, relativeToScroll: true)
        let word = emulator.screen.getWordAtLocation(x: cell.column, y: cell.row)
        guard !word.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        guard let match = detector.firstMatch(in: word, options: [], range: range), let url = match.url else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

// MARK: - TerminalViewClient (port of TermuxTerminalViewClient)

extension TerminalViewController: TerminalViewClient {

    func onScale(_ scale: CGFloat) -> CGFloat {
        if scale < 0.9 || scale > 1.1 {
            let increase = scale > 1
            changeFontSize(increase: increase)
            return 1.0
        }
        return scale
    }

    func onSingleTapUp(_ terminalView: TerminalView, at point: CGPoint) {
        if properties.terminalOnclickUrlOpen && openURL(at: point) {
            return
        }
        guard let emulator = terminalView.emulator, !emulator.isMouseTrackingActive else { return }
        if isDrawerOpen {
            closeDrawer(animated: true)
        }
        // Show the soft keyboard, unless it was disabled with the enable/disable toggle behaviour.
        if properties.softKeyboardToggleBehaviour == .showHide || preferences.softKeyboardEnabled {
            terminalView.isSoftKeyboardEnabled = true
        }
        if !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
        updateDrawer()
    }

    func copyModeChanged(_ copyMode: Bool) {
        // Disable drawer while copying.
        edgePanRecognizer.isEnabled = !copyMode
    }

    func onKeyDown(_ keyCode: Int, keyMod: Int, session: TerminalSession) -> Bool {
        if keyCode == AndroidKeyEvent.KEYCODE_ENTER && !session.isRunning {
            removeFinishedSession(session)
            return true
        }
        let ctrlAlt = KeyHandler.KEYMOD_CTRL | KeyHandler.KEYMOD_ALT
        if !properties.hardwareKeyboardShortcutsDisabled && (keyMod & ctrlAlt) == ctrlAlt {
            switch keyCode {
            case AndroidKeyEvent.KEYCODE_DPAD_DOWN:
                switchToSession(forward: true)
                return true
            case AndroidKeyEvent.KEYCODE_DPAD_UP:
                switchToSession(forward: false)
                return true
            case AndroidKeyEvent.KEYCODE_DPAD_RIGHT:
                openDrawer(animated: true)
                return true
            case AndroidKeyEvent.KEYCODE_DPAD_LEFT:
                closeDrawer(animated: true)
                return true
            default:
                break
            }
        }
        return false
    }

    func onLongPress(at point: CGPoint) -> Bool {
        return false
    }

    private func readExtraKeysSpecialButton(_ button: SpecialButton) -> Bool {
        guard let state = extraKeysView.readSpecialButton(button, autoSetInActive: true) else {
            log(.error, tag: TerminalViewController.LOG_TAG, "Failed to read an unregistered \(button) special button value from extra keys.")
            return false
        }
        return state
    }

    func readControlKey() -> Bool { return readExtraKeysSpecialButton(.CTRL) }
    func readAltKey() -> Bool { return readExtraKeysSpecialButton(.ALT) }
    func readShiftKey() -> Bool { return readExtraKeysSpecialButton(.SHIFT) }
    func readFnKey() -> Bool { return readExtraKeysSpecialButton(.FN) }

    func onCodePoint(_ codePoint: Int, ctrlDown: Bool, session: TerminalSession) -> Bool {
        if readFnKey() {
            // The FN extra key acts like the volume up key on Android.
            return handleVirtualFnKey(codePoint, session: session)
        } else if ctrlDown {
            // Ctrl+j (\n) or ctrl+m (\r, the return key of the iOS keyboard) on a finished session.
            if (codePoint == 106 || codePoint == 109) && !session.isRunning {
                removeFinishedSession(session)
                return true
            }
            if let action = properties.sessionShortcutAction(forCodePoint: codePoint) {
                switch action {
                case .createSession: addNewSession(name: nil)
                case .nextSession: switchToSession(forward: true)
                case .previousSession: switchToSession(forward: false)
                case .renameSession: renameSession(session)
                }
                return true
            }
        }
        return false
    }

    /// Port of the `mVirtualFnKeyDown` branch of `onCodePoint()`.
    private func handleVirtualFnKey(_ codePoint: Int, session: TerminalSession) -> Bool {
        switch TerminalInput.virtualFnKey(codePoint) {
        case .keyCode(let keyCode):
            if let term = session.emulator,
               let code = KeyHandler.getCode(keyCode: keyCode, keyMode: 0, cursorApp: term.isCursorKeysApplicationMode,
                                             keypadApplication: term.isKeypadApplicationMode) {
                session.write(code)
            }
        case .codePoint(let resultingCodePoint, let altDown):
            session.writeCodePoint(prependEscape: altDown, codePoint: resultingCodePoint)
        case .toggleKeyboard:
            onToggleSoftKeyboardRequest()
        case .consumed, .none:
            break
        }
        return true
    }

    func onEmulatorSet() {
        if let session = terminalView.currentSession {
            sessionManager.emulatorCreated(for: session)
        }
        terminalView.setTerminalCursorBlinkerState(start: isVisible, startOnlyIfCursorEnabled: true)
        updateBackgroundColor()
    }

    func log(_ level: LogLevel, tag: String, _ message: String) {
        sessionManager.log(level, tag: tag, message)
    }
}

// MARK: - ExtraKeysViewClient (port of TerminalExtraKeys / TermuxTerminalExtraKeys)

extension TerminalViewController: ExtraKeysViewClient {

    func onExtraKeyButtonClick(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton) {
        if buttonInfo.isMacro {
            let keys = buttonInfo.key.components(separatedBy: " ")
            var ctrlDown = false
            var altDown = false
            var shiftDown = false
            var fnDown = false
            for key in keys where !key.isEmpty {
                if SpecialButton.CTRL.key == key {
                    ctrlDown = true
                } else if SpecialButton.ALT.key == key {
                    altDown = true
                } else if SpecialButton.SHIFT.key == key {
                    shiftDown = true
                } else if SpecialButton.FN.key == key {
                    fnDown = true
                } else {
                    onTerminalExtraKeyButtonClick(key, ctrlDown: ctrlDown, altDown: altDown, shiftDown: shiftDown, fnDown: fnDown)
                    ctrlDown = false
                    altDown = false
                    shiftDown = false
                    fnDown = false
                }
            }
        } else {
            onTerminalExtraKeyButtonClick(buttonInfo.key, ctrlDown: false, altDown: false, shiftDown: false, fnDown: false)
        }
    }

    func performExtraKeyButtonHapticFeedback(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton) -> Bool {
        return false
    }

    private func onTerminalExtraKeyButtonClick(_ key: String, ctrlDown: Bool, altDown: Bool, shiftDown: Bool, fnDown: Bool) {
        switch key {
        case "KEYBOARD":
            onToggleSoftKeyboardRequest()
        case "DRAWER":
            toggleDrawer()
        case "PASTE":
            pasteFromClipboard()
        case "SCROLL":
            terminalView.emulator?.toggleAutoScrollDisabled()
        default:
            if let keyCode = ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS[key] {
                terminalView.onKeyDown(keyCode, ctrl: ctrlDown, alt: altDown, shift: shiftDown, fn: fnDown,
                                       source: .virtualKeyboard,
                                       fallbackCodePoint: HardwareKeyMapper.fallbackCodePoint(forKeyCode: keyCode))
            } else {
                // not a control char
                for codePoint in TerminalInput.codePoints(key) {
                    if fnDown, let session = currentSession {
                        _ = handleVirtualFnKey(codePoint, session: session)
                    } else {
                        terminalView.inputCodePoint(source: .virtualKeyboard, codePoint: codePoint,
                                                    controlDownFromEvent: ctrlDown, leftAltDownFromEvent: altDown)
                    }
                }
            }
        }
    }
}

// MARK: - SessionManagerDelegate (port of TermuxTerminalSessionActivityClient)

extension TerminalViewController: SessionManagerDelegate {

    func sessionManager(_ manager: SessionManager, textChangedIn session: TerminalSession) {
        if session === currentSession {
            terminalView.onScreenUpdated()
        }
    }

    func sessionManager(_ manager: SessionManager, titleChangedIn session: TerminalSession) {
        if session !== currentSession && isVisible && !properties.terminalSessionChangeToastDisabled {
            // Only show toast for other sessions than the current one, since the user probably
            // consciously caused the title change to change in the current session.
            showToast(manager.displayName(of: session), long: false)
        }
        updateDrawer()
        updateTitle()
    }

    func sessionManager(_ manager: SessionManager, sessionFinished session: TerminalSession) {
        if isVisible && session !== currentSession {
            // Show toast for non-current sessions that exit.
            showToast(manager.displayName(of: session) + " - exited", long: false)
        }
        // Auto-close the session on exit code '0' or '130', otherwise keep it with the
        // "[Process completed]" message until enter is pressed.
        if session.exitStatus == 0 || session.exitStatus == 130 {
            removeFinishedSession(session)
        } else {
            updateDrawer()
        }
    }

    func sessionManager(_ manager: SessionManager, copyText text: String, from session: TerminalSession) {
        UIPasteboard.general.string = text
        showToast("Copied to clipboard", long: false)
    }

    func sessionManager(_ manager: SessionManager, pasteInto session: TerminalSession?) {
        pasteFromClipboard()
    }

    func sessionManager(_ manager: SessionManager, bellIn session: TerminalSession) {
        guard isVisible else { return }
        switch properties.bellBehaviour {
        case .vibrate:
            if preferences.bellVibrate {
                bellFeedback.impactOccurred()
            }
        case .beep:
            AudioServicesPlaySystemSound(SystemSoundID(1057))
        case .ignore:
            break
        }
    }

    func sessionManager(_ manager: SessionManager, colorsChangedIn session: TerminalSession) {
        if session === currentSession {
            updateBackgroundColor()
        }
    }

    func sessionManager(_ manager: SessionManager, cursorStateChanged enabled: Bool) {
        // Do not start cursor blinking if not visible.
        if enabled && !isVisible { return }
        terminalView.setTerminalCursorBlinkerState(start: enabled, startOnlyIfCursorEnabled: false)
    }

    func sessionManagerSessionsDidChange(_ manager: SessionManager) {
        updateDrawer()
    }
}

/// A label with padding, used for toasts.
private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}

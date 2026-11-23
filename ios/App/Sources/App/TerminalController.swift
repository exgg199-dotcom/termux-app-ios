import UIKit
import SwiftUI
import Combine
import AudioToolbox
import TermuxTerminal

final class TerminalController: ObservableObject {
    private static let LOG_TAG = "TerminalController"

    let environment: TermuxEnvironment
    let terminalView: TerminalView
    let extraKeysView: ExtraKeysView

    @Published var isDrawerOpen = false
    @Published var isSettingsPresented = false
    @Published private(set) var toastMessage: String?
    @Published private(set) var isSoftKeyboardShown = true
    @Published private(set) var colorScheme: ColorScheme?
    @Published private(set) var usesBlackTheme = false
    @Published private(set) var terminalBackgroundColor = Color.black

    private var sessionManager: SessionManager { return environment.sessionManager }
    private var properties: TermuxProperties { return environment.properties }
    private var preferences: AppPreferences { return environment.preferences }

    private var isVisible = false
    private var hasStarted = false
    private var settingsObserver: NSObjectProtocol?
    private var toastHideWork: DispatchWorkItem?
    private let bellFeedback: UIImpactFeedbackGenerator

    init(environment: TermuxEnvironment) {
        self.environment = environment
        terminalView = TerminalView(frame: .zero)
        extraKeysView = ExtraKeysView(frame: CGRect(x: 0, y: 0, width: 320, height: 75))
        bellFeedback = UIImpactFeedbackGenerator(style: .medium)
        sessionManager.delegate = self
        extraKeysView.client = self
        terminalView.client = self
        terminalView.extraKeysView = extraKeysView
        terminalView.isSoftKeyboardEnabled = !environment.properties.hideSoftKeyboardOnStartup
            && (environment.properties.softKeyboardToggleBehaviour == .showHide || environment.preferences.softKeyboardEnabled)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: TermuxEnvironment.settingsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        applySettings()
        if sessionManager.sessions.isEmpty {
            sessionManager.addNewSession(name: nil)
        }
        if let session = sessionManager.currentSession {
            setCurrentSession(session, notify: false)
        }
    }

    func onAppear() {
        start()
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
            self?.onResume()
        }
    }

    func focusTerminal() {
        guard terminalView.window != nil, !isSettingsPresented else { return }
        if !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
        updateKeyboardState()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            environment.reloadSettings()
            onResume()
        case .inactive, .background:
            onPause()
        @unknown default:
            break
        }
    }

    private func onResume() {
        guard terminalView.window != nil else { return }
        isVisible = true
        terminalView.onScreenUpdated()
        terminalView.setTerminalCursorBlinkerState(start: true, startOnlyIfCursorEnabled: true)
        updateBackgroundColor()
    }

    private func onPause() {
        isVisible = false
        terminalView.setTerminalCursorBlinkerState(start: false, startOnlyIfCursorEnabled: true)
    }

    private func applySettings() {
        let currentProperties = properties

        terminalView.setFont(size: CGFloat(preferences.fontSize), customFontData: environment.customFontData)
        terminalView.terminalMargins = UIEdgeInsets(top: CGFloat(currentProperties.terminalMarginVertical),
                                                    left: CGFloat(currentProperties.terminalMarginHorizontal),
                                                    bottom: CGFloat(currentProperties.terminalMarginVertical),
                                                    right: CGFloat(currentProperties.terminalMarginHorizontal))
        terminalView.setTerminalCursorBlinkerRate(currentProperties.terminalCursorBlinkRate)
        terminalView.setTerminalCursorBlinkerState(start: isVisible, startOnlyIfCursorEnabled: true)

        extraKeysView.buttonTextAllCaps = currentProperties.extraKeysTextAllCaps
        extraKeysView.reload(environment.extraKeysInfo, heightScale: CGFloat(currentProperties.terminalToolbarHeightScaleFactor))
        if let error = environment.extraKeysError {
            showToast(error, long: true)
        }

        applyTheme()
        updateBackgroundColor()

        if terminalView.isFirstResponder {
            terminalView.reloadInputViews()
        }
        terminalView.invalidate()
        sessionManager.listChanged()
    }

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
        switch theme.style {
        case .dark: colorScheme = .dark
        case .light: colorScheme = .light
        default: colorScheme = nil
        }
        usesBlackTheme = theme.black

        let isDark: Bool
        switch theme.style {
        case .dark: isDark = true
        case .light: isDark = false
        default: isDark = terminalView.traitCollection.userInterfaceStyle == .dark
        }

        let keyboardAppearance: UIKeyboardAppearance = isDark ? .dark : .light
        if terminalView.keyboardAppearance != keyboardAppearance {
            terminalView.keyboardAppearance = keyboardAppearance
            if terminalView.isFirstResponder {
                terminalView.reloadInputViews()
            }
        }
        if theme.black {
            extraKeysView.backgroundColor = .black
        } else if isDark {
            extraKeysView.backgroundColor = UIColor(white: 0.13, alpha: 1)
        } else {
            extraKeysView.backgroundColor = UIColor(white: 0.93, alpha: 1)
        }
        extraKeysView.buttonTextColor = isDark ? .white : .black
        extraKeysView.buttonActiveTextColor = isDark ? ExtraKeysView.DEFAULT_BUTTON_ACTIVE_TEXT_COLOR : .systemBlue
        extraKeysView.buttonActiveBackgroundColor = isDark ? ExtraKeysView.DEFAULT_BUTTON_ACTIVE_BACKGROUND_COLOR : UIColor(white: 0.75, alpha: 1)
    }

    private var currentBackgroundColor: UInt32 {
        if let emulator = terminalView.emulator {
            return emulator.colors.currentColors[TextStyle.COLOR_INDEX_BACKGROUND]
        }
        return TerminalColors.colorScheme.defaultColors[TextStyle.COLOR_INDEX_BACKGROUND]
    }

    private func updateBackgroundColor() {
        let color = TerminalRenderer.uiColor(currentBackgroundColor)
        terminalView.backgroundColor = color
        let swiftUIColor = Color(color)
        if terminalBackgroundColor != swiftUIColor {
            terminalBackgroundColor = swiftUIColor
        }
    }

    func showSettings() {
        isDrawerOpen = false
        isSettingsPresented = true
    }

    func settingsDismissed() {
        focusTerminal()
    }

    func changeFontSize(increase: Bool) {
        preferences.changeFontSize(increase: increase)
        terminalView.setFont(size: CGFloat(preferences.fontSize), customFontData: environment.customFontData)
    }

    var currentSession: TerminalSession? {
        return terminalView.currentSession
    }

    func setCurrentSession(_ session: TerminalSession, notify: Bool = true) {
        if terminalView.attachSession(session) && notify {
            notifyOfSessionChange()
        }
        sessionManager.currentSessionHandle = session.handle
        sessionManager.listChanged()
        updateBackgroundColor()
    }

    func selectSession(withHandle handle: String) {
        guard let session = sessionManager.session(withHandle: handle) else { return }
        setCurrentSession(session)
        isDrawerOpen = false
    }

    private func notifyOfSessionChange() {
        guard !properties.terminalSessionChangeToastDisabled, let session = currentSession else { return }
        showToast(sessionManager.displayName(of: session), long: false)
    }

    func addNewSession(name: String?) {
        let session = sessionManager.addNewSession(name: name)
        setCurrentSession(session)
        isDrawerOpen = false
    }

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

    func switchToSession(index: Int) {
        let sessions = sessionManager.sessions
        guard index >= 0 && index < sessions.count else { return }
        setCurrentSession(sessions[index])
    }

    func renameSession(withHandle handle: String) {
        guard let session = sessionManager.session(withHandle: handle) else { return }
        renameSession(session)
    }

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
        })
        present(alert)
    }

    func promptForNewNamedSession() {
        let alert = UIAlertController(title: "New named session", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Session name"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            self?.addNewSession(name: alert?.textFields?.first?.text)
        })
        present(alert)
    }

    private func present(_ viewController: UIViewController) {
        guard var top = terminalView.window?.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(viewController, animated: true)
    }

    func killSession(withHandle handle: String) {
        guard let session = sessionManager.session(withHandle: handle) else { return }
        removeFinishedSession(session)
    }

    func removeFinishedSession(_ finishedSession: TerminalSession) {
        let wasCurrent = finishedSession === currentSession
        guard let index = sessionManager.removeSession(finishedSession) else { return }
        terminalView.sessionRemoved(finishedSession)

        if sessionManager.sessions.isEmpty {
            addNewSession(name: nil)
        } else if wasCurrent {
            let newIndex = min(max(0, index - 1), sessionManager.sessions.count - 1)
            setCurrentSession(sessionManager.sessions[newIndex])
        }
    }

    func toggleDrawer() {
        isDrawerOpen.toggle()
    }

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
        updateKeyboardState()
    }

    private func updateKeyboardState() {
        let shown = terminalView.isSoftKeyboardEnabled && terminalView.isFirstResponder
        if isSoftKeyboardShown != shown {
            isSoftKeyboardShown = shown
        }
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        terminalView.emulator?.paste(text)
    }

    func showToast(_ text: String, long: Bool) {
        toastHideWork?.cancel()
        toastMessage = text
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (long ? 3.5 : 2.0), execute: work)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

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

    private func handleVirtualFunctionKey(_ codePoint: Int, session: TerminalSession) -> Bool {
        switch TerminalInput.virtualFunctionKey(codePoint) {
        case .keyCode(let keyCode):
            if let sessionEmulator = session.emulator,
               let code = KeyHandler.getCode(keyCode: keyCode, keyMode: 0,
                                             cursorApp: sessionEmulator.isCursorKeysApplicationMode,
                                             keypadApplication: sessionEmulator.isKeypadApplicationMode) {
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

    private func onTerminalExtraKeyButtonClick(_ key: String, controlDown: Bool, altDown: Bool, shiftDown: Bool, functionDown: Bool) {
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
                terminalView.onKeyDown(keyCode, control: controlDown, alt: altDown, shift: shiftDown, functionKey: functionDown,
                                       source: .virtualKeyboard,
                                       fallbackCodePoint: HardwareKeyMapper.fallbackCodePoint(forKeyCode: keyCode))
            } else {
                for codePoint in TerminalInput.codePoints(key) {
                    if functionDown, let session = currentSession {
                        _ = handleVirtualFunctionKey(codePoint, session: session)
                    } else {
                        terminalView.inputCodePoint(source: .virtualKeyboard, codePoint: codePoint,
                                                    controlDownFromEvent: controlDown, leftAltDownFromEvent: altDown)
                    }
                }
            }
        }
    }
}

extension TerminalController: TerminalViewClient {
    func onScale(_ scale: CGFloat) -> CGFloat {
        if scale < 0.9 || scale > 1.1 {
            changeFontSize(increase: scale > 1)
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
            isDrawerOpen = false
        }
        if properties.softKeyboardToggleBehaviour == .showHide || preferences.softKeyboardEnabled {
            terminalView.isSoftKeyboardEnabled = true
        }
        if !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
        updateKeyboardState()
    }

    func copyModeChanged(_ copyMode: Bool) {
        if copyMode && isDrawerOpen {
            isDrawerOpen = false
        }
    }

    func onKeyDown(_ keyCode: Int, keyModifiers: Int, session: TerminalSession) -> Bool {
        if keyCode == AndroidKeyEvent.KEYCODE_ENTER && !session.isRunning {
            removeFinishedSession(session)
            return true
        }
        let controlAndAlt = KeyHandler.KEYMOD_CTRL | KeyHandler.KEYMOD_ALT
        if !properties.hardwareKeyboardShortcutsDisabled && (keyModifiers & controlAndAlt) == controlAndAlt {
            switch keyCode {
            case AndroidKeyEvent.KEYCODE_DPAD_DOWN:
                switchToSession(forward: true)
                return true
            case AndroidKeyEvent.KEYCODE_DPAD_UP:
                switchToSession(forward: false)
                return true
            case AndroidKeyEvent.KEYCODE_DPAD_RIGHT:
                isDrawerOpen = true
                return true
            case AndroidKeyEvent.KEYCODE_DPAD_LEFT:
                isDrawerOpen = false
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
            log(.error, tag: TerminalController.LOG_TAG, "Failed to read an unregistered \(button) special button value from extra keys.")
            return false
        }
        return state
    }

    func readControlKey() -> Bool { return readExtraKeysSpecialButton(.CTRL) }
    func readAltKey() -> Bool { return readExtraKeysSpecialButton(.ALT) }
    func readShiftKey() -> Bool { return readExtraKeysSpecialButton(.SHIFT) }
    func readFunctionKey() -> Bool { return readExtraKeysSpecialButton(.FN) }

    func onCodePoint(_ codePoint: Int, controlDown: Bool, session: TerminalSession) -> Bool {
        if readFunctionKey() {
            return handleVirtualFunctionKey(codePoint, session: session)
        } else if controlDown {
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

    var areHardwareKeyboardShortcutsEnabled: Bool {
        return !properties.hardwareKeyboardShortcutsDisabled
    }

    func performShortcut(_ shortcut: TerminalShortcut) {
        if let index = shortcut.sessionIndex {
            switchToSession(index: index)
            return
        }
        switch shortcut {
        case .newSession: addNewSession(name: nil)
        case .closeSession:
            if let session = currentSession { removeFinishedSession(session) }
        case .nextSession: switchToSession(forward: true)
        case .previousSession: switchToSession(forward: false)
        case .renameSession:
            if let session = currentSession { renameSession(session) }
        case .increaseFontSize, .increaseFontSizeWithPlus: changeFontSize(increase: true)
        case .decreaseFontSize: changeFontSize(increase: false)
        case .toggleKeyboard: onToggleSoftKeyboardRequest()
        case .toggleDrawer: toggleDrawer()
        case .settings: showSettings()
        default: break
        }
    }
}

extension TerminalController: ExtraKeysViewClient {
    func onExtraKeyButtonClick(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton) {
        if buttonInfo.isMacro {
            var controlDown = false
            var altDown = false
            var shiftDown = false
            var functionDown = false
            for key in buttonInfo.key.components(separatedBy: " ") where !key.isEmpty {
                if SpecialButton.CTRL.key == key {
                    controlDown = true
                } else if SpecialButton.ALT.key == key {
                    altDown = true
                } else if SpecialButton.SHIFT.key == key {
                    shiftDown = true
                } else if SpecialButton.FN.key == key {
                    functionDown = true
                } else {
                    onTerminalExtraKeyButtonClick(key, controlDown: controlDown, altDown: altDown,
                                                  shiftDown: shiftDown, functionDown: functionDown)
                    controlDown = false
                    altDown = false
                    shiftDown = false
                    functionDown = false
                }
            }
        } else {
            onTerminalExtraKeyButtonClick(buttonInfo.key, controlDown: false, altDown: false, shiftDown: false, functionDown: false)
        }
    }

    func performExtraKeyButtonHapticFeedback(_ view: ExtraKeysView, buttonInfo: ExtraKeyButton) -> Bool {
        return false
    }
}

extension TerminalController: SessionManagerDelegate {
    func sessionManager(_ manager: SessionManager, textChangedIn session: TerminalSession) {
        if session === currentSession {
            terminalView.onScreenUpdated()
        }
    }

    func sessionManager(_ manager: SessionManager, titleChangedIn session: TerminalSession) {
        if session !== currentSession && isVisible && !properties.terminalSessionChangeToastDisabled {
            showToast(manager.displayName(of: session), long: false)
        }
    }

    func sessionManager(_ manager: SessionManager, sessionFinished session: TerminalSession) {
        if isVisible && session !== currentSession {
            showToast(manager.displayName(of: session) + " - exited", long: false)
        }
        if session.exitStatus == 0 || session.exitStatus == 130 {
            removeFinishedSession(session)
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
        if enabled && !isVisible { return }
        terminalView.setTerminalCursorBlinkerState(start: enabled, startOnlyIfCursorEnabled: false)
    }
}

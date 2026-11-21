import Foundation

// Port of `com.termux.shared.termux.extrakeys.SpecialButton` and `SpecialButtonState`, plus the
// UI-independent state handling of `ExtraKeysView` (`onAnyExtraKeyButtonClick()`,
// `SpecialButtonsLongHoldRunnable` and `readSpecialButton()`).
//
// UIKit-free so that it can be unit tested on any platform.

/// The special toggle buttons of the extra keys row.
public struct SpecialButton: Hashable, CustomStringConvertible {
    public let key: String

    public init(_ key: String) { self.key = key }

    public static let CTRL = SpecialButton("CTRL")
    public static let ALT = SpecialButton("ALT")
    public static let SHIFT = SpecialButton("SHIFT")
    public static let FN = SpecialButton("FN")

    public static let defaultButtons: [SpecialButton] = [.CTRL, .ALT, .SHIFT, .FN]

    public static func valueOf(_ key: String) -> SpecialButton? {
        return defaultButtons.first { $0.key == key }
    }

    public var description: String { return key }
}

/// The state of a special button.
public final class SpecialButtonState {
    /// If special button has been created for the `ExtraKeysView`.
    public internal(set) var isCreated = false
    /// If special button is active.
    public internal(set) var isActive = false
    /// If special button is locked due to long hold (or a double tap) on it and should not be
    /// deactivated if its state is read.
    public internal(set) var isLocked = false
    /// Time of the tap that activated the button, used for double tap to lock.
    var lastActivationTime: TimeInterval?

    public init() {}
}

/// Holds the states of all special buttons and implements the transitions:
///
/// * tap: toggles the button, an active button acts as a one-shot modifier which is deactivated
///   once it has been read by the terminal (`read(_:autoSetInactive:)`).
/// * long press (Android behaviour) or double tap (iOS addition): locks the button active until
///   it is tapped again.
public final class SpecialButtonsStateMachine {

    /// Maximum interval between two taps that are treated as a double tap.
    public static let DOUBLE_TAP_INTERVAL: TimeInterval = 0.35

    public private(set) var states: [SpecialButton: SpecialButtonState] = [:]

    /// Called when the active/locked state of a button changes, so that the UI can be updated.
    public var onStateChanged: ((SpecialButton, SpecialButtonState) -> Void)?

    public init(buttons: [SpecialButton] = SpecialButton.defaultButtons) {
        for button in buttons {
            states[button] = SpecialButtonState()
        }
    }

    /// The keys of the registered special buttons.
    public var specialButtonsKeys: Set<String> {
        return Set(states.keys.map { $0.key })
    }

    public func isSpecialButton(_ button: ExtraKeyButton) -> Bool {
        return specialButtonsKeys.contains(button.key)
    }

    public func state(for button: SpecialButton) -> SpecialButtonState? {
        return states[button]
    }

    /// Mark all buttons as not created, called before the extra keys view is rebuilt.
    public func resetCreated() {
        for state in states.values { state.isCreated = false }
    }

    /// Mark a button as created (it's shown in the extra keys view).
    public func setCreated(_ button: SpecialButton) {
        states[button]?.isCreated = true
    }

    /// Handle a tap on a special button. Port of the special button part of
    /// `ExtraKeysView.onAnyExtraKeyButtonClick()`, extended with double tap to lock.
    public func tap(_ button: SpecialButton, at time: TimeInterval) {
        guard let state = states[button] else { return }
        if state.isActive && !state.isLocked,
           let last = state.lastActivationTime, time - last <= SpecialButtonsStateMachine.DOUBLE_TAP_INTERVAL {
            // Double tap: lock the button.
            state.isLocked = true
            state.lastActivationTime = nil
            onStateChanged?(button, state)
            return
        }

        // Toggle active state and disable lock state if new state is not active
        state.isActive = !state.isActive
        if !state.isActive {
            state.isLocked = false
            state.lastActivationTime = nil
        } else {
            state.lastActivationTime = time
        }
        onStateChanged?(button, state)
    }

    /// Handle a long hold on a special button. Port of `SpecialButtonsLongHoldRunnable.run()`.
    public func longPress(_ button: SpecialButton) {
        guard let state = states[button] else { return }
        // Toggle active and lock state
        state.isLocked = !state.isActive
        state.isActive = !state.isActive
        state.lastActivationTime = nil
        onStateChanged?(button, state)
    }

    /// Read the state of a special button. Port of `ExtraKeysView.readSpecialButton()`.
    ///
    /// - Parameter autoSetInactive: Set to `true` if the button should be deactivated (unless it
    ///   is locked) after being read, i.e. it was consumed as a one-shot modifier.
    /// - Returns: `nil` if the button is not registered, otherwise whether it is active.
    public func read(_ button: SpecialButton, autoSetInactive: Bool) -> Bool? {
        guard let state = states[button] else { return nil }
        if !state.isCreated || !state.isActive {
            return false
        }
        // Disable active state only if not locked
        if autoSetInactive && !state.isLocked {
            state.isActive = false
            state.lastActivationTime = nil
            onStateChanged?(button, state)
        }
        return true
    }

    /// Deactivate all buttons (e.g. when the session is switched).
    public func deactivateAll() {
        for (button, state) in states where state.isActive || state.isLocked {
            state.isActive = false
            state.isLocked = false
            state.lastActivationTime = nil
            onStateChanged?(button, state)
        }
    }
}

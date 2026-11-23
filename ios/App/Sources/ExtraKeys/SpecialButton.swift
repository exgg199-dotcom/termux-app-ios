import Foundation

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

public final class SpecialButtonState {
    public internal(set) var isCreated = false
    public internal(set) var isActive = false
    public internal(set) var isLocked = false
    var lastActivationTime: TimeInterval?

    public init() {}
}

public final class SpecialButtonsStateMachine {
    public static let DOUBLE_TAP_INTERVAL: TimeInterval = 0.35

    public private(set) var states: [SpecialButton: SpecialButtonState] = [:]

    public var onStateChanged: ((SpecialButton, SpecialButtonState) -> Void)?

    public init(buttons: [SpecialButton] = SpecialButton.defaultButtons) {
        for button in buttons {
            states[button] = SpecialButtonState()
        }
    }

    public var specialButtonsKeys: Set<String> {
        return Set(states.keys.map { $0.key })
    }

    public func isSpecialButton(_ button: ExtraKeyButton) -> Bool {
        return specialButtonsKeys.contains(button.key)
    }

    public func state(for button: SpecialButton) -> SpecialButtonState? {
        return states[button]
    }

    public func resetCreated() {
        for state in states.values { state.isCreated = false }
    }

    public func setCreated(_ button: SpecialButton) {
        states[button]?.isCreated = true
    }

    public func tap(_ button: SpecialButton, at time: TimeInterval) {
        guard let state = states[button] else { return }
        if state.isActive && !state.isLocked,
           let last = state.lastActivationTime, time - last <= SpecialButtonsStateMachine.DOUBLE_TAP_INTERVAL {
            state.isLocked = true
            state.lastActivationTime = nil
            onStateChanged?(button, state)
            return
        }

        state.isActive = !state.isActive
        if !state.isActive {
            state.isLocked = false
            state.lastActivationTime = nil
        } else {
            state.lastActivationTime = time
        }
        onStateChanged?(button, state)
    }

    public func longPress(_ button: SpecialButton) {
        guard let state = states[button] else { return }
        state.isLocked = !state.isActive
        state.isActive = !state.isActive
        state.lastActivationTime = nil
        onStateChanged?(button, state)
    }

    public func read(_ button: SpecialButton, autoSetInactive: Bool) -> Bool? {
        guard let state = states[button] else { return nil }
        if !state.isCreated || !state.isActive {
            return false
        }
        if autoSetInactive && !state.isLocked {
            state.isActive = false
            state.lastActivationTime = nil
            onStateChanged?(button, state)
        }
        return true
    }

    public func deactivateAll() {
        for (button, state) in states where state.isActive || state.isLocked {
            state.isActive = false
            state.isLocked = false
            state.lastActivationTime = nil
            onStateChanged?(button, state)
        }
    }
}

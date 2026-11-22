import UIKit
import TermuxTerminal

protocol TerminalViewClient: AnyObject {
    func onScale(_ scale: CGFloat) -> CGFloat

    func onSingleTapUp(_ terminalView: TerminalView, at point: CGPoint)

    func copyModeChanged(_ copyMode: Bool)

    func onKeyDown(_ keyCode: Int, keyModifiers: Int, session: TerminalSession) -> Bool

    func onLongPress(at point: CGPoint) -> Bool

    func readControlKey() -> Bool
    func readAltKey() -> Bool
    func readShiftKey() -> Bool
    func readFunctionKey() -> Bool

    func onCodePoint(_ codePoint: Int, controlDown: Bool, session: TerminalSession) -> Bool

    func onEmulatorSet()

    func log(_ level: LogLevel, tag: String, _ message: String)

    var areHardwareKeyboardShortcutsEnabled: Bool { get }

    func performShortcut(_ shortcut: TerminalShortcut)
}

enum TerminalShortcut: CaseIterable {
    case newSession
    case closeSession
    case nextSession
    case previousSession
    case renameSession
    case increaseFontSize
    case increaseFontSizeWithPlus
    case decreaseFontSize
    case toggleKeyboard
    case toggleDrawer
    case settings
    case session1
    case session2
    case session3
    case session4
    case session5
    case session6
    case session7
    case session8
    case session9

    var input: String {
        switch self {
        case .newSession: return "t"
        case .closeSession: return "w"
        case .nextSession: return "]"
        case .previousSession: return "["
        case .renameSession: return "r"
        case .increaseFontSize: return "="
        case .increaseFontSizeWithPlus: return "+"
        case .decreaseFontSize: return "-"
        case .toggleKeyboard: return "k"
        case .toggleDrawer: return "d"
        case .settings: return ","
        case .session1: return "1"
        case .session2: return "2"
        case .session3: return "3"
        case .session4: return "4"
        case .session5: return "5"
        case .session6: return "6"
        case .session7: return "7"
        case .session8: return "8"
        case .session9: return "9"
        }
    }

    var modifierFlags: UIKeyModifierFlags {
        switch self {
        case .nextSession, .previousSession, .renameSession, .toggleKeyboard, .toggleDrawer:
            return [.command, .shift]
        default:
            return .command
        }
    }

    var sessionIndex: Int? {
        switch self {
        case .session1: return 0
        case .session2: return 1
        case .session3: return 2
        case .session4: return 3
        case .session5: return 4
        case .session6: return 5
        case .session7: return 6
        case .session8: return 7
        case .session9: return 8
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .newSession: return "New Session"
        case .closeSession: return "Close Session"
        case .nextSession: return "Next Session"
        case .previousSession: return "Previous Session"
        case .renameSession: return "Rename Session"
        case .increaseFontSize, .increaseFontSizeWithPlus: return "Bigger Font"
        case .decreaseFontSize: return "Smaller Font"
        case .toggleKeyboard: return "Toggle Keyboard"
        case .toggleDrawer: return "Toggle Sessions Drawer"
        case .settings: return "Settings"
        default: return "Session \((sessionIndex ?? 0) + 1)"
        }
    }
}

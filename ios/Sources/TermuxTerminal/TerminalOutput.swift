import Foundation

public protocol TerminalOutput: AnyObject {
    func write(_ data: [UInt8])

    func titleChanged(oldTitle: String?, newTitle: String?)

    func onCopyTextToClipboard(_ text: String)

    func onPasteTextFromClipboard()

    func onBell()

    func onColorsChanged()
}

public extension TerminalOutput {
    func write(_ string: String) {
        write(Array(string.utf8))
    }
}

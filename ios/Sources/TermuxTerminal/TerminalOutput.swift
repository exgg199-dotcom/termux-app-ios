import Foundation

/// A client which receives callbacks from events triggered by feeding input to a `TerminalEmulator`.
///
/// Port of the abstract Java class `com.termux.terminal.TerminalOutput`.
public protocol TerminalOutput: AnyObject {
    /// Write bytes to the terminal client (i.e. to the process: keys, replies).
    func write(_ data: [UInt8])

    /// Notify the terminal client that the terminal title has changed.
    func titleChanged(oldTitle: String?, newTitle: String?)

    /// Notify the terminal client that text should be copied to clipboard.
    func onCopyTextToClipboard(_ text: String)

    /// Notify the terminal client that text should be pasted from clipboard.
    func onPasteTextFromClipboard()

    /// Notify the terminal client that a bell character (ASCII 7, bell, BEL, \a, ^G)) has been received.
    func onBell()

    func onColorsChanged()
}

public extension TerminalOutput {
    /// Write a string using the UTF-8 encoding to the terminal client.
    func write(_ string: String) {
        write(Array(string.utf8))
    }
}

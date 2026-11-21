// TEMPORARY: verbatim copy of the `TerminalBackend` protocol from docs/ARCHITECTURE.md.
// Delete this file as soon as Sources/TermuxTerminal provides `TerminalBackend`.

public protocol TerminalBackend: AnyObject {
    /// Called with process output. May be called on any thread.
    var onOutput: (([UInt8]) -> Void)? { get set }
    /// Called once when the process/shell exits. May be called on any thread.
    var onExit: ((Int32) -> Void)? { get set }
    func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    func write(_ data: [UInt8])                  // keyboard input → process
    func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    func terminate()
    var pid: Int32 { get }                       // -1 if not a real process
}

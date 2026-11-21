# Termux for iOS — Architecture & API Contract

This directory contains the iOS port of the Termux app. The Android modules map as follows:

| Android module        | iOS counterpart                          | Owner  |
|-----------------------|------------------------------------------|--------|
| `terminal-emulator`   | `Sources/TermuxTerminal` (SwiftPM, pure Foundation, builds on Linux) | core   |
| (JNI `termux.c` PTY)  | `Sources/TermuxShell` (`TerminalBackend` impls) | shell  |
| `terminal-view`       | `App/Sources/TerminalView` (UIKit)        | app    |
| `app`, `termux-shared`| `App/Sources/...` (UIKit app, XcodeGen `App/project.yml`) | app |

## Why there is no `/bin/sh` subprocess

iOS apps cannot `fork()`/`exec()` and cannot execute downloaded binaries (code
signing). So instead of Android's `forkpty` + bash, the app talks to a
`TerminalBackend`. Backends:

* `BuiltinShellBackend` (TermuxShell) — an in-process shell written in Swift
  with line editing, history, pipes and a set of builtin commands
  operating on the app sandbox (`$HOME` = `Documents/home`).
* `PTYProcessBackend` (TermuxShell, `#if !os(iOS)`) — real `forkpty` backend,
  used on macOS/Linux for tests and development.
* Future: SSH backend (e.g. via SwiftNIO SSH) — not in scope of first iteration.

## Shared API contract (MUST be respected by all parts)

Naming rule for the Java → Swift port: drop the `m` field prefix, `getX()` →
property `x`, `isX()` → property `isX`, constants keep their Java
UPPER_SNAKE names as `static let` on the same type (e.g.
`TextStyle.CHARACTER_ATTRIBUTE_BOLD`, `KeyHandler.KEYMOD_CTRL`,
`TerminalEmulator.MOUSE_LEFT_BUTTON`). Character storage stays UTF-16
(`[UInt16]`) exactly like Java `char[]`, so the port stays 1:1.

### TermuxTerminal

```swift
public protocol TerminalOutput: AnyObject {
    func write(_ data: [UInt8])                 // bytes the terminal sends to the process (keys, replies)
    func titleChanged(oldTitle: String?, newTitle: String?)
    func onCopyTextToClipboard(_ text: String)
    func onPasteTextFromClipboard()
    func onBell()
    func onColorsChanged()
}
public extension TerminalOutput { func write(_ string: String) }  // UTF-8

public protocol TerminalSessionClient: AnyObject {
    func onTextChanged(_ session: TerminalSession)
    func onTitleChanged(_ session: TerminalSession)
    func onSessionFinished(_ session: TerminalSession)
    func onCopyTextToClipboard(_ session: TerminalSession, text: String)
    func onPasteTextFromClipboard(_ session: TerminalSession?)
    func onBell(_ session: TerminalSession)
    func onColorsChanged(_ session: TerminalSession)
    func onTerminalCursorStateChange(_ state: Bool)
    var terminalCursorStyle: Int? { get }
    func log(_ level: LogLevel, tag: String, _ message: String)   // LogLevel: error, warn, info, debug, verbose
}

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

public final class TerminalSession: TerminalOutput {
    public let handle: String                    // UUID
    public var sessionName: String?
    public init(backend: TerminalBackend, transcriptRows: Int?, client: TerminalSessionClient?)
    public func updateTerminalSessionClient(_ client: TerminalSessionClient?)
    public func updateSize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) // first call initializes emulator + starts backend
    public var emulator: TerminalEmulator? { get }
    public var title: String? { get }
    public func writeCodePoint(prependEscape: Bool, codePoint: Int)
    public func reset()
    public func finishIfRunning()
    public var isRunning: Bool { get }
    public var exitStatus: Int32 { get }
    public var pid: Int32 { get }
    // Backend output is delivered to the emulator on DispatchQueue.main,
    // then client.onTextChanged(self) is called (on main).
}

public final class TerminalEmulator {
    public init(output: TerminalOutput, columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int, transcriptRows: Int?, client: TerminalSessionClient?)
    public func updateTerminalSessionClient(_ client: TerminalSessionClient?)
    public var screen: TerminalBuffer { get }
    public var rows: Int { get }; public var columns: Int { get }
    public var cellWidthPixels: Int { get }; public var cellHeightPixels: Int { get }
    public var isAlternateBufferActive: Bool { get }
    public func sendMouseEvent(_ mouseButton: Int, column: Int, row: Int, pressed: Bool)
    public func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    public var cursorRow: Int { get }; public var cursorCol: Int { get }
    public var cursorStyle: Int { get }
    public var isReverseVideo: Bool { get }
    public var isCursorEnabled: Bool { get }
    public var shouldCursorBeVisible: Bool { get }
    public func setCursorBlinkingEnabled(_ enabled: Bool)
    public func setCursorBlinkState(_ state: Bool)
    public var isKeypadApplicationMode: Bool { get }
    public var isCursorKeysApplicationMode: Bool { get }
    public var isMouseTrackingActive: Bool { get }
    public func append(_ buffer: [UInt8], length: Int)
    public var scrollCounter: Int { get }; public func clearScrollCounter()
    public var isAutoScrollDisabled: Bool { get }; public func toggleAutoScrollDisabled()
    public func reset()
    public func getSelectedText(x1: Int, y1: Int, x2: Int, y2: Int) -> String
    public var title: String? { get }
    public func paste(_ text: String)
    public let colors: TerminalColors
    // constants: MOUSE_LEFT_BUTTON, MOUSE_LEFT_BUTTON_MOVED, MOUSE_WHEELUP_BUTTON, MOUSE_WHEELDOWN_BUTTON,
    // TERMINAL_CURSOR_STYLE_BLOCK/UNDERLINE/BAR, DEFAULT_TERMINAL_TRANSCRIPT_ROWS, ...
}

public final class TerminalBuffer {
    public var activeTranscriptRows: Int { get }
    public var activeRows: Int { get }
    public var screenRows: Int { get }
    public var columns: Int { get }
    public func externalToInternalRow(_ externalRow: Int) -> Int
    public func allocateFullLineIfNecessary(_ row: Int) -> TerminalRow   // row = internal row
    public func getSelectedText(selX1: Int, selY1: Int, selX2: Int, selY2: Int) -> String
    public func getWordAtLocation(x: Int, y: Int) -> String
    public var transcriptText: String { get }
    public func getStyleAt(externalRow: Int, column: Int) -> Int64
}

public final class TerminalRow {
    public var text: [UInt16]        // UTF-16 code units, like Java char[]
    public var spaceUsed: Int { get }
    public var lineWrap: Bool
    public func findStartOfColumn(_ column: Int) -> Int
    public func getStyle(_ column: Int) -> Int64
}

public enum TextStyle {               // static helpers, same bit layout as Java (Int64)
    // CHARACTER_ATTRIBUTE_BOLD, _ITALIC, _UNDERLINE, _BLINK, _INVERSE, _INVISIBLE,
    // _STRIKETHROUGH, _PROTECTED, _DIM; COLOR_INDEX_FOREGROUND/BACKGROUND/CURSOR; NUM_INDEXED_COLORS
    public static func encode(foreColor: Int, backColor: Int, effect: Int) -> Int64
    public static func decodeForeColor(_ style: Int64) -> Int
    public static func decodeBackColor(_ style: Int64) -> Int
    public static func decodeEffect(_ style: Int64) -> Int
    // Colours: Int (0..259 index, or 0xff_RRGGBB for truecolor — same as Java)
}

public final class TerminalColors {
    public var currentColors: [UInt32]    // ARGB, size TextStyle.NUM_INDEXED_COLORS
    public func reset()
    public static func getPerceivedBrightnessOfColor(_ color: UInt32) -> Int
    public static var colorScheme: TerminalColorScheme
}
public final class TerminalColorScheme { public func updateWith(properties: [String: String]) }

public enum KeyHandler {
    // KEYMOD_ALT, KEYMOD_CTRL, KEYMOD_SHIFT, KEYMOD_NUM_LOCK
    // Key codes: iOS has no Android KeyEvent codes, so the port defines the same
    // numeric KEYCODE_* constants as Android (KEYCODE_DPAD_UP = 19, ...) and
    public static func getCode(keyCode: Int, keyMode: Int, cursorApp: Bool, keypadApplication: Bool) -> String?
    public static func getCodeFromTermcap(_ termcap: String, cursorKeysApplication: Bool, keypadApplication: Bool) -> String?
}
public enum WcWidth { public static func width(_ codePoint: Int) -> Int }
```

### TermuxShell

```swift
public final class BuiltinShellBackend: TerminalBackend {
    public init(homeDirectory: URL, environment: [String: String] = [:])
}
#if !os(iOS)
public final class PTYProcessBackend: TerminalBackend {
    public init(executable: String, arguments: [String], environment: [String], workingDirectory: String)
}
#endif
```

### App (iOS, UIKit, iOS 15+)

* `TerminalView: UIView, UIKeyInput` — port of `terminal-view` (CoreText rendering,
  scrolling, pinch-zoom font size, long-press text selection, mouse events).
* `ExtraKeysView` — port of extra keys row (`ESC TAB CTRL ALT - ↑ ↓ ← →` …),
  configurable via `~/.termux/termux.properties` `extra-keys`.
* `TerminalViewController` + session drawer (multiple sessions), settings.
* Built with XcodeGen: `cd ios/App && xcodegen && xcodebuild ...`.

## Building

```bash
cd ios
swift build && swift test          # Linux or macOS: core + shell
cd App && xcodegen generate        # macOS only
xcodebuild -project TermuxIOS.xcodeproj -scheme Termux -destination 'generic/platform=iOS Simulator' build
```

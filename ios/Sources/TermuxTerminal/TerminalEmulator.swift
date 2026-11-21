import Foundation

@inline(__always) private func ch(_ s: Unicode.Scalar) -> Int { return Int(s.value) }

/// Renders text into a screen. Contains all the terminal-specific knowledge and state. Emulates a subset of the X
/// Window System xterm terminal, which in turn is an emulator for a subset of the Digital Equipment Corporation vt100
/// terminal.
///
/// Faithful Swift port of `com.termux.terminal.TerminalEmulator`.
///
/// References:
/// - http://invisible-island.net/xterm/ctlseqs/ctlseqs.html
/// - http://en.wikipedia.org/wiki/ANSI_escape_code
/// - http://man.he.net/man4/console_codes
/// - http://bazaar.launchpad.net/~leonerd/libvterm/trunk/view/head:/src/state.c
/// - http://www.columbia.edu/~kermit/k95manual/iso2022.html
/// - http://www.vt100.net/docs/vt510-rm/chapter4
/// - http://bjh21.me.uk/all-escapes/all-escapes.txt
///
/// Images: sixel (`DCS q ... ST`) and iTerm inline images (`OSC 1337 ; File=... BEL`) depend on Android's
/// `Bitmap` in the original and are NOT rendered by this port. Both are still fully parsed and consumed (so they
/// do not corrupt the screen), but produce no output. `OSC 1337 ; ReportCellSize` is answered.
public final class TerminalEmulator: CustomStringConvertible {

    /// Log unknown or unimplemented escape sequences received from the shell process.
    private static let LOG_ESCAPE_SEQUENCES = false

    public static let MOUSE_LEFT_BUTTON = 0

    /// Mouse moving while having left mouse button pressed.
    public static let MOUSE_LEFT_BUTTON_MOVED = 32
    public static let MOUSE_WHEELUP_BUTTON = 64
    public static let MOUSE_WHEELDOWN_BUTTON = 65

    /// Used for invalid data - http://en.wikipedia.org/wiki/Replacement_character#Replacement_character
    public static let UNICODE_REPLACEMENT_CHAR = 0xFFFD

    // Escape sequences starting with an ESC character.
    // - https://vt100.net/docs/vt220-rm/chapter2.html#S2.5.1

    /// Escape processing: Not currently in an escape sequence.
    private static let ESC_NONE = 0
    /// Escape processing: Have seen an ESC character - proceed to doEsc()
    private static let ESC = 1
    /// Escape processing: Have seen ESC POUND
    private static let ESC_POUND = 2
    /// Escape processing: Have seen ESC and a character-set-select ( char
    private static let ESC_SELECT_LEFT_PAREN = 3
    /// Escape processing: Have seen ESC and a character-set-select ) char
    private static let ESC_SELECT_RIGHT_PAREN = 4
    /// Escape processing: "ESC [" or CSI (Control Sequence Introducer).
    private static let ESC_CSI = 6
    /// Escape processing: ESC [ ?
    private static let ESC_CSI_QUESTIONMARK = 7
    /// Escape processing: ESC [ $
    private static let ESC_CSI_DOLLAR = 8
    /// Escape processing: ESC %
    private static let ESC_PERCENT = 9
    /// Escape processing: `ESC ]` for Operating System Command (OSC).
    ///
    /// `OSC` commands may be in one of the following formats:
    /// - `OSC Ps ; Pt BEL` where `BEL` is the bell control passed as `\a`.
    /// - `OSC Ps ; Pt ST` where `ST` is the string terminator passed as `ESC \`.
    private static let ESC_OSC = 10
    /// Escape processing: `ESC` received while receiving a `ESC_OSC` command.
    private static let ESC_OSC__ESC = 11
    /// Escape processing: ESC [ >
    private static let ESC_CSI_BIGGERTHAN = 12
    /// Escape procession: `ESC P` for Device Control String (DCS).
    ///
    /// `DCS` commands are in the format `DCS data ST` where `ST` is the string terminator passed as `ESC \`.
    private static let ESC_DCS = 13
    /// Escape processing: CSI > (CSI ? Pm $)
    private static let ESC_CSI_QUESTIONMARK_ARG_DOLLAR = 14
    /// Escape processing: CSI $ARGS ' '
    private static let ESC_CSI_ARGS_SPACE = 15
    /// Escape processing: CSI $ARGS '*'
    private static let ESC_CSI_ARGS_ASTERIX = 16
    /// Escape processing: CSI "
    private static let ESC_CSI_DOUBLE_QUOTE = 17
    /// Escape processing: CSI '
    private static let ESC_CSI_SINGLE_QUOTE = 18
    /// Escape processing: CSI !
    private static let ESC_CSI_EXCLAMATION = 19
    /// Escape processing: `ESC _` for Application Program Command (APC).
    ///
    /// Currently, APC commands are only parsed, but ignored as none are supported.
    private static let ESC_APC = 20
    /// Escape processing: `ESC` received while receiving a `ESC_APC` command.
    private static let ESC_APC__ESC = 21
    /// Escape processing: ESC [ <parameter bytes>
    private static let ESC_CSI_UNSUPPORTED_PARAMETER_BYTE = 22
    /// Escape processing: ESC [ <parameter bytes> <intermediate bytes>
    private static let ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE = 23

    /// The number of parameter arguments including colon separated sub-parameters.
    private static let MAX_ESCAPE_PARAMETERS = 32

    /// DECSET 1 - application cursor keys.
    private static let DECSET_BIT_APPLICATION_CURSOR_KEYS = 1
    private static let DECSET_BIT_REVERSE_VIDEO = 1 << 1
    /// http://www.vt100.net/docs/vt510-rm/DECOM
    private static let DECSET_BIT_ORIGIN_MODE = 1 << 2
    /// http://www.vt100.net/docs/vt510-rm/DECAWM
    private static let DECSET_BIT_AUTOWRAP = 1 << 3
    /// DECSET 25 - if the cursor should be enabled, `isCursorEnabled`.
    private static let DECSET_BIT_CURSOR_ENABLED = 1 << 4
    private static let DECSET_BIT_APPLICATION_KEYPAD = 1 << 5
    /// DECSET 1000 - if to report mouse press&release events.
    private static let DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE = 1 << 6
    /// DECSET 1002 - like 1000, but report moving mouse while pressed.
    private static let DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT = 1 << 7
    /// DECSET 1004 - NOT implemented.
    private static let DECSET_BIT_SEND_FOCUS_EVENTS = 1 << 8
    /// DECSET 1006 - SGR-like mouse protocol (the modern sane choice).
    private static let DECSET_BIT_MOUSE_PROTOCOL_SGR = 1 << 9
    /// DECSET 2004 - see `paste(_:)`
    private static let DECSET_BIT_BRACKETED_PASTE_MODE = 1 << 10
    /// Toggled with DECLRMM - http://www.vt100.net/docs/vt510-rm/DECLRMM
    private static let DECSET_BIT_LEFTRIGHT_MARGIN_MODE = 1 << 11
    /// Not really DECSET bit... - http://www.vt100.net/docs/vt510-rm/DECSACE
    private static let DECSET_BIT_RECTANGULAR_CHANGEATTRIBUTE = 1 << 12

    public private(set) var title: String?
    private var titleStack: [String?] = []

    /// The cursor position. Between (0,0) and (rows-1, columns-1).
    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0

    /// The number of character rows and columns in the terminal screen.
    public private(set) var rows: Int
    public private(set) var columns: Int

    /// Size of a terminal cell in pixels.
    public private(set) var cellWidthPixels: Int
    public private(set) var cellHeightPixels: Int

    /// The number of terminal transcript rows that can be scrolled back to.
    public static let TERMINAL_TRANSCRIPT_ROWS_MIN = 100
    public static let TERMINAL_TRANSCRIPT_ROWS_MAX = 50000
    public static let DEFAULT_TERMINAL_TRANSCRIPT_ROWS = 2000

    // The supported terminal cursor styles.

    public static let TERMINAL_CURSOR_STYLE_BLOCK = 0
    public static let TERMINAL_CURSOR_STYLE_UNDERLINE = 1
    public static let TERMINAL_CURSOR_STYLE_BAR = 2
    public static let DEFAULT_TERMINAL_CURSOR_STYLE = TERMINAL_CURSOR_STYLE_BLOCK
    public static let TERMINAL_CURSOR_STYLES_LIST: [Int] = [TERMINAL_CURSOR_STYLE_BLOCK, TERMINAL_CURSOR_STYLE_UNDERLINE, TERMINAL_CURSOR_STYLE_BAR]

    /// The terminal cursor style.
    public private(set) var cursorStyle = TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE

    /// The normal screen buffer. Stores the characters that appear on the screen of the emulated terminal.
    let mainBuffer: TerminalBuffer
    /// The alternate screen buffer, exactly as large as the display and contains no additional saved lines (so that
    /// when the alternate screen buffer is active, you cannot scroll back to view saved lines).
    ///
    /// See http://www.xfree86.org/current/ctlseqs.html#The%20Alternate%20Screen%20Buffer
    let altBuffer: TerminalBuffer
    /// The current screen buffer, pointing at either `mainBuffer` or `altBuffer`.
    public private(set) var screen: TerminalBuffer

    /// The terminal session this emulator is bound to.
    ///
    /// Held weakly to avoid a retain cycle with `TerminalSession` (which owns the emulator). Whoever creates an
    /// emulator directly must keep the output alive.
    private weak var session: TerminalOutput?

    private(set) var client: TerminalSessionClient?

    /// Keeps track of the current argument of the current escape sequence. Ranges from 0 to MAX_ESCAPE_PARAMETERS-1.
    private var argIndex = 0
    /// Holds the arguments of the current escape sequence.
    private var args = [Int](repeating: 0, count: TerminalEmulator.MAX_ESCAPE_PARAMETERS)
    /// Holds the bit flags which arguments are sub parameters (after a colon) - bit N is set if `args[N]` is a sub
    /// parameter.
    private var argsSubParamsBitSet = 0

    /// The default max length for `terminalControlArgs`.
    /// Needs to be large enough to contain reasonable OSC 52 pastes.
    private static let TERMINAL_CONTROL_ARGS__DEFAULT_MAX_LENGTH = 16384

    /// The number of chars of an `OSC 1337` (iTerm image) command which are kept. Image data is discarded since
    /// images are not supported, but the whole command is still consumed.
    private static let OSC_1337__MAX_KEPT_LENGTH = 256

    /// The max length for `terminalControlArgs` used by `collectTerminalControlArgs(_:)`.
    private var terminalControlArgsMaxLength = TerminalEmulator.TERMINAL_CONTROL_ARGS__DEFAULT_MAX_LENGTH

    /// The terminal control arguments string buffer (UTF-16, like Java's StringBuilder), like for OSC, DCS, APC
    /// commands.
    private var terminalControlArgs: [UInt16] = []

    /// The integer Operating System Command `type` received as `ESC ] type ;`.
    private var oscType = -1

    /// If `true`, then `processCodePoint()` will directly call `receiveOsc()` as a fast path without additional
    /// checks.
    private var isFastPathOsc = false

    /// If `true`, then `processCodePoint()` will not print any CR/LF characters received.
    private var ignoreCrLfForOsc = false

    /// If `true`, then `processCodePoint()` will directly call `doDcs()` as a fast path without additional checks.
    private var isFastPathDcs = false

    /// Whether processing an `ESC` for a DCS command.
    private var ESC_DCS__ESC = false

    /// Whether processing a sixel `DCS q s..s ST` or `DCS P1; P2; P3; q s..s ST` command.
    private var ESC_DCS__SIXEL = false

    /// Whether to check if sixel command is being received when processing a DCS command.
    private var ESC_DCS__CHECK_IF_SIXEL = true

    /// The command part number in case a long sixel command was broken into parts for processing.
    private var sixelCommandPartNum = 0

    /// The maximum value of a sixel repeat introducer (from `TerminalSixel.SIXEL__MAX_REPEAT`).
    static let SIXEL__MAX_REPEAT = 8192

    /// True if the current escape sequence should continue, false if the current escape sequence should be
    /// terminated. Used when parsing a single character.
    private var continueSequenceFlag = false

    /// The current state of the escape sequence state machine. One of the ESC_* constants.
    private var escapeState = 0

    private let savedStateMain = SavedScreenState()
    private let savedStateAlt = SavedScreenState()

    /// http://www.vt100.net/docs/vt102-ug/table5-15.html
    private var useLineDrawingG0 = false
    private var useLineDrawingG1 = false
    private var useLineDrawingUsesG0 = true

    /// See `mapDecSetBitToInternalBit(_:)`.
    private var currentDecSetFlags = 0
    private var savedDecSetFlags = 0

    /// If insert mode (as opposed to replace mode) is active. In insert mode new characters are inserted, pushing
    /// existing text to the right. Characters moved past the right margin are lost.
    private var insertMode = false

    /// An array of tab stops. tabStop[i] is true if there is a tab stop set for column i.
    private var tabStop: [Bool]

    /// Top margin of screen for scrolling ranges from 0 to rows-2. Bottom margin ranges from topMargin + 2 to rows
    /// (Defines the first row after the scrolling region). Left/right margin in [0, columns].
    private var topMargin = 0
    private var bottomMargin = 0
    private var leftMargin = 0
    private var rightMargin = 0

    /// If the next character to be emitted will be automatically wrapped to the next line. Used to disambiguate the
    /// case where the cursor is positioned on the last column (columns-1). When standing there, a written character
    /// will be output in the last column, the cursor not moving but this flag will be set. When outputting another
    /// character this will move to the next line.
    private var aboutToAutoWrap = false

    /// If the cursor blinking is enabled. It requires cursor itself to be enabled, which is controlled
    /// by whether `DECSET_BIT_CURSOR_ENABLED` bit is set or not.
    private var cursorBlinkingEnabled = false

    /// If currently cursor should be in a visible state or not if `cursorBlinkingEnabled` is `true`.
    private var cursorBlinkState = false

    /// Current foreground, background and underline colors. Can either be a color index in [0,259] or a truecolor
    /// (24-bit) value. For a 24-bit value the top byte (0xff000000) is set.
    ///
    /// Note that the underline color is currently parsed but not yet used during rendering.
    var foreColor = 0
    var backColor = 0
    var underlineColor = 0

    /// Current `TextStyle` effect.
    var effect = 0

    /// The number of scrolled lines since last calling `clearScrollCounter()`. Used for moving selection up along
    /// with the scrolling text.
    public private(set) var scrollCounter = 0

    /// The cached value for this emulator for `TerminalView.topRow` as sessions/emulators may be switched.
    public var topRow = 0

    /// If automatic scrolling of terminal is disabled
    public private(set) var isAutoScrollDisabled = false

    private var utf8ToFollow = 0
    private var utf8Index = 0
    private var utf8InputBuffer = [UInt8](repeating: 0, count: 4)
    private var lastEmittedCodePoint = -1

    public let colors = TerminalColors()

    private static let LOG_TAG = "TerminalEmulator"

    private func isDecsetInternalBitSet(_ bit: Int) -> Bool {
        return (currentDecSetFlags & bit) != 0
    }

    private func setDecsetinternalBit(_ internalBit: Int, _ set: Bool) {
        if set {
            // The mouse modes are mutually exclusive.
            if internalBit == TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE {
                setDecsetinternalBit(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT, false)
            } else if internalBit == TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT {
                setDecsetinternalBit(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE, false)
            }
        }
        if set {
            currentDecSetFlags |= internalBit
        } else {
            currentDecSetFlags &= ~internalBit
        }
    }

    static func mapDecSetBitToInternalBit(_ decsetBit: Int) -> Int {
        switch decsetBit {
        case 1: return DECSET_BIT_APPLICATION_CURSOR_KEYS
        case 5: return DECSET_BIT_REVERSE_VIDEO
        case 6: return DECSET_BIT_ORIGIN_MODE
        case 7: return DECSET_BIT_AUTOWRAP
        case 25: return DECSET_BIT_CURSOR_ENABLED
        case 66: return DECSET_BIT_APPLICATION_KEYPAD
        case 69: return DECSET_BIT_LEFTRIGHT_MARGIN_MODE
        case 1000: return DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE
        case 1002: return DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT
        case 1004: return DECSET_BIT_SEND_FOCUS_EVENTS
        case 1006: return DECSET_BIT_MOUSE_PROTOCOL_SGR
        case 2004: return DECSET_BIT_BRACKETED_PASTE_MODE
        default: return -1
        }
    }

    public init(output: TerminalOutput, columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int, transcriptRows: Int?, client: TerminalSessionClient?) {
        self.session = output
        let main = TerminalBuffer(client: client, columns: columns, totalRows: TerminalEmulator.getTerminalTranscriptRows(transcriptRows), screenRows: rows)
        self.mainBuffer = main
        self.screen = main
        self.altBuffer = TerminalBuffer(client: client, columns: columns, totalRows: rows, screenRows: rows)
        self.client = client
        self.rows = rows
        self.columns = columns
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
        self.tabStop = [Bool](repeating: false, count: columns)
        reset()
    }

    public func updateTerminalSessionClient(_ client: TerminalSessionClient?) {
        self.client = client
        mainBuffer.updateClient(client)
        altBuffer.updateClient(client)
        setCursorStyle()
        setCursorBlinkState(true)
    }

    public var isAlternateBufferActive: Bool {
        return screen === altBuffer
    }

    private static func getTerminalTranscriptRows(_ transcriptRows: Int?) -> Int {
        guard let transcriptRows = transcriptRows, transcriptRows >= TERMINAL_TRANSCRIPT_ROWS_MIN, transcriptRows <= TERMINAL_TRANSCRIPT_ROWS_MAX else {
            return DEFAULT_TERMINAL_TRANSCRIPT_ROWS
        }
        return transcriptRows
    }

    /// - Parameter mouseButton: one of the MOUSE_* constants of this class.
    public func sendMouseEvent(_ mouseButtonIn: Int, column columnIn: Int, row rowIn: Int, pressed: Bool) {
        var mouseButton = mouseButtonIn
        var column = columnIn
        var row = rowIn
        if column < 1 { column = 1 }
        if column > columns { column = columns }
        if row < 1 { row = 1 }
        if row > rows { row = rows }

        if mouseButton == TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED && !isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT) {
            // Do not send tracking.
        } else if isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_PROTOCOL_SGR) {
            session?.write("\u{1B}[<\(mouseButton);\(column);\(row)" + (pressed ? "M" : "m"))
        } else {
            mouseButton = pressed ? mouseButton : 3 // 3 for release of all buttons.
            // Clip to screen, and clip to the limits of 8-bit data.
            let outOfBounds = column > 255 - 32 || row > 255 - 32
            if !outOfBounds {
                let data: [UInt8] = [27, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(truncatingIfNeeded: 32 + mouseButton),
                                     UInt8(truncatingIfNeeded: 32 + column), UInt8(truncatingIfNeeded: 32 + row)]
                session?.write(data)
            }
        }
    }

    public func resize(columns newColumns: Int, rows newRows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels

        if rows == newRows && columns == newColumns {
            return
        } else if newColumns < 2 || newRows < 2 {
            // Java throws IllegalArgumentException here; ignore invalid sizes instead of crashing the app.
            Logger.logError(client, TerminalEmulator.LOG_TAG, "Invalid resize: rows=\(newRows), columns=\(newColumns)")
            return
        }

        if rows != newRows {
            rows = newRows
            topMargin = 0
            bottomMargin = rows
        }
        if columns != newColumns {
            let oldColumns = columns
            columns = newColumns
            let oldTabStop = tabStop
            tabStop = [Bool](repeating: false, count: columns)
            setDefaultTabStops()
            let toTransfer = min(oldColumns, newColumns)
            for i in 0..<toTransfer { tabStop[i] = oldTabStop[i] }
            leftMargin = 0
            rightMargin = columns
        }

        resizeScreen()
    }

    private func resizeScreen() {
        var cursor = [cursorCol, cursorRow]
        let newTotalRows = (screen === altBuffer) ? rows : mainBuffer.totalRows
        screen.resize(columns, rows, newTotalRows, &cursor, getStyle(), isAlternateBufferActive)
        cursorCol = cursor[0]
        cursorRow = cursor[1]
    }

    /// Set the terminal cursor style from the client.
    public func setCursorStyle() {
        let cursorStyle = client?.terminalCursorStyle
        if let cursorStyle = cursorStyle, TerminalEmulator.TERMINAL_CURSOR_STYLES_LIST.contains(cursorStyle) {
            self.cursorStyle = cursorStyle
        } else {
            self.cursorStyle = TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE
        }
    }

    public var isReverseVideo: Bool {
        return isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_REVERSE_VIDEO)
    }

    public var isCursorEnabled: Bool {
        return isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_CURSOR_ENABLED)
    }

    public var shouldCursorBeVisible: Bool {
        if !isCursorEnabled {
            return false
        } else {
            return cursorBlinkingEnabled ? cursorBlinkState : true
        }
    }

    public func setCursorBlinkingEnabled(_ enabled: Bool) {
        cursorBlinkingEnabled = enabled
    }

    public func setCursorBlinkState(_ state: Bool) {
        cursorBlinkState = state
    }

    public var isKeypadApplicationMode: Bool {
        return isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_APPLICATION_KEYPAD)
    }

    public var isCursorKeysApplicationMode: Bool {
        return isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_APPLICATION_CURSOR_KEYS)
    }

    /// If mouse events are being sent as escape codes to the terminal.
    public var isMouseTrackingActive: Bool {
        return isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE) || isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT)
    }

    private func setDefaultTabStops() {
        for i in 0..<columns {
            tabStop[i] = (i & 7) == 0 && i != 0
        }
    }

    /// Accept bytes (typically from the pseudo-teletype) and process them.
    ///
    /// - Parameters:
    ///   - buffer: a byte array containing the bytes to be processed
    ///   - length: the number of bytes in the array to process
    public func append(_ buffer: [UInt8], length: Int) {
        let count = min(length, buffer.count)
        for i in 0..<count {
            processByte(buffer[i])
        }
    }

    /// Convenience: process all bytes of the buffer.
    public func append(_ buffer: [UInt8]) {
        append(buffer, length: buffer.count)
    }

    private func processByte(_ byteToProcess: UInt8) {
        if utf8ToFollow > 0 {
            if (byteToProcess & 0b11000000) == 0b10000000 {
                // 10xxxxxx, a continuation byte.
                utf8InputBuffer[utf8Index] = byteToProcess
                utf8Index += 1
                utf8ToFollow -= 1
                if utf8ToFollow == 0 {
                    let firstByteMask: UInt8 = (utf8Index == 2 ? 0b00011111 : (utf8Index == 3 ? 0b00001111 : 0b00000111))
                    var codePoint = Int(utf8InputBuffer[0] & firstByteMask)
                    for i in 1..<utf8Index {
                        codePoint = ((codePoint << 6) | Int(utf8InputBuffer[i] & 0b00111111))
                    }
                    if ((codePoint <= 0b1111111) && utf8Index > 1) || (codePoint < 0b11111111111 && utf8Index > 2)
                        || (codePoint < 0b1111111111111111 && utf8Index > 3) {
                        // Overlong encoding.
                        codePoint = TerminalEmulator.UNICODE_REPLACEMENT_CHAR
                    }

                    utf8Index = 0
                    utf8ToFollow = 0

                    if codePoint >= 0x80 && codePoint <= 0x9F {
                        // Sequence decoded to a C1 control character which we ignore. They are
                        // not used nowadays and increases the risk of messing up the terminal state
                        // on binary input. XTerm does not allow them in utf-8:
                        // "It is not possible to use a C1 control obtained from decoding the
                        // UTF-8 text" - http://invisible-island.net/xterm/ctlseqs/ctlseqs.html
                    } else {
                        if UTF16Util.isUnassignedOrSurrogate(codePoint) {
                            codePoint = TerminalEmulator.UNICODE_REPLACEMENT_CHAR
                        }
                        processCodePoint(codePoint)
                    }
                }
            } else {
                // Not a UTF-8 continuation byte so replace the entire sequence up to now with the replacement char:
                utf8Index = 0
                utf8ToFollow = 0
                emitCodePoint(TerminalEmulator.UNICODE_REPLACEMENT_CHAR)
                // The Unicode Standard Version 6.2 – Core Specification
                // (http://www.unicode.org/versions/Unicode6.2.0/ch03.pdf):
                // "If the converter encounters an ill-formed UTF-8 code unit sequence which starts with a valid first
                // byte, but which does not continue with valid successor bytes (see Table 3-7), it must not consume the
                // successor bytes as part of the ill-formed subsequence
                // whenever those successor bytes themselves constitute part of a well-formed UTF-8 code unit
                // subsequence."
                processByte(byteToProcess)
            }
        } else {
            if (byteToProcess & 0b10000000) == 0 { // The leading bit is not set so it is a 7-bit ASCII character.
                processCodePoint(Int(byteToProcess))
                return
            } else if (byteToProcess & 0b11100000) == 0b11000000 { // 110xxxxx, a two-byte sequence.
                utf8ToFollow = 1
            } else if (byteToProcess & 0b11110000) == 0b11100000 { // 1110xxxx, a three-byte sequence.
                utf8ToFollow = 2
            } else if (byteToProcess & 0b11111000) == 0b11110000 { // 11110xxx, a four-byte sequence.
                utf8ToFollow = 3
            } else {
                // Not a valid UTF-8 sequence start, signal invalid data:
                processCodePoint(TerminalEmulator.UNICODE_REPLACEMENT_CHAR)
                return
            }
            utf8InputBuffer[utf8Index] = byteToProcess
            utf8Index += 1
        }
    }

    public func processCodePoint(_ b: Int) {
        screen.doTerminalBitmapsGC(300000)

        if escapeState == TerminalEmulator.ESC_OSC && isFastPathOsc {
            continueSequenceFlag = false
            receiveOsc(b)
            if !continueSequenceFlag { escapeState = TerminalEmulator.ESC_NONE }
            return
        }

        if escapeState == TerminalEmulator.ESC_DCS && isFastPathDcs {
            if b == 27 { // ESC
                ESC_DCS__ESC = true
                return
            }
            continueSequenceFlag = false
            doDcs(b)
            if !continueSequenceFlag { escapeState = TerminalEmulator.ESC_NONE }
            return
        }

        // The Application Program-Control (APC) string might be arbitrary non-printable characters, so handle that early.
        if escapeState == TerminalEmulator.ESC_APC {
            continueSequenceFlag = false
            receiveApc(b)
            if !continueSequenceFlag { escapeState = TerminalEmulator.ESC_NONE }
            return
        } else if escapeState == TerminalEmulator.ESC_APC__ESC {
            continueSequenceFlag = false
            receiveApcEsc(b)
            if !continueSequenceFlag { escapeState = TerminalEmulator.ESC_NONE }
            return
        }

        switch b {
        case 0: // Null character (NUL, ^@). Do nothing.
            break
        case 7: // Bell (BEL, ^G, \a). If in an OSC sequence, BEL may terminate a string; otherwise signal bell.
            if escapeState == TerminalEmulator.ESC_OSC {
                receiveOsc(b)
            } else {
                session?.onBell()
            }
        case 8: // Backspace (BS, ^H).
            if leftMargin == cursorCol {
                // Jump to previous line if it was auto-wrapped.
                let previousRow = cursorRow - 1
                if previousRow >= 0 && screen.getLineWrap(previousRow) {
                    screen.clearLineWrap(previousRow)
                    setCursorRowCol(previousRow, rightMargin - 1)
                }
            } else {
                setCursorCol(cursorCol - 1)
            }
        case 9: // Horizontal tab (HT, \t) - move to next tab stop, but not past edge of screen
            cursorCol = nextTabStop(1)
        case 10, 11, 12: // Line feed (LF, \n), Vertical tab (VT, \v), Form feed (FF, \f).
            // Ignore CR/LF inside DCS by default (including sixel) or OSC if requested (like for iTerm).
            if !(escapeState == TerminalEmulator.ESC_DCS ||
                 ((escapeState == TerminalEmulator.ESC_OSC || escapeState == TerminalEmulator.ESC_OSC__ESC) && ignoreCrLfForOsc)) {
                doLinefeed()
            }
        case 13: // Carriage return (CR, \r).
            if !(escapeState == TerminalEmulator.ESC_DCS ||
                 ((escapeState == TerminalEmulator.ESC_OSC || escapeState == TerminalEmulator.ESC_OSC__ESC) && ignoreCrLfForOsc)) {
                setCursorCol(leftMargin)
            }
        case 14: // Shift Out (Ctrl-N, SO) → Switch to Alternate Character Set. This invokes the G1 character set.
            useLineDrawingUsesG0 = false
        case 15: // Shift In (Ctrl-O, SI) → Switch to Standard Character Set. This invokes the G0 character set.
            useLineDrawingUsesG0 = true
        case 24, 26: // CAN, SUB.
            if escapeState != TerminalEmulator.ESC_NONE {
                // FIXME: What is this??
                escapeState = TerminalEmulator.ESC_NONE
                emitCodePoint(127)
            }
        case 27: // ESC
            // Starts an escape sequence unless we're parsing a string
            if escapeState == TerminalEmulator.ESC_DCS {
                // XXX: Ignore escape when reading device control sequence, since it may be part of string terminator.
                ESC_DCS__ESC = true
                return
            } else if escapeState != TerminalEmulator.ESC_OSC {
                startEscapeSequence()
            } else {
                receiveOsc(b)
            }
        default:
            continueSequenceFlag = false
            switch escapeState {
            case TerminalEmulator.ESC_NONE:
                if b >= 32 { emitCodePoint(b) }
            case TerminalEmulator.ESC:
                doEsc(b)
            case TerminalEmulator.ESC_POUND:
                doEscPound(b)
            case TerminalEmulator.ESC_SELECT_LEFT_PAREN: // Designate G0 Character Set (ISO 2022, VT100).
                useLineDrawingG0 = (b == ch("0"))
            case TerminalEmulator.ESC_SELECT_RIGHT_PAREN: // Designate G1 Character Set (ISO 2022, VT100).
                useLineDrawingG1 = (b == ch("0"))
            case TerminalEmulator.ESC_CSI:
                doCsi(b)
            case TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE, TerminalEmulator.ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE:
                doCsiUnsupportedParameterOrIntermediateByte(b)
            case TerminalEmulator.ESC_CSI_EXCLAMATION:
                if b == ch("p") { // Soft terminal reset (DECSTR, http://vt100.net/docs/vt510-rm/DECSTR).
                    reset()
                } else {
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_QUESTIONMARK:
                doCsiQuestionMark(b)
            case TerminalEmulator.ESC_CSI_BIGGERTHAN:
                doCsiBiggerThan(b)
            case TerminalEmulator.ESC_CSI_DOLLAR:
                doCsiDollar(b)
            case TerminalEmulator.ESC_CSI_DOUBLE_QUOTE:
                if b == ch("q") {
                    // http://www.vt100.net/docs/vt510-rm/DECSCA
                    let arg = getArg0(0)
                    if arg == 0 || arg == 2 {
                        // DECSED and DECSEL can erase characters.
                        effect &= ~TextStyle.CHARACTER_ATTRIBUTE_PROTECTED
                    } else if arg == 1 {
                        // DECSED and DECSEL cannot erase characters.
                        effect |= TextStyle.CHARACTER_ATTRIBUTE_PROTECTED
                    } else {
                        unknownSequence(b)
                    }
                } else {
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_SINGLE_QUOTE:
                if b == ch("}") { // Insert Ps Column(s) (default = 1) (DECIC), VT420 and up.
                    let columnsAfterCursor = rightMargin - cursorCol
                    let columnsToInsert = min(getArg0(1), columnsAfterCursor)
                    let columnsToMove = columnsAfterCursor - columnsToInsert
                    screen.blockCopy(cursorCol, 0, columnsToMove, rows, cursorCol + columnsToInsert, 0)
                    blockClear(cursorCol, 0, columnsToInsert, rows)
                } else if b == ch("~") { // Delete Ps Column(s) (default = 1) (DECDC), VT420 and up.
                    let columnsAfterCursor = rightMargin - cursorCol
                    let columnsToDelete = min(getArg0(1), columnsAfterCursor)
                    let columnsToMove = columnsAfterCursor - columnsToDelete
                    screen.blockCopy(cursorCol + columnsToDelete, 0, columnsToMove, rows, cursorCol, 0)
                } else {
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_PERCENT:
                break
            case TerminalEmulator.ESC_OSC:
                receiveOsc(b)
            case TerminalEmulator.ESC_OSC__ESC:
                receiveOscEsc(b)
            case TerminalEmulator.ESC_DCS:
                doDcs(b)
            case TerminalEmulator.ESC_CSI_QUESTIONMARK_ARG_DOLLAR:
                if b == ch("p") {
                    // Request DEC private mode (DECRQM).
                    let mode = getArg0(0)
                    let value: Int
                    if mode == 47 || mode == 1047 || mode == 1049 {
                        // This state is carried by screen pointer.
                        value = (screen === altBuffer) ? 1 : 2
                    } else {
                        let internalBit = TerminalEmulator.mapDecSetBitToInternalBit(mode)
                        if internalBit != -1 {
                            value = isDecsetInternalBitSet(internalBit) ? 1 : 2 // 1=set, 2=reset.
                        } else {
                            Logger.logError(client, TerminalEmulator.LOG_TAG, "Got DECRQM for unrecognized private DEC mode=\(mode)")
                            value = 0 // 0=not recognized, 3=permanently set, 4=permanently reset
                        }
                    }
                    session?.write("\u{1B}[?\(mode);\(value)$y")
                } else {
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_ARGS_SPACE:
                let arg = getArg0(0)
                switch b {
                case ch("q"): // "${CSI}${STYLE} q" - set cursor style (http://www.vt100.net/docs/vt510-rm/DECSCUSR).
                    switch arg {
                    case 0, 1, 2: // Blinking block, blinking block, steady block.
                        cursorStyle = TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
                    case 3, 4: // Blinking underline, steady underline.
                        cursorStyle = TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE
                    case 5, 6: // Blinking bar (xterm addition), steady bar (xterm addition).
                        cursorStyle = TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR
                    default:
                        break
                    }
                case ch("t"), ch("u"):
                    // Set margin-bell volume - ignore.
                    break
                default:
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_ARGS_ASTERIX:
                let attributeChangeExtent = getArg0(0)
                if b == ch("x") && (attributeChangeExtent >= 0 && attributeChangeExtent <= 2) {
                    // Select attribute change extent (DECSACE - http://www.vt100.net/docs/vt510-rm/DECSACE).
                    setDecsetinternalBit(TerminalEmulator.DECSET_BIT_RECTANGULAR_CHANGEATTRIBUTE, attributeChangeExtent == 2)
                } else {
                    unknownSequence(b)
                }
            default:
                unknownSequence(b)
            }
            if !continueSequenceFlag { escapeState = TerminalEmulator.ESC_NONE }
        }
    }

    /// Process byte while in the `ESC_CSI_DOLLAR` escape state.
    private func doCsiDollar(_ b: Int) {
        let originMode = isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_ORIGIN_MODE)
        let effectiveTopMargin = originMode ? topMargin : 0
        let effectiveBottomMargin = originMode ? bottomMargin : rows
        let effectiveLeftMargin = originMode ? leftMargin : 0
        let effectiveRightMargin = originMode ? rightMargin : columns
        switch b {
        case ch("v"): // ${CSI}${SRC_TOP}${SRC_LEFT}${SRC_BOTTOM}${SRC_RIGHT}${SRC_PAGE}${DST_TOP}${DST_LEFT}${DST_PAGE}$v"
            // Copy rectangular area (DECCRA - http://vt100.net/docs/vt510-rm/DECCRA):
            // "If Pbs is greater than Pts, or Pls is greater than Prs, the terminal ignores DECCRA.
            // The coordinates of the rectangular area are affected by the setting of origin mode (DECOM).
            // DECCRA is not affected by the page margins.
            // The copied text takes on the line attributes of the destination area.
            // If the value of Pt, Pl, Pb, or Pr exceeds the width or height of the active page, then the value
            // is treated as the width or height of that page.
            // If the destination area is partially off the page, then DECCRA clips the off-page data.
            // DECCRA does not change the active cursor position."
            let topSource = min(getArg(0, 1, true) - 1 + effectiveTopMargin, rows)
            let leftSource = min(getArg(1, 1, true) - 1 + effectiveLeftMargin, columns)
            // Inclusive, so do not subtract one:
            let bottomSource = min(max(getArg(2, rows, true) + effectiveTopMargin, topSource), rows)
            let rightSource = min(max(getArg(3, columns, true) + effectiveLeftMargin, leftSource), columns)
            // int sourcePage = getArg(4, 1, true);
            let destionationTop = min(getArg(5, 1, true) - 1 + effectiveTopMargin, rows)
            let destinationLeft = min(getArg(6, 1, true) - 1 + effectiveLeftMargin, columns)
            // int destinationPage = getArg(7, 1, true);
            let heightToCopy = min(rows - destionationTop, bottomSource - topSource)
            let widthToCopy = min(columns - destinationLeft, rightSource - leftSource)
            screen.blockCopy(leftSource, topSource, widthToCopy, heightToCopy, destinationLeft, destionationTop)
        case ch("{"), ch("x"), ch("z"):
            // '{': ${CSI}${TOP}${LEFT}${BOTTOM}${RIGHT}${"
            //      Selective erase rectangular area (DECSERA - http://www.vt100.net/docs/vt510-rm/DECSERA).
            // 'x': ${CSI}${CHAR};${TOP}${LEFT}${BOTTOM}${RIGHT}$x"
            //      Fill rectangular area (DECFRA - http://www.vt100.net/docs/vt510-rm/DECFRA).
            // 'z': ${CSI}$${TOP}${LEFT}${BOTTOM}${RIGHT}$z"
            //      Erase rectangular area (DECERA - http://www.vt100.net/docs/vt510-rm/DECERA).
            let erase = b != ch("x")
            let selective = b == ch("{")
            // Only DECSERA keeps visual attributes, DECERA does not:
            let keepVisualAttributes = erase && selective
            var argIndex = 0
            let fillChar: Int
            if erase {
                fillChar = 32
            } else {
                fillChar = getArg(argIndex, -1, true)
                argIndex += 1
            }
            // "Pch can be any value from 32 to 126 or from 160 to 255. If Pch is not in this range, then the
            // terminal ignores the DECFRA command":
            if (fillChar >= 32 && fillChar <= 126) || (fillChar >= 160 && fillChar <= 255) {
                // "If the value of Pt, Pl, Pb, or Pr exceeds the width or height of the active page, the value
                // is treated as the width or height of that page."
                let top = min(getArg(argIndex, 1, true) + effectiveTopMargin, effectiveBottomMargin + 1)
                argIndex += 1
                let left = min(getArg(argIndex, 1, true) + effectiveLeftMargin, effectiveRightMargin + 1)
                argIndex += 1
                let bottom = min(getArg(argIndex, rows, true) + effectiveTopMargin, effectiveBottomMargin)
                argIndex += 1
                let right = min(getArg(argIndex, columns, true) + effectiveLeftMargin, effectiveRightMargin)
                let style = getStyle()
                var row = top - 1
                while row < bottom {
                    var col = left - 1
                    while col < right {
                        if !selective || (TextStyle.decodeEffect(screen.getStyleAt(externalRow: row, column: col)) & TextStyle.CHARACTER_ATTRIBUTE_PROTECTED) == 0 {
                            screen.setChar(col, row, fillChar, keepVisualAttributes ? screen.getStyleAt(externalRow: row, column: col) : style)
                        }
                        col += 1
                    }
                    row += 1
                }
            }
        case ch("r"), ch("t"):
            // 'r': "${CSI}${TOP}${LEFT}${BOTTOM}${RIGHT}${ATTRIBUTES}$r"
            //      Change attributes in rectangular area (DECCARA - http://vt100.net/docs/vt510-rm/DECCARA).
            // 't': "${CSI}${TOP}${LEFT}${BOTTOM}${RIGHT}${ATTRIBUTES}$t"
            //      Reverse attributes in rectangular area (DECRARA - http://www.vt100.net/docs/vt510-rm/DECRARA).
            let reverse = b == ch("t")
            // FIXME: "coordinates of the rectangular area are affected by the setting of origin mode (DECOM)".
            let top = min(getArg(0, 1, true) - 1, effectiveBottomMargin) + effectiveTopMargin
            let left = min(getArg(1, 1, true) - 1, effectiveRightMargin) + effectiveLeftMargin
            let bottom = min(getArg(2, rows, true) + 1, effectiveBottomMargin - 1) + effectiveTopMargin
            let right = min(getArg(3, columns, true) + 1, effectiveRightMargin - 1) + effectiveLeftMargin
            if argIndex >= 4 {
                if argIndex >= args.count { argIndex = args.count - 1 }
                for i in 4...argIndex {
                    var bits = 0
                    var setOrClear = true // True if setting, false if clearing.
                    switch getArg(i, 0, false) {
                    case 0: // Attributes off (no bold, no underline, no blink, positive image).
                        bits = (TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE | TextStyle.CHARACTER_ATTRIBUTE_BLINK
                            | TextStyle.CHARACTER_ATTRIBUTE_INVERSE)
                        if !reverse { setOrClear = false }
                    case 1: // Bold.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BOLD
                    case 4: // Underline.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                    case 5: // Blink.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BLINK
                    case 7: // Negative image.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_INVERSE
                    case 22: // No bold.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BOLD
                        setOrClear = false
                    case 24: // No underline.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                        setOrClear = false
                    case 25: // No blink.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BLINK
                        setOrClear = false
                    case 27: // Positive image.
                        bits = TextStyle.CHARACTER_ATTRIBUTE_INVERSE
                        setOrClear = false
                    default:
                        break
                    }
                    if reverse && !setOrClear {
                        // Reverse attributes in rectangular area ignores non-(1,4,5,7) bits.
                    } else {
                        screen.setOrClearEffect(bits, setOrClear, reverse, isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_RECTANGULAR_CHANGEATTRIBUTE),
                                                effectiveLeftMargin, effectiveRightMargin, top, left, bottom, right)
                    }
                }
            } else {
                // Do nothing.
            }
        default:
            unknownSequence(b)
        }
    }

    // MARK: - DCS

    /// Do `ESC_DCS`.
    private func doDcs(_ b: Int) {
        if
            // End of DCS if string terminator ST `ESC \` received.
            (ESC_DCS__ESC && b == ch("\\")) ||
            // If sixel continuation after sixel start and a
            // Color Introducer `#`, Graphics Repeat Introducer `!` or Raster Attributes `"`
            // command is received, then process any previous commands, or if end of input
            // with a ST received.
            (ESC_DCS__SIXEL && ((b == ch("#") || b == ch("!") || b == ch("\"")) &&
                ((terminalControlArgs.count >= (terminalControlArgsMaxLength / 2)) || (terminalControlArgs.count > 1 && sixelCommandPartNum == 1)))) {
            let dcs = terminalControlArgs

            // Request Selection or Setting (DECRQSS) `DCS $ q P t ST`.
            // - https://vt100.net/docs/vt510-rm/DECRQSS.html
            if dcs.starts(with: [UInt16(ch("$")), UInt16(ch("q"))]) {
                if UTF16Util.string(dcs) == "$q\"p" {
                    // DECSCL, conformance level, http://www.vt100.net/docs/vt510-rm/DECSCL:
                    let csiString = "64;1\"p"
                    session?.write("\u{1B}P1$r" + csiString + "\u{1B}\\")
                } else {
                    finishSequenceAndLogError("Unrecognized DECRQSS string: '\(UTF16Util.string(dcs))'")
                }
            } else if dcs.starts(with: [UInt16(ch("+")), UInt16(ch("q"))]) {
                // Request Termcap/Terminfo String. The string following the "q" is a list of names encoded in
                // hexadecimal (2 digits per character) separated by ; which correspond to termcap or terminfo key
                // names.
                // Two special features are also recognized, which are not key names: Co for termcap colors (or colors
                // for terminfo colors), and TN for termcap name (or name for terminfo name).
                // xterm responds with DCS 1 + r P t ST for valid requests, adding to P t an = , and the value of the
                // corresponding string that xterm would send, or DCS 0 + r P t ST for invalid requests. The strings are
                // encoded in hexadecimal (2 digits per character).
                // Example: Request for ku is "ESC P + q 6 b 7 5 ESC \", where 6b7d=ku in hexadecimal.
                // Xterm response in normal cursor mode:
                // "<27> P 1 + r 6 b 7 5 = 1 B 5 B 4 1" where 0x1B 0x5B 0x41 = 27 91 65 = ESC [ A
                let partsString = UTF16Util.string(dcs[2...])
                for partSub in TerminalEmulator.javaSplit(partsString, separator: ";") {
                    let part = Array(partSub.utf16)
                    if part.count % 2 == 0 {
                        var transBuffer = [UInt16]()
                        var i = 0
                        while i < part.count {
                            defer { i += 2 }
                            let hex = UTF16Util.string(part[i..<(i + 2)])
                            guard let value = Int(hex, radix: 16), !hex.hasPrefix("+"), !hex.hasPrefix("-") else {
                                Logger.logError(client, TerminalEmulator.LOG_TAG, "Invalid device termcap/terminfo encoded name \"\(partSub)\"")
                                continue
                            }
                            transBuffer.append(UInt16(truncatingIfNeeded: value))
                        }

                        let trans = UTF16Util.string(transBuffer)
                        let responseValue: String?
                        switch trans {
                        case "Co", "colors":
                            responseValue = "256" // Number of colors.
                        case "TN", "name":
                            responseValue = "xterm"
                        default:
                            responseValue = KeyHandler.getCodeFromTermcap(trans, cursorKeysApplication: isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_APPLICATION_CURSOR_KEYS),
                                                                          keypadApplication: isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_APPLICATION_KEYPAD))
                        }
                        if let responseValue = responseValue {
                            var hexEncoded = ""
                            for unit in responseValue.utf16 {
                                hexEncoded += TerminalEmulator.hex(Int(unit), width: 2, uppercase: true)
                            }
                            session?.write("\u{1B}P1+r" + partSub + "=" + hexEncoded + "\u{1B}\\")
                        } else {
                            switch trans {
                            case "%1", "&8": // Help key - ignore, Undo key - ignore.
                                break
                            default:
                                Logger.logWarn(client, TerminalEmulator.LOG_TAG, "Unhandled termcap/terminfo name: '\(trans)'")
                            }
                            // Respond with invalid request:
                            session?.write("\u{1B}P0+r" + partSub + "\u{1B}\\")
                        }
                    } else {
                        Logger.logError(client, TerminalEmulator.LOG_TAG, "Invalid device termcap/terminfo name of odd length: \(partSub)")
                    }
                }
            }
            // If `s..s` or `ST` received from Sixel Device Control String `DCS q s..s ST` or `DCS P1; P2; P3; q s..s ST` command.
            else if ESC_DCS__SIXEL {
                sixelCommandPartNum += 1

                let isValidDcs = processSixelDcs(dcs)

                if !isValidDcs {
                    clearTerminalControlArgs()
                    clearDcsTypeVariables()
                    finishSequence()
                    return
                }

                if ESC_DCS__ESC && b == ch("\\") {
                    var n = screen.sixelEnd(cursorCol, cursorRow, cellWidthPixels, cellHeightPixels)
                    while n > 0 {
                        doLinefeed()
                        n -= 1
                    }
                    // Clear DCS args buffer and variables and finish sequence.
                } else {
                    ESC_DCS__ESC = false

                    // Clear DCS args buffer to receive further new input in empty buffer.
                    clearTerminalControlArgs()

                    // If `b` is a Color Introducer `#`, Graphics Repeat Introducer `!` or Raster Attributes `"`
                    // command, then add to buffer and wait for more input as further arguments
                    // need to be received for its command before it can be processed, which is
                    // not until the next command is received.
                    _ = collectTerminalControlArgs(b)
                    return
                }
            } else {
                if TerminalEmulator.LOG_ESCAPE_SEQUENCES {
                    Logger.logError(client, TerminalEmulator.LOG_TAG, "Unrecognized device control string: \(UTF16Util.string(dcs))")
                }
            }

            // Clear DCS args buffer and variables and finish sequence.
            clearTerminalControlArgs()
            clearDcsTypeVariables()
            finishSequence()
        } else {
            ESC_DCS__ESC = false

            if !collectTerminalControlArgs(b) { return }

            if ESC_DCS__CHECK_IF_SIXEL && !ESC_DCS__SIXEL {
                // Check if `DCS q` or `DCS P1; P2; P3; q` received from Sixel
                // Device Control String `DCS q s..s ST` or `DCS P1; P2; P3; q s..s ST` command.
                // If received, then wait for more input after `q`.
                if b == ch("q") {
                    startIfSixelDcs()
                } else if b == ch(";") || (b >= ch("0") && b <= ch("9")) {
                    // Ignore.
                } else {
                    ESC_DCS__CHECK_IF_SIXEL = false
                }
            }
        }
    }

    public func clearDcsTypeVariables() {
        ESC_DCS__ESC = false
        isFastPathDcs = false

        ESC_DCS__SIXEL = false
        ESC_DCS__CHECK_IF_SIXEL = true
        sixelCommandPartNum = 0
        screen.sixelClear()
    }

    private func startIfSixelDcs() {
        if getSixelDcsSetupArgs(terminalControlArgs, 0) != nil {
            isFastPathDcs = true
            ESC_DCS__SIXEL = true
            ESC_DCS__CHECK_IF_SIXEL = false
            sixelCommandPartNum = 1

            // The `P1; P2; P3;` arguments are ignored as they are not supported currently (if ever).
            screen.sixelStart(100, 100)
            clearTerminalControlArgs()
        }
    }

    private func getSixelDcsSetupArgs(_ dcs: [UInt16], _ indexIn: Int) -> [Int]? {
        var index = indexIn
        var args = [/* `P1=0`/`2:1` */ 0, /* `P2=0` */ 0, /* `P3=0` */ 0]

        if index < dcs.count && Int(dcs[index]) == ch("q") { return args }

        var arg = 0
        var incArg = false
        while index < dcs.count {
            let c = Int(dcs[index])
            if c >= ch("0") && c <= ch("9") {
                if incArg { arg += 1; incArg = false }
                if arg > 2 { break }
                args[arg] = args[arg] &* 10 &+ (c - ch("0"))
                if args[arg] < 0 || args[arg] > Int(Int32.max) { // Overflow.
                    break
                }
                index += 1
            } else if c == ch(";") {
                index += 1

                if arg == 2 {
                    if index < dcs.count {
                        if Int(dcs[index]) == ch("q") {
                            return args
                        } else {
                            // Must be some other command, so no need to check again.
                            ESC_DCS__CHECK_IF_SIXEL = false
                        }
                    }
                    break
                }

                incArg = true
            } else if c == ch("q") {
                // If optional parameters `P1`, `P2` or `P3` are not all passed, or
                // a parameter did not end with a `;`, but is followed by `q`.
                return args
            } else {
                break
            }
        }

        return nil
    }

    /// Parse sixel data. Since sixel images are not rendered on iOS the `screen.sixel*()` calls are no-ops, but
    /// the data is validated the same way as on Android.
    private func processSixelDcs(_ dcs: [UInt16]) -> Bool {
        var index = 0
        var repeatCount = 1
        var isValidDcs = true
        let maxValue = Int(Int32.max)

        func parseNumberedArgs(_ name: String) -> (args: [Int], argIndex: Int)? {
            var args = [0, 0, 0, 0]
            var arg = 0
            var incArg = false
            while index < dcs.count {
                let c = Int(dcs[index])
                if c >= ch("0") && c <= ch("9") {
                    if incArg { arg += 1; incArg = false }
                    args[arg] = args[arg] &* 10 &+ (c - ch("0"))
                    if args[arg] > maxValue { // Overflow.
                        Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel \(name) command value overflow at index \(index)")
                        return nil
                    }
                } else if c == ch(";") {
                    if arg == 3 { // Last arg must not end with a ';'.
                        Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel \(name) command last value must not end with a semicolon ';' at index \(index)")
                        return nil
                    }
                    incArg = true
                } else {
                    break
                }
                index += 1
            }
            return (args, arg)
        }

        while index < dcs.count {
            let c = Int(dcs[index])

            if
                // Sixel data characters in the range of `?` (0x3F) to `~` (0x7E).
                (c >= ch("?") && c <= ch("~"))
                // Graphics Carriage Return `$`.
                || c == ch("$")
                // Graphics New Line `-`.
                || c == ch("-") {
                screen.sixelReadData(c, repeatCount)
                index += 1
                repeatCount = 1
            }
            // Color Introducer `#`
            else if c == ch("#") {
                index += 1 // Consume '#'.

                var color = 0
                while index < dcs.count {
                    let d = Int(dcs[index])
                    if d >= ch("0") && d <= ch("9") {
                        color = color &* 10 &+ (d - ch("0"))
                        if color > maxValue { // Overflow.
                            Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel color command Pc value overflow at index \(index)")
                            isValidDcs = false
                            break
                        }
                        index += 1
                    } else {
                        break
                    }
                }

                if !isValidDcs { break }

                if color > 255 {
                    Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel color command Pc value \(color) is not between 0-255 at index \(index)")
                    isValidDcs = false
                    break
                }

                // Basic Colors `# Pc`
                if index == dcs.count || Int(dcs[index]) != ch(";") {
                    screen.sixelSetColor(color)
                }
                // HLS or RGB Colors `# Pc; Pu; Px; Py; Pz`
                else {
                    index += 1 // Consume ';'.

                    guard let (args, arg) = parseNumberedArgs("non-basic color") else {
                        isValidDcs = false
                        break
                    }

                    for i in 0..<args.count {
                        if i == 0 { // Pu must equal 1 or 2.
                            if args[i] != 1 && args[i] != 2 {
                                Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel non-basic color command Pu value \(args[i]) is not 1 or 2 at index \(index)")
                                isValidDcs = false
                                break
                            }
                        } else {
                            var limit = 100
                            if args[0] == 1 && i == 1 { limit = 360 }
                            if args[i] < 0 || args[i] > limit {
                                Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel non-basic color command value \(args[i]) is not between 0-\(limit) at index \(index)")
                                isValidDcs = false
                                break
                            }
                        }
                    }

                    if isValidDcs && arg == 3 { // If complete spec is received and is valid.
                        if args[0] == 2 { // Only RGB is supported.
                            screen.sixelSetRGBColor(color, args[1], args[2], args[3])
                        } else if args[0] == 1 { // HLS is not supported.
                            Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel non-basic color command Pu value \(args[0]) is not supported at index \(index)")
                            screen.sixelIgnore()
                            break
                        }
                    } else {
                        if isValidDcs {
                            Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel non-basic color command expected 4 arguments at index \(index)")
                        }
                        isValidDcs = false
                        break
                    }
                }
            }
            // Graphics Repeat Introducer `! Pn character`.
            else if c == ch("!") {
                index += 1 // Consume '!'.

                repeatCount = 0
                while index < dcs.count {
                    let d = Int(dcs[index])
                    if d >= ch("0") && d <= ch("9") {
                        repeatCount = repeatCount &* 10 &+ (d - ch("0"))
                        if repeatCount > maxValue { // Overflow.
                            Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel repeat command Pn value overflow at index \(index)")
                            isValidDcs = false
                            break
                        }
                        index += 1
                    } else {
                        break
                    }
                }

                if !isValidDcs { break }

                if repeatCount > TerminalEmulator.SIXEL__MAX_REPEAT {
                    Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel repeat command Pn value \(repeatCount) is greater than max repeat value \(TerminalEmulator.SIXEL__MAX_REPEAT) at index \(index)")
                    screen.sixelIgnore()
                    break
                }
            }
            // Raster Attributes `" Pan; Pad; Ph; Pv`
            else if c == ch("\"") {
                index += 1 // Consume '"'.

                guard let (args, arg) = parseNumberedArgs("raster") else {
                    isValidDcs = false
                    break
                }

                if arg == 3 { // If complete spec is received and is valid.
                    // Raster pixel aspect ratio is not supported currently.
                    let sixelWidth = args[2] // `Ph`
                    let sixelHeight = args[3] // `Pv`
                    if sixelWidth > 0 && sixelHeight > 0 {
                        screen.sixelResize(sixelWidth, sixelHeight)
                    }
                } else {
                    Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel raster command expected 4 arguments at index \(index)")
                    isValidDcs = false
                    break
                }
            } else if c == ch(" ") || c == ch("\t") || c == ch("\n") || c == 12 || c == ch("\r") {
                index += 1
            } else {
                // Invalid character.
                Logger.logError(client, TerminalEmulator.LOG_TAG, "Invalid character (\(c)) at index \(index) of sixel input")
                isValidDcs = false
                break
            }
        }

        return isValidDcs
    }

    private func nextTabStop(_ numTabsIn: Int) -> Int {
        var numTabs = numTabsIn
        var i = cursorCol + 1
        while i < columns {
            if tabStop[i] {
                numTabs -= 1
                if numTabs == 0 { return min(i, rightMargin) }
            }
            i += 1
        }
        return rightMargin - 1
    }

    /// Process byte while in the `ESC_CSI_UNSUPPORTED_PARAMETER_BYTE` or
    /// `ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE` escape state.
    ///
    /// Parse unsupported parameter, intermediate and final bytes but ignore them.
    ///
    /// > For Control Sequence Introducer, ... the ESC [ is followed by
    /// > - any number (including none) of "parameter bytes" in the range 0x30–0x3F (ASCII 0–9:;<=>?),
    /// > - then by any number of "intermediate bytes" in the range 0x20–0x2F (ASCII space and !"#$%&'()*+,-./),
    /// > - then finally by a single "final byte" in the range 0x40–0x7E (ASCII @A–Z[\]^_`a–z{|}~).
    private func doCsiUnsupportedParameterOrIntermediateByte(_ b: Int) {
        if escapeState == TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE && b >= 0x30 && b <= 0x3F {
            // Supported `0–9:;>?` or unsupported `<=` parameter byte after an
            // initial unsupported parameter byte in `doCsi()`, or a sequential parameter byte.
            continueSequence(TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE)
        } else if b >= 0x20 && b <= 0x2F {
            // Optional intermediate byte `!"#$%&'()*+,-./` after parameter or intermediate byte.
            continueSequence(TerminalEmulator.ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE)
        } else if b >= 0x40 && b <= 0x7E {
            // Final byte `@A–Z[\]^_`a–z{|}~` after parameter or intermediate byte.
            // Calling `unknownSequence()` would log an error with only a final byte, so ignore it for now.
            finishSequence()
        } else {
            unknownSequence(b)
        }
    }

    /// Process byte while in the `ESC_CSI_QUESTIONMARK` escape state.
    private func doCsiQuestionMark(_ b: Int) {
        switch b {
        case ch("J"), ch("K"):
            // 'J': Selective erase in display (DECSED) - http://www.vt100.net/docs/vt510-rm/DECSED.
            // 'K': Selective erase in line (DECSEL) - http://vt100.net/docs/vt510-rm/DECSEL.
            aboutToAutoWrap = false
            let fillChar = 32
            var startCol = -1
            var startRow = -1
            var endCol = -1
            var endRow = -1
            let justRow = (b == ch("K"))
            switch getArg0(0) {
            case 0: // Erase from the active position to the end, inclusive (default).
                startCol = cursorCol
                startRow = cursorRow
                endCol = columns
                endRow = justRow ? (cursorRow + 1) : rows
            case 1: // Erase from start to the active position, inclusive.
                startCol = 0
                startRow = justRow ? cursorRow : 0
                endCol = cursorCol + 1
                endRow = cursorRow + 1
            case 2: // Erase all of the display/line.
                startCol = 0
                startRow = justRow ? cursorRow : 0
                endCol = columns
                endRow = justRow ? (cursorRow + 1) : rows
            default:
                unknownSequence(b)
            }
            let style = getStyle()
            var row = startRow
            while row < endRow {
                var col = startCol
                while col < endCol {
                    if (TextStyle.decodeEffect(screen.getStyleAt(externalRow: row, column: col)) & TextStyle.CHARACTER_ATTRIBUTE_PROTECTED) == 0 {
                        screen.setChar(col, row, fillChar, style)
                    }
                    col += 1
                }
                row += 1
            }
        case ch("h"), ch("l"):
            if argIndex >= args.count { argIndex = args.count - 1 }
            for i in 0...argIndex {
                doDecSetOrReset(b == ch("h"), args[i])
            }
        case ch("n"): // Device Status Report (DSR, DEC-specific).
            switch getArg0(-1) {
            case 6:
                // Extended Cursor Position (DECXCPR - http://www.vt100.net/docs/vt510-rm/DECXCPR). Page=1.
                session?.write("\u{1B}[?\(cursorRow + 1);\(cursorCol + 1);1R")
            default:
                finishSequence()
                return
            }
        case ch("r"), ch("s"):
            if argIndex >= args.count { argIndex = args.count - 1 }
            for i in 0...argIndex {
                let externalBit = args[i]
                let internalBit = TerminalEmulator.mapDecSetBitToInternalBit(externalBit)
                if internalBit == -1 {
                    Logger.logWarn(client, TerminalEmulator.LOG_TAG, "Ignoring request to save/recall decset bit=\(externalBit)")
                } else {
                    if b == ch("s") {
                        savedDecSetFlags |= internalBit
                    } else {
                        doDecSetOrReset((savedDecSetFlags & internalBit) != 0, externalBit)
                    }
                }
            }
        case ch("$"):
            continueSequence(TerminalEmulator.ESC_CSI_QUESTIONMARK_ARG_DOLLAR)
            return
        default:
            parseArg(b)
        }
    }

    public func doDecSetOrReset(_ setting: Bool, _ externalBit: Int) {
        let internalBit = TerminalEmulator.mapDecSetBitToInternalBit(externalBit)
        if internalBit != -1 {
            setDecsetinternalBit(internalBit, setting)
        }
        switch externalBit {
        case 1: // Application Cursor Keys (DECCKM).
            break
        case 3: // Set: 132 column mode (. Reset: 80 column mode. ANSI name: DECCOLM.
            // We don't actually set/reset 132 cols, but we do want the side effects
            // (FIXME: Should only do this if the 95 DECSET bit (DECNCSM) is set, and if changing value?):
            // Sets the left, right, top and bottom scrolling margins to their default positions, which is important for
            // the "reset" utility to really reset the terminal:
            leftMargin = 0
            topMargin = 0
            bottomMargin = rows
            rightMargin = columns
            // "DECCOLM resets vertical split screen mode (DECLRMM) to unavailable":
            setDecsetinternalBit(TerminalEmulator.DECSET_BIT_LEFTRIGHT_MARGIN_MODE, false)
            // "Erases all data in page memory":
            blockClear(0, 0, columns, rows)
            setCursorRowCol(0, 0)
        case 4: // DECSCLM-Scrolling Mode. Ignore.
            break
        case 5: // Reverse video. No action.
            break
        case 6: // Set: Origin Mode. Reset: Normal Cursor Mode. Ansi name: DECOM.
            if setting { setCursorPosition(0, 0) }
        case 7, 8, 9, 12, 25:
            // 7: Wrap-around bit, not specific action.
            // 8: Auto-repeat Keys (DECARM). Do not implement.
            // 9: X10 mouse reporting - outdated. Do not implement.
            // 12: Control cursor blinking - ignore.
            // 25: Hide/show cursor - no action needed, renderer will check with shouldCursorBeVisible().
            // NOTE: Like the Java version (which falls through), the client is notified for all of these.
            client?.onTerminalCursorStateChange(setting)
        case 40, 45, 66:
            // 40: Allow 80 => 132 Mode, ignore.
            // 45: TODO: Reverse wrap-around. Implement???
            // 66: Application keypad (DECNKM).
            break
        case 69: // Left and right margin mode (DECLRMM).
            if !setting {
                leftMargin = 0
                rightMargin = columns
            }
        case 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 1034:
            // 1005: UTF-8 mouse mode, ignore. 1006: SGR Mouse Mode. 1034: Interpret "meta" key, sets eighth bit.
            break
        case 1048: // Set: Save cursor as in DECSC. Reset: Restore cursor as in DECRC.
            if setting {
                saveCursor()
            } else {
                restoreCursor()
            }
        case 47, 1047, 1049:
            // Set: Save cursor as in DECSC and use Alternate Screen Buffer, clearing it first.
            // Reset: Use Normal Screen Buffer and restore cursor as in DECRC.
            let newScreen = setting ? altBuffer : mainBuffer
            if newScreen !== screen {
                let resized = !(newScreen.columns == columns && newScreen.screenRows == rows)
                if setting { saveCursor() }
                screen = newScreen
                if !setting {
                    let col = savedStateMain.savedCursorCol
                    let row = savedStateMain.savedCursorRow
                    restoreCursor()
                    if resized {
                        // Restore cursor position _not_ clipped to current screen (let resizeScreen() handle that):
                        cursorCol = col
                        cursorRow = row
                    }
                }
                // Check if buffer size needs to be updated:
                if resized { resizeScreen() }
                // Clear new screen if alt buffer:
                if newScreen === altBuffer {
                    newScreen.blockSet(0, 0, columns, rows, 32, getStyle())
                }
            }
        case 2004:
            // Bracketed paste mode - setting bit is enough.
            break
        default:
            unknownParameter(externalBit)
        }
    }

    private func doCsiBiggerThan(_ b: Int) {
        switch b {
        case ch("c"): // "${CSI}>c" or "${CSI}>c". Secondary Device Attributes (DA2).
            // Originally this was used for the terminal to respond with "identification code, firmware version level,
            // and hardware options" (http://vt100.net/docs/vt510-rm/DA2), with the first "41" meaning the VT420
            // terminal type. This is not used anymore, but the second version level field has been changed by xterm
            // to mean it's release number ("patch numbers" listed at http://invisible-island.net/xterm/xterm.log.html),
            // and some applications use it as a feature check:
            // * tmux used to have a "xterm won't reach version 500 for a while so set that as the upper limit" check,
            // and then check "xterm_version > 270" if rectangular area operations such as DECCRA could be used.
            // * vim checks xterm version number >140 for "Request termcap/terminfo string" functionality >276 for SGR
            // mouse report.
            // The third number is a keyboard identifier not used nowadays.
            session?.write("\u{1B}[>41;320;0c")
        case ch("m"):
            // https://bugs.launchpad.net/gnome-terminal/+bug/96676/comments/25
            // Depending on the first number parameter, this can set one of the xterm resources
            // modifyKeyboard, modifyCursorKeys, modifyFunctionKeys and modifyOtherKeys.
            // http://invisible-island.net/xterm/manpage/xterm.html#RESOURCES
            Logger.logError(client, TerminalEmulator.LOG_TAG, "(ignored) CSI > MODIFY RESOURCE: \(getArg0(-1)) to \(getArg1(-1))")
        default:
            parseArg(b)
        }
    }

    private func startEscapeSequence() {
        escapeState = TerminalEmulator.ESC
        argIndex = 0
        for i in 0..<args.count { args[i] = -1 }
        argsSubParamsBitSet = 0
    }

    private func doLinefeed() {
        let belowScrollingRegion = cursorRow >= bottomMargin
        var newCursorRow = cursorRow + 1
        if belowScrollingRegion {
            // Move down (but not scroll) as long as we are above the last row.
            if cursorRow != rows - 1 {
                setCursorRow(newCursorRow)
            }
        } else {
            if newCursorRow == bottomMargin {
                scrollDownOneLine()
                newCursorRow = bottomMargin - 1
            }
            setCursorRow(newCursorRow)
        }
    }

    private func continueSequence(_ state: Int) {
        escapeState = state
        continueSequenceFlag = true
    }

    private func doEscPound(_ b: Int) {
        switch b {
        case ch("8"): // Esc # 8 - DEC screen alignment test - fill screen with E's.
            screen.blockSet(0, 0, columns, rows, ch("E"), getStyle())
        default:
            unknownSequence(b)
        }
    }

    /// Encountering a character in the `ESC` state.
    private func doEsc(_ b: Int) {
        switch b {
        case ch("#"):
            continueSequence(TerminalEmulator.ESC_POUND)
        case ch("("):
            continueSequence(TerminalEmulator.ESC_SELECT_LEFT_PAREN)
        case ch(")"):
            continueSequence(TerminalEmulator.ESC_SELECT_RIGHT_PAREN)
        case ch("6"): // Back index (http://www.vt100.net/docs/vt510-rm/DECBI). Move left, insert blank column if start.
            if cursorCol > leftMargin {
                cursorCol -= 1
            } else {
                let rows = bottomMargin - topMargin
                screen.blockCopy(leftMargin, topMargin, rightMargin - leftMargin - 1, rows, leftMargin + 1, topMargin)
                screen.blockSet(leftMargin, topMargin, 1, rows, 32, TextStyle.encode(foreColor: foreColor, backColor: backColor, effect: 0))
            }
        case ch("7"): // DECSC save cursor - http://www.vt100.net/docs/vt510-rm/DECSC
            saveCursor()
        case ch("8"): // DECRC restore cursor - http://www.vt100.net/docs/vt510-rm/DECRC
            restoreCursor()
        case ch("9"): // Forward Index (http://www.vt100.net/docs/vt510-rm/DECFI). Move right, insert blank column if end.
            if cursorCol < rightMargin - 1 {
                cursorCol += 1
            } else {
                let rows = bottomMargin - topMargin
                screen.blockCopy(leftMargin + 1, topMargin, rightMargin - leftMargin - 1, rows, leftMargin, topMargin)
                screen.blockSet(rightMargin - 1, topMargin, 1, rows, 32, TextStyle.encode(foreColor: foreColor, backColor: backColor, effect: 0))
            }
        case ch("c"): // RIS - Reset to Initial State (http://vt100.net/docs/vt510-rm/RIS).
            reset()
            mainBuffer.clearTranscript()
            blockClear(0, 0, columns, rows)
            setCursorPosition(0, 0)
        case ch("D"): // INDEX
            doLinefeed()
        case ch("E"): // Next line (http://www.vt100.net/docs/vt510-rm/NEL).
            setCursorCol(isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_ORIGIN_MODE) ? leftMargin : 0)
            doLinefeed()
        case ch("F"): // Cursor to lower-left corner of screen
            setCursorRowCol(0, bottomMargin - 1)
        case ch("H"): // Tab set
            tabStop[cursorCol] = true
        case ch("M"): // "${ESC}M" - reverse index (RI).
            // http://www.vt100.net/docs/vt100-ug/chapter3.html: "Move the active position to the same horizontal
            // position on the preceding line. If the active position is at the top margin, a scroll down is performed".
            if cursorRow <= topMargin {
                screen.blockCopy(leftMargin, topMargin, rightMargin - leftMargin, bottomMargin - (topMargin + 1), leftMargin, topMargin + 1)
                blockClear(leftMargin, topMargin, rightMargin - leftMargin)
            } else {
                cursorRow -= 1
            }
        case ch("N"), ch("0"): // SS2, ignore. SS3, ignore.
            break
        case ch("P"): // Device control string
            clearTerminalControlArgs()
            clearDcsTypeVariables()
            continueSequence(TerminalEmulator.ESC_DCS)
        case ch("["):
            continueSequence(TerminalEmulator.ESC_CSI)
        case ch("="): // DECKPAM
            setDecsetinternalBit(TerminalEmulator.DECSET_BIT_APPLICATION_KEYPAD, true)
        case ch("]"): // OSC
            clearTerminalControlArgs()
            clearOscTypeVariables()
            continueSequence(TerminalEmulator.ESC_OSC)
        case ch(">"): // DECKPNM
            setDecsetinternalBit(TerminalEmulator.DECSET_BIT_APPLICATION_KEYPAD, false)
        case ch("_"): // APC - Application Program Command.
            clearTerminalControlArgs()
            continueSequence(TerminalEmulator.ESC_APC)
        default:
            unknownSequence(b)
        }
    }

    /// DECSC save cursor - http://www.vt100.net/docs/vt510-rm/DECSC . See `restoreCursor()`.
    private func saveCursor() {
        let state = (screen === mainBuffer) ? savedStateMain : savedStateAlt
        state.savedCursorRow = cursorRow
        state.savedCursorCol = cursorCol
        state.savedEffect = effect
        state.savedForeColor = foreColor
        state.savedBackColor = backColor
        state.savedDecFlags = currentDecSetFlags
        state.useLineDrawingG0 = useLineDrawingG0
        state.useLineDrawingG1 = useLineDrawingG1
        state.useLineDrawingUsesG0 = useLineDrawingUsesG0
    }

    /// DECRS restore cursor - http://www.vt100.net/docs/vt510-rm/DECRC. See `saveCursor()`.
    private func restoreCursor() {
        let state = (screen === mainBuffer) ? savedStateMain : savedStateAlt
        setCursorRowCol(state.savedCursorRow, state.savedCursorCol)
        effect = state.savedEffect
        foreColor = state.savedForeColor
        backColor = state.savedBackColor
        let mask = (TerminalEmulator.DECSET_BIT_AUTOWRAP | TerminalEmulator.DECSET_BIT_ORIGIN_MODE)
        currentDecSetFlags = (currentDecSetFlags & ~mask) | (state.savedDecFlags & mask)
        useLineDrawingG0 = state.useLineDrawingG0
        useLineDrawingG1 = state.useLineDrawingG1
        useLineDrawingUsesG0 = state.useLineDrawingUsesG0
    }

    /// Following a CSI - Control Sequence Introducer, "\033[". `ESC_CSI`.
    private func doCsi(_ b: Int) {
        switch b {
        case ch("!"):
            continueSequence(TerminalEmulator.ESC_CSI_EXCLAMATION)
        case ch("\""):
            continueSequence(TerminalEmulator.ESC_CSI_DOUBLE_QUOTE)
        case ch("'"):
            continueSequence(TerminalEmulator.ESC_CSI_SINGLE_QUOTE)
        case ch("$"):
            continueSequence(TerminalEmulator.ESC_CSI_DOLLAR)
        case ch("*"):
            continueSequence(TerminalEmulator.ESC_CSI_ARGS_ASTERIX)
        case ch("@"):
            // "CSI{n}@" - Insert ${n} space characters (ICH) - http://www.vt100.net/docs/vt510-rm/ICH.
            aboutToAutoWrap = false
            let columnsAfterCursor = columns - cursorCol
            let spacesToInsert = min(getArg0(1), columnsAfterCursor)
            let charsToMove = columnsAfterCursor - spacesToInsert
            screen.blockCopy(cursorCol, cursorRow, charsToMove, 1, cursorCol + spacesToInsert, cursorRow)
            blockClear(cursorCol, cursorRow, spacesToInsert)
        case ch("A"): // "CSI${n}A" - Cursor up (CUU) ${n} rows.
            setCursorRow(max(0, cursorRow - getArg0(1)))
        case ch("B"): // "CSI${n}B" - Cursor down (CUD) ${n} rows.
            setCursorRow(min(rows - 1, cursorRow + getArg0(1)))
        case ch("C"), ch("a"):
            // "CSI${n}C" - Cursor forward (CUF).
            // "CSI${n}a" - Horizontal position relative (HPR). From ISO-6428/ECMA-48.
            setCursorCol(min(rightMargin - 1, cursorCol + getArg0(1)))
        case ch("D"): // "CSI${n}D" - Cursor backward (CUB) ${n} columns.
            setCursorCol(max(leftMargin, cursorCol - getArg0(1)))
        case ch("E"): // "CSI{n}E - Cursor Next Line (CNL). From ISO-6428/ECMA-48.
            setCursorPosition(0, cursorRow + getArg0(1))
        case ch("F"): // "CSI{n}F - Cursor Previous Line (CPL). From ISO-6428/ECMA-48.
            setCursorPosition(0, cursorRow - getArg0(1))
        case ch("G"): // "CSI${n}G" - Cursor horizontal absolute (CHA) to column ${n}.
            setCursorCol(min(max(1, getArg0(1)), columns) - 1)
        case ch("H"), ch("f"):
            // "${CSI}${ROW};${COLUMN}H" - Cursor position (CUP).
            // "${CSI}${ROW};${COLUMN}f" - Horizontal and Vertical Position (HVP).
            setCursorPosition(getArg1(1) - 1, getArg0(1) - 1)
        case ch("I"): // Cursor Horizontal Forward Tabulation (CHT). Move the active position n tabs forward.
            setCursorCol(nextTabStop(getArg0(1)))
        case ch("J"): // "${CSI}${0,1,2,3}J" - Erase in Display (ED)
            // ED ignores the scrolling margins.
            switch getArg0(0) {
            case 0: // Erase from the active position to the end of the screen, inclusive (default).
                blockClear(cursorCol, cursorRow, columns - cursorCol)
                blockClear(0, cursorRow + 1, columns, rows - (cursorRow + 1))
            case 1: // Erase from start of the screen to the active position, inclusive.
                blockClear(0, 0, columns, cursorRow)
                blockClear(0, cursorRow, cursorCol + 1)
            case 2: // Erase all of the display - all lines are erased, changed to single-width, and the cursor does not
                // move..
                blockClear(0, 0, columns, rows)
            case 3: // Delete all lines saved in the scrollback buffer (xterm etc)
                mainBuffer.clearTranscript()
            default:
                unknownSequence(b)
                return
            }
            aboutToAutoWrap = false
        case ch("K"): // "CSI{n}K" - Erase in line (EL).
            switch getArg0(0) {
            case 0: // Erase from the cursor to the end of the line, inclusive (default)
                blockClear(cursorCol, cursorRow, columns - cursorCol)
            case 1: // Erase from the start of the screen to the cursor, inclusive.
                blockClear(0, cursorRow, cursorCol + 1)
            case 2: // Erase all of the line.
                blockClear(0, cursorRow, columns)
            default:
                unknownSequence(b)
                return
            }
            aboutToAutoWrap = false
        case ch("L"): // "${CSI}{N}L" - insert ${N} lines (IL).
            let linesAfterCursor = bottomMargin - cursorRow
            let linesToInsert = min(getArg0(1), linesAfterCursor)
            let linesToMove = linesAfterCursor - linesToInsert
            screen.blockCopy(0, cursorRow, columns, linesToMove, 0, cursorRow + linesToInsert)
            blockClear(0, cursorRow, columns, linesToInsert)
        case ch("M"): // "${CSI}${N}M" - delete N lines (DL).
            aboutToAutoWrap = false
            let linesAfterCursor = bottomMargin - cursorRow
            let linesToDelete = min(getArg0(1), linesAfterCursor)
            let linesToMove = linesAfterCursor - linesToDelete
            screen.blockCopy(0, cursorRow + linesToDelete, columns, linesToMove, 0, cursorRow)
            blockClear(0, cursorRow + linesToMove, columns, linesToDelete)
        case ch("P"): // "${CSI}{N}P" - delete ${N} characters (DCH).
            // http://www.vt100.net/docs/vt510-rm/DCH: "If ${N} is greater than the number of characters between the
            // cursor and the right margin, then DCH only deletes the remaining characters.
            // As characters are deleted, the remaining characters between the cursor and right margin move to the left.
            // Character attributes move with the characters. The terminal adds blank spaces with no visual character
            // attributes at the right margin. DCH has no effect outside the scrolling margins."
            aboutToAutoWrap = false
            let cellsAfterCursor = columns - cursorCol
            let cellsToDelete = min(getArg0(1), cellsAfterCursor)
            let cellsToMove = cellsAfterCursor - cellsToDelete
            screen.blockCopy(cursorCol + cellsToDelete, cursorRow, cellsToMove, 1, cursorCol, cursorRow)
            blockClear(cursorCol + cellsToMove, cursorRow, cellsToDelete)
        case ch("S"): // "${CSI}${N}S" - scroll up ${N} lines (default = 1) (SU).
            let linesToScroll = getArg0(1)
            for _ in 0..<max(0, linesToScroll) {
                scrollDownOneLine()
            }
        case ch("T"):
            if argIndex == 0 {
                // "${CSI}${N}T" - Scroll down N lines (default = 1) (SD).
                // http://vt100.net/docs/vt510-rm/SD: "N is the number of lines to move the user window up in page
                // memory. N new lines appear at the top of the display. N old lines disappear at the bottom of the
                // display. You cannot pan past the top margin of the current page".
                let linesToScrollArg = getArg0(1)
                let linesBetweenTopAndBottomMargins = bottomMargin - topMargin
                let linesToScroll = min(linesBetweenTopAndBottomMargins, linesToScrollArg)
                screen.blockCopy(leftMargin, topMargin, rightMargin - leftMargin, linesBetweenTopAndBottomMargins - linesToScroll, leftMargin, topMargin + linesToScroll)
                blockClear(leftMargin, topMargin, rightMargin - leftMargin, linesToScroll)
            } else {
                // "${CSI}${func};${startx};${starty};${firstrow};${lastrow}T" - initiate highlight mouse tracking.
                unimplementedSequence(b)
            }
        case ch("X"): // "${CSI}${N}X" - Erase ${N:=1} character(s) (ECH). FIXME: Clears character attributes?
            aboutToAutoWrap = false
            screen.blockSet(cursorCol, cursorRow, min(getArg0(1), columns - cursorCol), 1, 32, getStyle())
        case ch("Z"): // Cursor Backward Tabulation (CBT). Move the active position n tabs backward.
            var numberOfTabs = getArg0(1)
            var newCol = leftMargin
            var i = cursorCol - 1
            while i >= 0 {
                if tabStop[i] {
                    numberOfTabs -= 1
                    if numberOfTabs == 0 {
                        newCol = max(i, leftMargin)
                        break
                    }
                }
                i -= 1
            }
            cursorCol = newCol
        case ch("?"): // Esc [ ? -- start of a private parameter byte
            continueSequence(TerminalEmulator.ESC_CSI_QUESTIONMARK)
        case ch(">"): // "Esc [ >" -- start of a private parameter byte
            continueSequence(TerminalEmulator.ESC_CSI_BIGGERTHAN)
        case ch("<"), ch("="): // "Esc [ <" / "Esc [ =" -- start of a private parameter byte
            continueSequence(TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE)
        case ch("`"): // Horizontal position absolute (HPA - http://www.vt100.net/docs/vt510-rm/HPA).
            setCursorColRespectingOriginMode(getArg0(1) - 1)
        case ch("b"): // Repeat the preceding graphic character Ps times (REP).
            if lastEmittedCodePoint == -1 { break }
            let numRepeat = getArg0(1)
            for _ in 0..<max(0, numRepeat) { emitCodePoint(lastEmittedCodePoint) }
        case ch("c"): // Primary Device Attributes (http://www.vt100.net/docs/vt510-rm/DA1) if argument is missing or zero.
            // The important part that may still be used by some (tmux stores this value but does not currently use it)
            // is the first response parameter identifying the terminal service class, where we send 64 for "vt420".
            // This is followed by a list of attributes which is probably unused by applications. Send like xterm.
            if getArg0(0) == 0 { session?.write("\u{1B}[?64;1;2;4;6;9;15;18;21;22c") }
        case ch("d"): // ESC [ Pn d - Vert Position Absolute
            setCursorRow(min(max(1, getArg0(1)), rows) - 1)
        case ch("e"): // Vertical Position Relative (VPR). From ISO-6429 (ECMA-48).
            setCursorPosition(cursorCol, cursorRow + getArg0(1))
        // case 'f': "${CSI}${ROW};${COLUMN}f" - Horizontal and Vertical Position (HVP). Grouped with case 'H'.
        case ch("g"): // Clear tab stop
            switch getArg0(0) {
            case 0:
                tabStop[cursorCol] = false
            case 3:
                for i in 0..<columns {
                    tabStop[i] = false
                }
            default:
                // Specified to have no effect.
                break
            }
        case ch("h"): // Set Mode
            doSetMode(true)
        case ch("l"): // Reset Mode
            doSetMode(false)
        case ch("m"): // Esc [ Pn m - character attributes. (can have up to 16 numerical arguments)
            selectGraphicRendition()
        case ch("n"): // Esc [ Pn n - ECMA-48 Status Report Commands
            switch getArg0(0) {
            case 5: // Device status report (DSR):
                // Answer is ESC [ 0 n (Terminal OK).
                let dsr: [UInt8] = [27, UInt8(ascii: "["), UInt8(ascii: "0"), UInt8(ascii: "n")]
                session?.write(dsr)
            case 6: // Cursor position report (CPR):
                // Answer is ESC [ y ; x R, where x,y is
                // the cursor location.
                session?.write("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R")
            default:
                break
            }
        case ch("r"): // "CSI${top};${bottom}r" - set top and bottom Margins (DECSTBM).
            // https://vt100.net/docs/vt510-rm/DECSTBM.html
            // The top margin defaults to 1, the bottom margin defaults to mRows.
            // The escape sequence numbers top 1..23, but we number top 0..22.
            // The escape sequence numbers bottom 2..24, and so do we (because we use a zero based numbering
            // scheme, but we store the first line below the bottom-most scrolling line.
            // As a result, we adjust the top line by -1, but we leave the bottom line alone.
            // Also require that top + 2 <= bottom.
            topMargin = max(0, min(getArg0(1) - 1, rows - 2))
            bottomMargin = max(topMargin + 2, min(getArg1(rows), rows))

            // DECSTBM moves the cursor to column 1, line 1 of the page respecting origin mode.
            setCursorPosition(0, 0)
        case ch("s"):
            if isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_LEFTRIGHT_MARGIN_MODE) {
                // Set left and right margins (DECSLRM - http://www.vt100.net/docs/vt510-rm/DECSLRM).
                leftMargin = min(getArg0(1) - 1, columns - 2)
                rightMargin = max(leftMargin + 1, min(getArg1(columns), columns))
                // DECSLRM moves the cursor to column 1, line 1 of the page.
                setCursorPosition(0, 0)
            } else {
                // Save cursor (ANSI.SYS), available only when DECLRMM is disabled.
                saveCursor()
            }
        case ch("t"): // Window manipulation (from dtterm, as well as extensions)
            switch getArg0(0) {
            case 11: // Report xterm window state. If the xterm window is open (non-iconified), it returns CSI 1 t .
                session?.write("\u{1B}[1t")
            case 13: // Report xterm window position. Result is CSI 3 ; x ; y t
                session?.write("\u{1B}[3;0;0t")
            case 14: // Report xterm window in pixels. Result is CSI 4 ; height ; width t
                session?.write("\u{1B}[4;\(rows * cellHeightPixels);\(columns * cellWidthPixels)t")
            case 16: // Report xterm character cell size in pixels. Result is CSI 6 ; height ; width t
                session?.write("\u{1B}[6;\(cellHeightPixels);\(cellWidthPixels)t")
            case 18: // Report the size of the text area in characters. Result is CSI 8 ; height ; width t
                session?.write("\u{1B}[8;\(rows);\(columns)t")
            case 19: // Report the size of the screen in characters. Result is CSI 9 ; height ; width t
                // We report the same size as the view, since it's the view really isn't resizable from the shell.
                session?.write("\u{1B}[9;\(rows);\(columns)t")
            case 20: // Report xterm windows icon label. Result is OSC L label ST. Disabled due to security concerns:
                session?.write("\u{1B}]LIconLabel\u{1B}\\")
            case 21: // Report xterm windows title. Result is OSC l label ST. Disabled due to security concerns:
                session?.write("\u{1B}]l\u{1B}\\")
            case 22:
                // 22;0 -> Save xterm icon and window title on stack.
                // 22;1 -> Save xterm icon title on stack.
                // 22;2 -> Save xterm window title on stack.
                titleStack.append(title)
                if titleStack.count > 20 {
                    // Limit size
                    titleStack.remove(at: 0)
                }
            case 23: // Like 22 above but restore from stack.
                if !titleStack.isEmpty { setTitle(titleStack.removeLast()) }
            default:
                // Ignore window manipulation.
                break
            }
        case ch("u"): // Restore cursor (ANSI.SYS).
            restoreCursor()
        case ch(" "):
            continueSequence(TerminalEmulator.ESC_CSI_ARGS_SPACE)
        default:
            parseArg(b)
        }
    }

    /// Select Graphic Rendition (SGR) - see http://en.wikipedia.org/wiki/ANSI_escape_code#graphics.
    private func selectGraphicRendition() {
        if argIndex >= args.count { argIndex = args.count - 1 }
        var i = 0
        while i <= argIndex {
            defer { i += 1 }
            // Skip leading sub parameters:
            if (argsSubParamsBitSet & (1 << i)) != 0 {
                continue
            }

            var code = getArg(i, 0, false)
            if code < 0 {
                if argIndex > 0 {
                    continue
                } else {
                    code = 0
                }
            }
            if code == 0 { // reset
                foreColor = TextStyle.COLOR_INDEX_FOREGROUND
                backColor = TextStyle.COLOR_INDEX_BACKGROUND
                effect = 0
            } else if code == 1 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_BOLD
            } else if code == 2 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_DIM
            } else if code == 3 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_ITALIC
            } else if code == 4 {
                if i + 1 <= argIndex && ((argsSubParamsBitSet & (1 << (i + 1))) != 0) {
                    // Sub parameter, see https://sw.kovidgoyal.net/kitty/underlines/
                    i += 1
                    if args[i] == 0 {
                        // No underline.
                        effect &= ~TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                    } else {
                        // Different variations of underlines: https://sw.kovidgoyal.net/kitty/underlines/
                        effect |= TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                    }
                } else {
                    effect |= TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                }
            } else if code == 5 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_BLINK
            } else if code == 7 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_INVERSE
            } else if code == 8 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE
            } else if code == 9 {
                effect |= TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH
            } else if code == 10 {
                // Exit alt charset (TERM=linux) - ignore.
            } else if code == 11 {
                // Enter alt charset (TERM=linux) - ignore.
            } else if code == 22 { // Normal color or intensity, neither bright, bold nor faint.
                effect &= ~(TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_DIM)
            } else if code == 23 { // not italic, but rarely used as such; clears standout with TERM=screen
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_ITALIC
            } else if code == 24 { // underline: none
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
            } else if code == 25 { // blink: none
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_BLINK
            } else if code == 27 { // image: positive
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_INVERSE
            } else if code == 28 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE
            } else if code == 29 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH
            } else if code >= 30 && code <= 37 {
                foreColor = code - 30
            } else if code == 38 || code == 48 || code == 58 {
                // Extended set foreground(38)/background(48)/underline(58) color.
                // This is followed by either "2;$R;$G;$B" to set a 24-bit color or
                // "5;$INDEX" to set an indexed color.
                if i + 2 > argIndex { continue }
                let firstArg = args[i + 1]
                if firstArg == 2 {
                    if i + 4 > argIndex {
                        Logger.logWarn(client, TerminalEmulator.LOG_TAG, "Too few CSI\(code);2 RGB arguments")
                    } else {
                        let red = getArg(i + 2, 0, false)
                        let green = getArg(i + 3, 0, false)
                        let blue = getArg(i + 4, 0, false)

                        if red < 0 || green < 0 || blue < 0 || red > 255 || green > 255 || blue > 255 {
                            finishSequenceAndLogError("Invalid RGB: \(red),\(green),\(blue)")
                        } else {
                            let argbColor = 0xff_00_00_00 | (red << 16) | (green << 8) | blue
                            switch code {
                            case 38: foreColor = argbColor
                            case 48: backColor = argbColor
                            case 58: underlineColor = argbColor
                            default: break
                            }
                        }
                        i += 4 // "2;P_r;P_g;P_r"
                    }
                } else if firstArg == 5 {
                    let color = getArg(i + 2, 0, false)
                    i += 2 // "5;P_s"
                    if color >= 0 && color < TextStyle.NUM_INDEXED_COLORS {
                        switch code {
                        case 38: foreColor = color
                        case 48: backColor = color
                        case 58: underlineColor = color
                        default: break
                        }
                    } else {
                        if TerminalEmulator.LOG_ESCAPE_SEQUENCES { Logger.logWarn(client, TerminalEmulator.LOG_TAG, "Invalid color index: \(color)") }
                    }
                } else {
                    finishSequenceAndLogError("Invalid ISO-8613-3 SGR first argument: \(firstArg)")
                }
            } else if code == 39 { // Set default foreground color.
                foreColor = TextStyle.COLOR_INDEX_FOREGROUND
            } else if code >= 40 && code <= 47 { // Set background color.
                backColor = code - 40
            } else if code == 49 { // Set default background color.
                backColor = TextStyle.COLOR_INDEX_BACKGROUND
            } else if code == 59 { // Set default underline color.
                underlineColor = TextStyle.COLOR_INDEX_FOREGROUND
            } else if code >= 90 && code <= 97 { // Bright foreground colors (aixterm codes).
                foreColor = code - 90 + 8
            } else if code >= 100 && code <= 107 { // Bright background color (aixterm codes).
                backColor = code - 100 + 8
            } else {
                if TerminalEmulator.LOG_ESCAPE_SEQUENCES {
                    Logger.logWarn(client, TerminalEmulator.LOG_TAG, "SGR unknown code \(code)")
                }
            }
        }
    }

    // MARK: - APC

    /// Receive `ESC_APC`.
    private func receiveApc(_ b: Int) {
        switch b {
        case 27: // Escape.
            continueSequence(TerminalEmulator.ESC_APC__ESC)
        default:
            if !collectTerminalControlArgs(b) { return }
        }
    }

    /// Receive `ESC_APC__ESC`.
    private func receiveApcEsc(_ b: Int) {
        switch b {
        case ch("\\"):
            // doApc(); clearApcTypeVariables(); - APC commands are not supported.
            break
        default:
            // The ESC character was not followed by a \, so insert the ESC and
            // the current character in arg buffer.
            if !collectTerminalControlArgs(27) { return }
            if !collectTerminalControlArgs(b) { return }
            continueSequence(TerminalEmulator.ESC_APC)
        }
    }

    /// Clear `ESC_APC` type variables.
    public func clearApcTypeVariables() {}

    // MARK: - OSC

    /// Receive `ESC_OSC`.
    private func receiveOsc(_ b: Int) {
        switch b {
        case 7: // Bell.
            doOsc("\u{07}")
            clearOscTypeVariables()
        case 27: // Escape.
            continueSequence(TerminalEmulator.ESC_OSC__ESC)
        default:
            if oscType == 1337 && terminalControlArgs.count >= TerminalEmulator.OSC_1337__MAX_KEPT_LENGTH {
                // iTerm image data is not supported, so discard it but keep consuming the sequence.
                continueSequence(escapeState)
                return
            }
            if !collectTerminalControlArgs(b) { return }
            if oscType == -1 {
                setOscTypeVariables()
            }
        }
    }

    /// Receive `ESC_OSC__ESC`.
    private func receiveOscEsc(_ b: Int) {
        switch b {
        case ch("\\"):
            doOsc("\u{1B}\\")
            clearOscTypeVariables()
        default:
            // The ESC character was not followed by a \, so insert the ESC and
            // the current character in arg buffer.
            if oscType == 1337 && terminalControlArgs.count >= TerminalEmulator.OSC_1337__MAX_KEPT_LENGTH {
                continueSequence(TerminalEmulator.ESC_OSC)
                return
            }
            if !collectTerminalControlArgs(27) { return }
            if !collectTerminalControlArgs(b) { return }
            continueSequence(TerminalEmulator.ESC_OSC)
        }
    }

    /// Set `ESC_OSC` type variables.
    func setOscTypeVariables() {
        if oscType >= 0 { return }
        // NOTE: The Java version checks for ":" here (`indexOf(":") < 0`), so the type was only determined once a
        // ':' had been received - which never happens for e.g. `52;c;<base64>` (so the larger OSC 52 limit never
        // applied) or `1337;FilePart=<base64>`. The port determines the type as soon as `$type;` is received.
        if !terminalControlArgs.contains(UInt16(ch(";"))) { return }

        var value = -1

        // Extract initial $value from initial "$value;..." string.
        for c in terminalControlArgs {
            let b = Int(c)
            if b == ch(";") {
                oscType = value
                break
            } else if b >= ch("0") && b <= ch("9") {
                value = ((value < 0) ? 0 : value * 10) + (b - ch("0"))
                if value > 1_000_000 { oscType = -2; return }
            } else {
                oscType = -2 // Unknown sequence.
                return
            }
        }

        if oscType >= 0 {
            switch oscType {
            case 52:
                // Android has a `~100KB` limit for sharing/sending `UTF-16` encoded `String`
                // with binder transactions, including clipboard. Keep the same limit.
                setTerminalControlArgsMaxLength((100 * 1024) + /* `52;Pc;` */ 10)
            case 1337: // iTerm image command sends the base64 encoded image, do not run complex logic for each byte.
                isFastPathOsc = true
                ignoreCrLfForOsc = true
            default:
                break
            }
        }
    }

    /// Clear `ESC_OSC` type variables.
    public func clearOscTypeVariables() {
        oscType = -1
        isFastPathOsc = false
        ignoreCrLfForOsc = false
    }

    /// Do `ESC_OSC`.
    ///
    /// This handles Set Text Parameters commands.
    ///
    /// The `bellOrStringTerminator` defines whether `OSC` command terminated with a `BEL` or `ST`.
    private func doOsc(_ bellOrStringTerminator: String) {
        var value = -1
        var textParameter: [UInt16] = []
        let argsLength = terminalControlArgs.count

        // Extract initial $value from initial "$value;..." string.
        var i = 0
        while i < argsLength {
            let b = Int(terminalControlArgs[i])
            if b == ch(";") {
                // Do not make a copy of `terminalControlArgs` for lengthy commands.
                if value != 1337 {
                    textParameter = Array(terminalControlArgs[(i + 1)...])
                }
                break
            } else if b >= ch("0") && b <= ch("9") {
                value = ((value < 0) ? 0 : value * 10) + (b - ch("0"))
                if value > 1_000_000 { unknownSequence(b); return }
            } else {
                unknownSequence(b)
                return
            }
            i += 1
        }

        let semicolon = UInt16(ch(";"))

        switch value {
        case 0, 1, 2:
            // 0: Change icon name and window title to T.
            // 1: Change icon name to T.
            // 2: Change window title to T.
            setTitle(UTF16Util.string(textParameter))
        case 4:
            // P s = 4 ; c ; spec → Change Color Number c to the color specified by spec. This can be a name or RGB
            // specification as per XParseColor. Any number of c name pairs may be given. The color numbers correspond
            // to the ANSI colors 0-7, their bright versions 8-15, and if supported, the remainder of the 88-color or
            // 256-color table.
            // If a "?" is given rather than a name or RGB specification, xterm replies with a control sequence of the
            // same form which can be used to set the corresponding color. Because more than one pair of color number
            // and specification can be given in one control sequence, xterm can make more than one reply.
            var colorIndex = -1
            var parsingPairStart = -1
            var i = 0
            while true {
                let endOfInput = i == textParameter.count
                let b = endOfInput ? ch(";") : Int(textParameter[i])
                if b == ch(";") {
                    if parsingPairStart < 0 {
                        parsingPairStart = i + 1
                    } else {
                        if colorIndex < 0 || colorIndex > 255 {
                            unknownSequence(b)
                            return
                        } else {
                            colors.tryParseColor(colorIndex, UTF16Util.string(textParameter[parsingPairStart..<i]))
                            session?.onColorsChanged()
                            colorIndex = -1
                            parsingPairStart = -1
                        }
                    }
                } else if parsingPairStart >= 0 {
                    // We have passed a color index and are now going through color spec.
                } else if parsingPairStart < 0 && (b >= ch("0") && b <= ch("9")) {
                    colorIndex = ((colorIndex < 0) ? 0 : colorIndex * 10) + (b - ch("0"))
                    if colorIndex > 1_000_000 { unknownSequence(b); return }
                } else {
                    unknownSequence(b)
                    return
                }
                if endOfInput { break }
                i += 1
            }
        case 10, 11, 12:
            // 10: Set foreground color.
            // 11: Set background color.
            // 12: Set cursor color.
            var specialIndex = TextStyle.COLOR_INDEX_FOREGROUND + (value - 10)
            var lastSemiIndex = 0
            var charIndex = 0
            while true {
                let endOfInput = charIndex == textParameter.count
                if endOfInput || textParameter[charIndex] == semicolon {
                    let colorSpec = UTF16Util.string(textParameter[lastSemiIndex..<charIndex])
                    if colorSpec == "?" {
                        // Report current color in the same format xterm and gnome-terminal does.
                        let rgb = Int(colors.currentColors[specialIndex])
                        let r = (65535 * ((rgb & 0x00FF0000) >> 16)) / 255
                        let g = (65535 * ((rgb & 0x0000FF00) >> 8)) / 255
                        let b = (65535 * ((rgb & 0x000000FF))) / 255
                        session?.write("\u{1B}]\(value);rgb:" + TerminalEmulator.hex(r, width: 4) + "/" + TerminalEmulator.hex(g, width: 4) + "/"
                            + TerminalEmulator.hex(b, width: 4) + bellOrStringTerminator)
                    } else {
                        colors.tryParseColor(specialIndex, colorSpec)
                        session?.onColorsChanged()
                    }
                    specialIndex += 1
                    if endOfInput || (specialIndex > TextStyle.COLOR_INDEX_CURSOR) { break }
                    charIndex += 1
                    if charIndex >= textParameter.count { break }
                    lastSemiIndex = charIndex
                }
                charIndex += 1
            }
        case 52: // Manipulate Selection Data. Skip the optional first selection parameter(s).
            let startIndex = (textParameter.firstIndex(of: semicolon) ?? -1) + 1
            if let decoded = TerminalEmulator.decodeBase64Lenient(Array(textParameter[startIndex...])) {
                let clipboardText = String(decoding: decoded, as: UTF8.self)
                session?.onCopyTextToClipboard(clipboardText)
            } else {
                Logger.logError(client, TerminalEmulator.LOG_TAG, "OSC Manipulate selection, invalid string '\(UTF16Util.string(textParameter))'")
            }
        case 104:
            // "104;$c" → Reset Color Number $c. It is reset to the color specified by the corresponding X
            // resource. Any number of c parameters may be given. These parameters correspond to the ANSI colors 0-7,
            // their bright versions 8-15, and if supported, the remainder of the 88-color or 256-color table. If no
            // parameters are given, the entire table will be reset.
            if textParameter.isEmpty {
                colors.reset()
                session?.onColorsChanged()
            } else {
                var lastIndex = 0
                var charIndex = 0
                while true {
                    let endOfInput = charIndex == textParameter.count
                    if endOfInput || textParameter[charIndex] == semicolon {
                        if let colorToReset = Int(UTF16Util.string(textParameter[lastIndex..<charIndex])),
                           colorToReset >= 0, colorToReset < TextStyle.NUM_INDEXED_COLORS {
                            colors.reset(colorToReset)
                            session?.onColorsChanged()
                            if endOfInput { break }
                            charIndex += 1
                            lastIndex = charIndex
                            continue
                        } else {
                            // Ignore. (Unlike Java, which would loop past the end of the input here.)
                            if endOfInput { break }
                        }
                    }
                    charIndex += 1
                }
            }
        case 110, 111, 112:
            // 110: Reset foreground color.
            // 111: Reset background color.
            // 112: Reset cursor color.
            colors.reset(TextStyle.COLOR_INDEX_FOREGROUND + (value - 110))
            session?.onColorsChanged()
        case 119: // Reset highlight color.
            break
        case 1337: // iTerm image
            // - https://iterm2.com/documentation-images.html
            // - https://iterm2.com/documentation-escape-codes.html
            let prefixEnd = min(19, argsLength)
            let controlCommandPrefix = prefixEnd > 5 ? UTF16Util.string(terminalControlArgs[5..<prefixEnd]) : ""

            if controlCommandPrefix.hasPrefix("File=") ||
                controlCommandPrefix.hasPrefix("MultipartFile=") ||
                controlCommandPrefix.hasPrefix("FilePart=") ||
                controlCommandPrefix == "FileEnd" {
                // Inline images are not supported on iOS (they require decoding PNG/JPEG/GIF into a bitmap).
                // The command has been fully consumed, so just drop it.
                clearTerminalControlArgs()
                break
            } else if controlCommandPrefix.hasPrefix("ReportCellSize") {
                // NOTE: The Java version writes "\0331337;..." (missing the ']' of OSC), which is a bug; the iTerm2
                // documented reply is `OSC 1337 ; ReportCellSize=height;width ST`.
                session?.write("\u{1B}]1337;ReportCellSize=\(cellHeightPixels);\(cellWidthPixels)\u{07}")
            }
            unknownParameter(value)
        default:
            unknownParameter(value)
        }

        finishSequence()
    }

    private func blockClear(_ sx: Int, _ sy: Int, _ w: Int) {
        blockClear(sx, sy, w, 1)
    }

    private func blockClear(_ sx: Int, _ sy: Int, _ w: Int, _ h: Int) {
        screen.blockSet(sx, sy, w, h, 32, getStyle())
    }

    private func getStyle() -> Int64 {
        return TextStyle.encode(foreColor: foreColor, backColor: backColor, effect: effect)
    }

    /// "CSI P_m h" for set or "CSI P_m l" for reset ANSI mode.
    private func doSetMode(_ newValue: Bool) {
        let modeBit = getArg0(0)
        switch modeBit {
        case 4: // Set="Insert Mode". Reset="Replace Mode". (IRM).
            insertMode = newValue
        case 20: // Normal Linefeed (LNM).
            unknownParameter(modeBit)
            // http://www.vt100.net/docs/vt510-rm/LNM
        case 34:
            // Normal cursor visibility - when using TERM=screen, see
            // http://www.gnu.org/software/screen/manual/html_node/Control-Sequences.html
            break
        default:
            unknownParameter(modeBit)
        }
    }

    /// NOTE: The parameters of this function respect the `DECSET_BIT_ORIGIN_MODE`. Use
    /// `setCursorRowCol(_:_:)` for absolute pos.
    private func setCursorPosition(_ x: Int, _ y: Int) {
        let originMode = isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_ORIGIN_MODE)
        let effectiveTopMargin = originMode ? topMargin : 0
        let effectiveBottomMargin = originMode ? bottomMargin : rows
        let effectiveLeftMargin = originMode ? leftMargin : 0
        let effectiveRightMargin = originMode ? rightMargin : columns
        let newRow = max(effectiveTopMargin, min(effectiveTopMargin + y, effectiveBottomMargin - 1))
        let newCol = max(effectiveLeftMargin, min(effectiveLeftMargin + x, effectiveRightMargin - 1))
        setCursorRowCol(newRow, newCol)
    }

    private func scrollDownOneLine() {
        scrollCounter += 1
        let currentStyle = getStyle()
        if leftMargin != 0 || rightMargin != columns {
            // Horizontal margin: Do not put anything into scroll history, just non-margin part of screen up.
            screen.blockCopy(leftMargin, topMargin + 1, rightMargin - leftMargin, bottomMargin - topMargin - 1, leftMargin, topMargin)
            // .. and blank bottom row between margins:
            screen.blockSet(leftMargin, bottomMargin - 1, rightMargin - leftMargin, 1, 32, currentStyle)
        } else {
            screen.scrollDownOneLine(topMargin, bottomMargin, currentStyle)
        }
    }

    /// Process the next ASCII character of a parameter.
    ///
    /// You must use the ; character to separate parameters and : to separate sub-parameters.
    ///
    /// Parameter characters modify the action or interpretation of the sequence. Originally
    /// you can use up to 16 parameters per sequence, but following at least xterm and alacritty
    /// we use a common space for parameters and sub-parameters, allowing 32 in total.
    ///
    /// All parameters are unsigned, positive decimal integers, with the most significant
    /// digit sent first. Any parameter greater than 9999 (decimal) is set to 9999
    /// (decimal). If you do not specify a value, a 0 value is assumed. A 0 value
    /// or omitted parameter indicates a default value for the sequence. For most
    /// sequences, the default value is 1.
    private func parseArg(_ b: Int) {
        if b >= ch("0") && b <= ch("9") {
            if argIndex < args.count {
                let oldValue = args[argIndex]
                let thisDigit = b - ch("0")
                var value: Int
                if oldValue >= 0 {
                    value = oldValue * 10 + thisDigit
                } else {
                    value = thisDigit
                }
                if value > 9999 {
                    value = 9999
                }
                args[argIndex] = value
            }
            continueSequence(escapeState)
        } else if b == ch(";") || b == ch(":") {
            if argIndex + 1 < args.count {
                argIndex += 1
                if b == ch(":") {
                    argsSubParamsBitSet |= 1 << argIndex
                }
            } else {
                logError("Too many parameters when in state: \(escapeState)")
            }
            continueSequence(escapeState)
        } else {
            unknownSequence(b)
        }
    }

    private func getArg0(_ defaultValue: Int) -> Int {
        return getArg(0, defaultValue, true)
    }

    private func getArg1(_ defaultValue: Int) -> Int {
        return getArg(1, defaultValue, true)
    }

    private func getArg(_ index: Int, _ defaultValue: Int, _ treatZeroAsDefault: Bool) -> Int {
        // Java would throw ArrayIndexOutOfBoundsException for an index past the end; treat as missing instead.
        if index < 0 || index >= args.count { return defaultValue }
        var result = args[index]
        if result < 0 || (result == 0 && treatZeroAsDefault) {
            result = defaultValue
        }
        return result
    }

    /// Collect code point in `terminalControlArgs`.
    private func collectTerminalControlArgs(_ b: Int) -> Bool {
        if terminalControlArgs.count < terminalControlArgsMaxLength {
            UTF16Util.appendCodePoint(b, to: &terminalControlArgs)
            continueSequence(escapeState)
            return true
        } else {
            Logger.logError(client, TerminalEmulator.LOG_TAG, "Terminal control args input will" +
                " overflow max args length \(terminalControlArgsMaxLength) for" +
                " numeric value=\(b) and args string with length \(terminalControlArgs.count)")
        }

        clearTerminalControlArgs()
        finishSequence()
        return false
    }

    /// Clear `terminalControlArgs`.
    private func clearTerminalControlArgs() {
        terminalControlArgsMaxLength = TerminalEmulator.TERMINAL_CONTROL_ARGS__DEFAULT_MAX_LENGTH
        if terminalControlArgs.capacity > 4096 {
            terminalControlArgs = []
        } else {
            terminalControlArgs.removeAll(keepingCapacity: true)
        }
    }

    /// Set `terminalControlArgsMaxLength` in case a command expects a larger input.
    private func setTerminalControlArgsMaxLength(_ length: Int) {
        if length > 0 {
            terminalControlArgsMaxLength = length
        }
    }

    private func unimplementedSequence(_ b: Int) {
        logError("Unimplemented sequence char (U+\(TerminalEmulator.hex(b, width: 4)))")
        finishSequence()
    }

    private func unknownSequence(_ b: Int) {
        logError("Unknown sequence char (numeric value=\(b))")
        finishSequence()
    }

    private func unknownParameter(_ parameter: Int) {
        logError("Unknown parameter: \(parameter)")
        finishSequence()
    }

    private func logError(_ errorType: String) {
        if TerminalEmulator.LOG_ESCAPE_SEQUENCES {
            var buf = errorType
            buf += ", escapeState=\(escapeState)"
            var firstArg = true
            if argIndex >= args.count { argIndex = args.count - 1 }
            for i in 0...argIndex {
                let value = args[i]
                if value >= 0 {
                    if firstArg {
                        firstArg = false
                        buf += ", args={"
                    } else {
                        buf += ","
                    }
                    buf += "\(value)"
                }
            }
            if !firstArg { buf += "}" }
            finishSequenceAndLogError(buf)
        }
    }

    private func finishSequenceAndLogError(_ error: String) {
        if TerminalEmulator.LOG_ESCAPE_SEQUENCES { Logger.logWarn(client, TerminalEmulator.LOG_TAG, error) }
        finishSequence()
    }

    private func finishSequence() {
        escapeState = TerminalEmulator.ESC_NONE
    }

    /// DEC special graphics (line drawing) mapping - http://www.vt100.net/docs/vt102-ug/table5-15.html.
    private static func lineDrawingCodePoint(_ codePoint: Int) -> Int {
        switch codePoint {
        case ch("_"): return 32 // Blank.
        case ch("`"): return 0x25C6 // '◆' Diamond.
        case ch("0"): return 0x2588 // '█' Solid block;
        case ch("a"): return 0x2592 // '▒' Checker board.
        case ch("b"): return 0x2409 // '␉' Horizontal tab.
        case ch("c"): return 0x240C // '␌' Form feed.
        case ch("d"): return 13 // '\r' Carriage return.
        case ch("e"): return 0x240A // '␊' Linefeed.
        case ch("f"): return 0x00B0 // '°' Degree.
        case ch("g"): return 0x00B1 // '±' Plus-minus.
        case ch("h"): return 10 // '\n' Newline.
        case ch("i"): return 0x240B // '␋' Vertical tab.
        case ch("j"): return 0x2518 // '┘' Lower right corner.
        case ch("k"): return 0x2510 // '┐' Upper right corner.
        case ch("l"): return 0x250C // '┌' Upper left corner.
        case ch("m"): return 0x2514 // '└' Left left corner.
        case ch("n"): return 0x253C // '┼' Crossing lines.
        case ch("o"): return 0x23BA // '⎺' Horizontal line - scan 1.
        case ch("p"): return 0x23BB // '⎻' Horizontal line - scan 3.
        case ch("q"): return 0x2500 // '─' Horizontal line - scan 5.
        case ch("r"): return 0x23BC // '⎼' Horizontal line - scan 7.
        case ch("s"): return 0x23BD // '⎽' Horizontal line - scan 9.
        case ch("t"): return 0x251C // '├' T facing rightwards.
        case ch("u"): return 0x2524 // '┤' T facing leftwards.
        case ch("v"): return 0x2534 // '┴' T facing upwards.
        case ch("w"): return 0x252C // '┬' T facing downwards.
        case ch("x"): return 0x2502 // '│' Vertical line.
        case ch("y"): return 0x2264 // '≤' Less than or equal to.
        case ch("z"): return 0x2265 // '≥' Greater than or equal to.
        case ch("{"): return 0x03C0 // 'π' Pi.
        case ch("|"): return 0x2260 // '≠' Not equal to.
        case ch("}"): return 0x00A3 // '£' UK pound.
        case ch("~"): return 0x00B7 // '·' Centered dot.
        default: return codePoint
        }
    }

    /// Send a Unicode code point to the screen.
    ///
    /// - Parameter codePoint: The code point of the character to display
    private func emitCodePoint(_ codePointIn: Int) {
        var codePoint = codePointIn
        lastEmittedCodePoint = codePoint
        if useLineDrawingUsesG0 ? useLineDrawingG0 : useLineDrawingG1 {
            // http://www.vt100.net/docs/vt102-ug/table5-15.html.
            codePoint = TerminalEmulator.lineDrawingCodePoint(codePoint)
        }

        let autoWrap = isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_AUTOWRAP)
        let displayWidth = WcWidth.width(codePoint)
        let cursorInLastColumn = cursorCol == rightMargin - 1

        if autoWrap {
            if cursorInLastColumn && ((aboutToAutoWrap && displayWidth == 1) || displayWidth == 2) {
                screen.setLineWrap(cursorRow)
                cursorCol = leftMargin
                if cursorRow + 1 < bottomMargin {
                    cursorRow += 1
                } else {
                    scrollDownOneLine()
                }
            }
        } else if cursorInLastColumn && displayWidth == 2 {
            // The behaviour when a wide character is output with cursor in the last column when
            // autowrap is disabled is not obvious - it's ignored here.
            return
        }

        if insertMode && displayWidth > 0 {
            // Move character to right one space.
            let destCol = cursorCol + displayWidth
            if destCol < rightMargin {
                screen.blockCopy(cursorCol, cursorRow, rightMargin - destCol, 1, destCol, cursorRow)
            }
        }

        let offsetDueToCombiningChar = ((displayWidth <= 0 && cursorCol > 0 && !aboutToAutoWrap) ? 1 : 0)
        var column = cursorCol - offsetDueToCombiningChar

        // Fix TerminalRow.setChar() ArrayIndexOutOfBoundsException index=-1 exception reported
        // The offsetDueToCombiningChar would never be 1 if mCursorCol was 0 to get column/index=-1,
        // so was mCursorCol changed after the offsetDueToCombiningChar conditional by another thread?
        if column < 0 { column = 0 }
        screen.setChar(column, cursorRow, codePoint, getStyle())

        if autoWrap && displayWidth > 0 {
            aboutToAutoWrap = (cursorCol == rightMargin - displayWidth)
        }

        cursorCol = min(cursorCol + displayWidth, rightMargin - 1)
    }

    private func setCursorRow(_ row: Int) {
        cursorRow = row
        aboutToAutoWrap = false
    }

    private func setCursorCol(_ col: Int) {
        cursorCol = col
        aboutToAutoWrap = false
    }

    /// Set the cursor mode, but limit it to margins if `DECSET_BIT_ORIGIN_MODE` is enabled.
    private func setCursorColRespectingOriginMode(_ col: Int) {
        setCursorPosition(col, cursorRow)
    }

    /// TODO: Better name, distinguished from `setCursorPosition(_:_:)` by not regarding origin mode.
    private func setCursorRowCol(_ row: Int, _ col: Int) {
        cursorRow = max(0, min(row, rows - 1))
        cursorCol = max(0, min(col, columns - 1))
        aboutToAutoWrap = false
    }

    public func clearScrollCounter() {
        scrollCounter = 0
    }

    public func toggleAutoScrollDisabled() {
        isAutoScrollDisabled = !isAutoScrollDisabled
    }

    /// Reset terminal state so user can interact with it regardless of present state.
    public func reset() {
        setCursorStyle()
        argIndex = 0
        continueSequenceFlag = false
        escapeState = TerminalEmulator.ESC_NONE
        insertMode = false
        topMargin = 0
        leftMargin = 0
        bottomMargin = rows
        rightMargin = columns
        aboutToAutoWrap = false
        foreColor = TextStyle.COLOR_INDEX_FOREGROUND
        savedStateMain.savedForeColor = TextStyle.COLOR_INDEX_FOREGROUND
        savedStateAlt.savedForeColor = TextStyle.COLOR_INDEX_FOREGROUND
        backColor = TextStyle.COLOR_INDEX_BACKGROUND
        savedStateMain.savedBackColor = TextStyle.COLOR_INDEX_BACKGROUND
        savedStateAlt.savedBackColor = TextStyle.COLOR_INDEX_BACKGROUND
        setDefaultTabStops()

        useLineDrawingG0 = false
        useLineDrawingG1 = false
        useLineDrawingUsesG0 = true

        for state in [savedStateMain, savedStateAlt] {
            state.savedCursorRow = 0
            state.savedCursorCol = 0
            state.savedEffect = 0
            state.savedDecFlags = 0
        }
        currentDecSetFlags = 0
        // Initial wrap-around is not accurate but makes terminal more useful, especially on a small screen:
        setDecsetinternalBit(TerminalEmulator.DECSET_BIT_AUTOWRAP, true)
        setDecsetinternalBit(TerminalEmulator.DECSET_BIT_CURSOR_ENABLED, true)
        savedDecSetFlags = currentDecSetFlags
        savedStateMain.savedDecFlags = currentDecSetFlags
        savedStateAlt.savedDecFlags = currentDecSetFlags

        // XXX: Should we set terminal driver back to IUTF8 with termios?
        utf8Index = 0
        utf8ToFollow = 0

        colors.reset()
        session?.onColorsChanged()

        clearTerminalControlArgs()
        clearOscTypeVariables()
    }

    public func getSelectedText(x1: Int, y1: Int, x2: Int, y2: Int) -> String {
        return screen.getSelectedText(selX1: x1, selY1: y1, selX2: x2, selY2: y2)
    }

    /// Change the terminal session's title.
    private func setTitle(_ newTitle: String?) {
        let oldTitle = title
        title = newTitle
        if oldTitle != newTitle {
            session?.titleChanged(oldTitle: oldTitle, newTitle: newTitle)
        }
    }

    /// If DECSET 2004 is set, prefix paste with "\033[200~" and suffix with "\033[201~".
    public func paste(_ textIn: String) {
        // First: Always remove escape key and C1 control characters [0x80,0x9F]:
        // Second: Replace all newlines (\n) or CRLF (\r\n) with carriage returns (\r).
        // (Done on unicode scalars, since Swift treats "\r\n" as a single Character.)
        var scalars = String.UnicodeScalarView()
        var pendingCR = false
        for scalar in textIn.unicodeScalars {
            let v = scalar.value
            if v == 0x1B || (v >= 0x80 && v <= 0x9F) { continue }
            if pendingCR {
                pendingCR = false
                if v == 0x0A {
                    scalars.append("\r")
                    continue
                }
                scalars.append("\r")
            }
            if v == 0x0D {
                pendingCR = true
                continue
            }
            if v == 0x0A {
                scalars.append("\r")
            } else {
                scalars.append(scalar)
            }
        }
        if pendingCR { scalars.append("\r") }
        let text = String(scalars)

        // Then: Implement bracketed paste mode if enabled:
        let bracketed = isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_BRACKETED_PASTE_MODE)
        if bracketed { session?.write("\u{1B}[200~") }
        session?.write(text)
        if bracketed { session?.write("\u{1B}[201~") }
    }

    /// http://www.vt100.net/docs/vt510-rm/DECSC
    final class SavedScreenState {
        /// Saved state of the cursor position, Used to implement the save/restore cursor position escape sequences.
        var savedCursorRow = 0
        var savedCursorCol = 0
        var savedEffect = 0
        var savedForeColor = 0
        var savedBackColor = 0
        var savedDecFlags = 0
        var useLineDrawingG0 = false
        var useLineDrawingG1 = false
        var useLineDrawingUsesG0 = true
    }

    public var description: String {
        return "TerminalEmulator[size=\(screen.columns)x\(screen.screenRows), margins={\(topMargin),\(rightMargin),\(bottomMargin),\(leftMargin)}]"
    }

    // MARK: - Helpers

    static func hex(_ value: Int, width: Int, uppercase: Bool = false) -> String {
        var s = String(value, radix: 16, uppercase: uppercase)
        while s.count < width { s = "0" + s }
        return s
    }

    /// Like Java `String.split(";")`: trailing empty strings are removed.
    static func javaSplit(_ s: String, separator: Character) -> [String] {
        var parts = s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        while let last = parts.last, last.isEmpty, parts.count > 0 {
            parts.removeLast()
            if parts.isEmpty { break }
        }
        if parts.isEmpty && s.isEmpty { return [""] }
        return parts
    }

    /// Lenient base64 decoding like `android.util.Base64.decode(s, Base64.DEFAULT)`: characters outside the
    /// alphabet (like whitespace and newlines) are skipped and padding is optional. Returns nil on invalid input.
    static func decodeBase64Lenient(_ chars: [UInt16]) -> [UInt8]? {
        var values = [UInt8]()
        values.reserveCapacity(chars.count)
        var sawPadding = false
        for c in chars {
            let v: Int
            switch c {
            case 0x41...0x5A: v = Int(c) - 0x41
            case 0x61...0x7A: v = Int(c) - 0x61 + 26
            case 0x30...0x39: v = Int(c) - 0x30 + 52
            case 0x2B, 0x2D: v = 62 // '+' (and URL-safe '-')
            case 0x2F, 0x5F: v = 63 // '/' (and URL-safe '_')
            case 0x3D: sawPadding = true; continue // '='
            default: continue
            }
            if sawPadding { return nil } // Data after padding.
            values.append(UInt8(v))
        }
        if values.count % 4 == 1 { return nil }
        var out = [UInt8]()
        out.reserveCapacity(values.count * 3 / 4)
        var i = 0
        while i + 4 <= values.count {
            let n = (Int(values[i]) << 18) | (Int(values[i + 1]) << 12) | (Int(values[i + 2]) << 6) | Int(values[i + 3])
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
            i += 4
        }
        let remaining = values.count - i
        if remaining == 2 {
            let n = (Int(values[i]) << 18) | (Int(values[i + 1]) << 12)
            out.append(UInt8((n >> 16) & 0xFF))
        } else if remaining == 3 {
            let n = (Int(values[i]) << 18) | (Int(values[i + 1]) << 12) | (Int(values[i + 2]) << 6)
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
        }
        return out
    }
}

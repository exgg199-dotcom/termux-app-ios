import Foundation

@inline(__always) private func ch(_ s: Unicode.Scalar) -> Int { return Int(s.value) }

public final class TerminalEmulator: CustomStringConvertible {

    private static let LOG_ESCAPE_SEQUENCES = false

    public static let MOUSE_LEFT_BUTTON = 0

    public static let MOUSE_LEFT_BUTTON_MOVED = 32
    public static let MOUSE_WHEELUP_BUTTON = 64
    public static let MOUSE_WHEELDOWN_BUTTON = 65

    public static let UNICODE_REPLACEMENT_CHAR = 0xFFFD

    private static let ESC_NONE = 0
    private static let ESC = 1
    private static let ESC_POUND = 2
    private static let ESC_SELECT_LEFT_PAREN = 3
    private static let ESC_SELECT_RIGHT_PAREN = 4
    private static let ESC_CSI = 6
    private static let ESC_CSI_QUESTIONMARK = 7
    private static let ESC_CSI_DOLLAR = 8
    private static let ESC_PERCENT = 9
    private static let ESC_OSC = 10
    private static let ESC_OSC__ESC = 11
    private static let ESC_CSI_BIGGERTHAN = 12
    private static let ESC_DCS = 13
    private static let ESC_CSI_QUESTIONMARK_ARG_DOLLAR = 14
    private static let ESC_CSI_ARGS_SPACE = 15
    private static let ESC_CSI_ARGS_ASTERIX = 16
    private static let ESC_CSI_DOUBLE_QUOTE = 17
    private static let ESC_CSI_SINGLE_QUOTE = 18
    private static let ESC_CSI_EXCLAMATION = 19
    private static let ESC_APC = 20
    private static let ESC_APC__ESC = 21
    private static let ESC_CSI_UNSUPPORTED_PARAMETER_BYTE = 22
    private static let ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE = 23

    private static let MAX_ESCAPE_PARAMETERS = 32

    private static let DECSET_BIT_APPLICATION_CURSOR_KEYS = 1
    private static let DECSET_BIT_REVERSE_VIDEO = 1 << 1
    private static let DECSET_BIT_ORIGIN_MODE = 1 << 2
    private static let DECSET_BIT_AUTOWRAP = 1 << 3
    private static let DECSET_BIT_CURSOR_ENABLED = 1 << 4
    private static let DECSET_BIT_APPLICATION_KEYPAD = 1 << 5
    private static let DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE = 1 << 6
    private static let DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT = 1 << 7
    private static let DECSET_BIT_SEND_FOCUS_EVENTS = 1 << 8
    private static let DECSET_BIT_MOUSE_PROTOCOL_SGR = 1 << 9
    private static let DECSET_BIT_BRACKETED_PASTE_MODE = 1 << 10
    private static let DECSET_BIT_LEFTRIGHT_MARGIN_MODE = 1 << 11
    private static let DECSET_BIT_RECTANGULAR_CHANGEATTRIBUTE = 1 << 12

    public private(set) var title: String?
    private var titleStack: [String?] = []

    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0

    public private(set) var rows: Int
    public private(set) var columns: Int

    public private(set) var cellWidthPixels: Int
    public private(set) var cellHeightPixels: Int

    public static let TERMINAL_TRANSCRIPT_ROWS_MIN = 100
    public static let TERMINAL_TRANSCRIPT_ROWS_MAX = 50000
    public static let DEFAULT_TERMINAL_TRANSCRIPT_ROWS = 2000

    public static let TERMINAL_CURSOR_STYLE_BLOCK = 0
    public static let TERMINAL_CURSOR_STYLE_UNDERLINE = 1
    public static let TERMINAL_CURSOR_STYLE_BAR = 2
    public static let DEFAULT_TERMINAL_CURSOR_STYLE = TERMINAL_CURSOR_STYLE_BLOCK
    public static let TERMINAL_CURSOR_STYLES_LIST: [Int] = [TERMINAL_CURSOR_STYLE_BLOCK, TERMINAL_CURSOR_STYLE_UNDERLINE, TERMINAL_CURSOR_STYLE_BAR]

    public private(set) var cursorStyle = TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE

    let mainBuffer: TerminalBuffer
    let altBuffer: TerminalBuffer
    public private(set) var screen: TerminalBuffer

    private weak var session: TerminalOutput?

    private(set) var client: TerminalSessionClient?

    private var argIndex = 0
    private var args = [Int](repeating: 0, count: TerminalEmulator.MAX_ESCAPE_PARAMETERS)
    private var argsSubParamsBitSet = 0

    private static let TERMINAL_CONTROL_ARGS__DEFAULT_MAX_LENGTH = 16384

    private static let OSC_1337__MAX_KEPT_LENGTH = 256

    private var terminalControlArgsMaxLength = TerminalEmulator.TERMINAL_CONTROL_ARGS__DEFAULT_MAX_LENGTH

    private var terminalControlArgs: [UInt16] = []

    private var oscType = -1

    private var isFastPathOsc = false

    private var ignoreCrLfForOsc = false

    private var isFastPathDcs = false

    private var ESC_DCS__ESC = false

    private var ESC_DCS__SIXEL = false

    private var ESC_DCS__CHECK_IF_SIXEL = true

    private var sixelCommandPartNum = 0

    static let SIXEL__MAX_REPEAT = 8192

    private var continueSequenceFlag = false

    private var escapeState = 0

    private let savedStateMain = SavedScreenState()
    private let savedStateAlt = SavedScreenState()

    private var useLineDrawingG0 = false
    private var useLineDrawingG1 = false
    private var useLineDrawingUsesG0 = true

    private var currentDecSetFlags = 0
    private var savedDecSetFlags = 0

    private var insertMode = false

    private var tabStop: [Bool]

    private var topMargin = 0
    private var bottomMargin = 0
    private var leftMargin = 0
    private var rightMargin = 0

    private var aboutToAutoWrap = false

    private var cursorBlinkingEnabled = false

    private var cursorBlinkState = false

    var foreColor = 0
    var backColor = 0
    var underlineColor = 0

    var effect = 0

    public private(set) var scrollCounter = 0

    public var topRow = 0

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

    public func sendMouseEvent(_ mouseButtonIn: Int, column columnIn: Int, row rowIn: Int, pressed: Bool) {
        var mouseButton = mouseButtonIn
        var column = columnIn
        var row = rowIn
        if column < 1 { column = 1 }
        if column > columns { column = columns }
        if row < 1 { row = 1 }
        if row > rows { row = rows }

        if mouseButton == TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED && !isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT) {
        } else if isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_PROTOCOL_SGR) {
            session?.write("\u{1B}[<\(mouseButton);\(column);\(row)" + (pressed ? "M" : "m"))
        } else {
            mouseButton = pressed ? mouseButton : 3
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

    public var isMouseTrackingActive: Bool {
        return isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_PRESS_RELEASE) || isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_MOUSE_TRACKING_BUTTON_EVENT)
    }

    private func setDefaultTabStops() {
        for i in 0..<columns {
            tabStop[i] = (i & 7) == 0 && i != 0
        }
    }

    public func append(_ buffer: [UInt8], length: Int) {
        let count = min(length, buffer.count)
        for i in 0..<count {
            processByte(buffer[i])
        }
    }

    public func append(_ buffer: [UInt8]) {
        append(buffer, length: buffer.count)
    }

    private func processByte(_ byteToProcess: UInt8) {
        if utf8ToFollow > 0 {
            if (byteToProcess & 0b11000000) == 0b10000000 {
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
                        codePoint = TerminalEmulator.UNICODE_REPLACEMENT_CHAR
                    }

                    utf8Index = 0
                    utf8ToFollow = 0

                    if codePoint >= 0x80 && codePoint <= 0x9F {
                    } else {
                        if UTF16Util.isUnassignedOrSurrogate(codePoint) {
                            codePoint = TerminalEmulator.UNICODE_REPLACEMENT_CHAR
                        }
                        processCodePoint(codePoint)
                    }
                }
            } else {
                utf8Index = 0
                utf8ToFollow = 0
                emitCodePoint(TerminalEmulator.UNICODE_REPLACEMENT_CHAR)
                processByte(byteToProcess)
            }
        } else {
            if (byteToProcess & 0b10000000) == 0 {
                processCodePoint(Int(byteToProcess))
                return
            } else if (byteToProcess & 0b11100000) == 0b11000000 {
                utf8ToFollow = 1
            } else if (byteToProcess & 0b11110000) == 0b11100000 {
                utf8ToFollow = 2
            } else if (byteToProcess & 0b11111000) == 0b11110000 {
                utf8ToFollow = 3
            } else {
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
            if b == 27 {
                ESC_DCS__ESC = true
                return
            }
            continueSequenceFlag = false
            doDcs(b)
            if !continueSequenceFlag { escapeState = TerminalEmulator.ESC_NONE }
            return
        }

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
        case 0:
            break
        case 7:
            if escapeState == TerminalEmulator.ESC_OSC {
                receiveOsc(b)
            } else {
                session?.onBell()
            }
        case 8:
            if leftMargin == cursorCol {
                let previousRow = cursorRow - 1
                if previousRow >= 0 && screen.getLineWrap(previousRow) {
                    screen.clearLineWrap(previousRow)
                    setCursorRowCol(previousRow, rightMargin - 1)
                }
            } else {
                setCursorCol(cursorCol - 1)
            }
        case 9:
            cursorCol = nextTabStop(1)
        case 10, 11, 12:
            if !(escapeState == TerminalEmulator.ESC_DCS ||
                 ((escapeState == TerminalEmulator.ESC_OSC || escapeState == TerminalEmulator.ESC_OSC__ESC) && ignoreCrLfForOsc)) {
                doLinefeed()
            }
        case 13:
            if !(escapeState == TerminalEmulator.ESC_DCS ||
                 ((escapeState == TerminalEmulator.ESC_OSC || escapeState == TerminalEmulator.ESC_OSC__ESC) && ignoreCrLfForOsc)) {
                setCursorCol(leftMargin)
            }
        case 14:
            useLineDrawingUsesG0 = false
        case 15:
            useLineDrawingUsesG0 = true
        case 24, 26:
            if escapeState != TerminalEmulator.ESC_NONE {
                escapeState = TerminalEmulator.ESC_NONE
                emitCodePoint(127)
            }
        case 27:
            if escapeState == TerminalEmulator.ESC_DCS {
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
            case TerminalEmulator.ESC_SELECT_LEFT_PAREN:
                useLineDrawingG0 = (b == ch("0"))
            case TerminalEmulator.ESC_SELECT_RIGHT_PAREN:
                useLineDrawingG1 = (b == ch("0"))
            case TerminalEmulator.ESC_CSI:
                doCsi(b)
            case TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE, TerminalEmulator.ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE:
                doCsiUnsupportedParameterOrIntermediateByte(b)
            case TerminalEmulator.ESC_CSI_EXCLAMATION:
                if b == ch("p") {
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
                    let arg = getArg0(0)
                    if arg == 0 || arg == 2 {
                        effect &= ~TextStyle.CHARACTER_ATTRIBUTE_PROTECTED
                    } else if arg == 1 {
                        effect |= TextStyle.CHARACTER_ATTRIBUTE_PROTECTED
                    } else {
                        unknownSequence(b)
                    }
                } else {
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_SINGLE_QUOTE:
                if b == ch("}") {
                    let columnsAfterCursor = rightMargin - cursorCol
                    let columnsToInsert = min(getArg0(1), columnsAfterCursor)
                    let columnsToMove = columnsAfterCursor - columnsToInsert
                    screen.blockCopy(cursorCol, 0, columnsToMove, rows, cursorCol + columnsToInsert, 0)
                    blockClear(cursorCol, 0, columnsToInsert, rows)
                } else if b == ch("~") {
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
                    let mode = getArg0(0)
                    let value: Int
                    if mode == 47 || mode == 1047 || mode == 1049 {
                        value = (screen === altBuffer) ? 1 : 2
                    } else {
                        let internalBit = TerminalEmulator.mapDecSetBitToInternalBit(mode)
                        if internalBit != -1 {
                            value = isDecsetInternalBitSet(internalBit) ? 1 : 2
                        } else {
                            Logger.logError(client, TerminalEmulator.LOG_TAG, "Got DECRQM for unrecognized private DEC mode=\(mode)")
                            value = 0
                        }
                    }
                    session?.write("\u{1B}[?\(mode);\(value)$y")
                } else {
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_ARGS_SPACE:
                let arg = getArg0(0)
                switch b {
                case ch("q"):
                    switch arg {
                    case 0, 1, 2:
                        cursorStyle = TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
                    case 3, 4:
                        cursorStyle = TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE
                    case 5, 6:
                        cursorStyle = TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR
                    default:
                        break
                    }
                case ch("t"), ch("u"):
                    break
                default:
                    unknownSequence(b)
                }
            case TerminalEmulator.ESC_CSI_ARGS_ASTERIX:
                let attributeChangeExtent = getArg0(0)
                if b == ch("x") && (attributeChangeExtent >= 0 && attributeChangeExtent <= 2) {
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

    private func doCsiDollar(_ b: Int) {
        let originMode = isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_ORIGIN_MODE)
        let effectiveTopMargin = originMode ? topMargin : 0
        let effectiveBottomMargin = originMode ? bottomMargin : rows
        let effectiveLeftMargin = originMode ? leftMargin : 0
        let effectiveRightMargin = originMode ? rightMargin : columns
        switch b {
        case ch("v"):
            let topSource = min(getArg(0, 1, true) - 1 + effectiveTopMargin, rows)
            let leftSource = min(getArg(1, 1, true) - 1 + effectiveLeftMargin, columns)
            let bottomSource = min(max(getArg(2, rows, true) + effectiveTopMargin, topSource), rows)
            let rightSource = min(max(getArg(3, columns, true) + effectiveLeftMargin, leftSource), columns)
            let destionationTop = min(getArg(5, 1, true) - 1 + effectiveTopMargin, rows)
            let destinationLeft = min(getArg(6, 1, true) - 1 + effectiveLeftMargin, columns)
            let heightToCopy = min(rows - destionationTop, bottomSource - topSource)
            let widthToCopy = min(columns - destinationLeft, rightSource - leftSource)
            screen.blockCopy(leftSource, topSource, widthToCopy, heightToCopy, destinationLeft, destionationTop)
        case ch("{"), ch("x"), ch("z"):
            let erase = b != ch("x")
            let selective = b == ch("{")
            let keepVisualAttributes = erase && selective
            var argIndex = 0
            let fillChar: Int
            if erase {
                fillChar = 32
            } else {
                fillChar = getArg(argIndex, -1, true)
                argIndex += 1
            }
            if (fillChar >= 32 && fillChar <= 126) || (fillChar >= 160 && fillChar <= 255) {
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
            let reverse = b == ch("t")
            let top = min(getArg(0, 1, true) - 1, effectiveBottomMargin) + effectiveTopMargin
            let left = min(getArg(1, 1, true) - 1, effectiveRightMargin) + effectiveLeftMargin
            let bottom = min(getArg(2, rows, true) + 1, effectiveBottomMargin - 1) + effectiveTopMargin
            let right = min(getArg(3, columns, true) + 1, effectiveRightMargin - 1) + effectiveLeftMargin
            if argIndex >= 4 {
                if argIndex >= args.count { argIndex = args.count - 1 }
                for i in 4...argIndex {
                    var bits = 0
                    var setOrClear = true
                    switch getArg(i, 0, false) {
                    case 0:
                        bits = (TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE | TextStyle.CHARACTER_ATTRIBUTE_BLINK
                            | TextStyle.CHARACTER_ATTRIBUTE_INVERSE)
                        if !reverse { setOrClear = false }
                    case 1:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BOLD
                    case 4:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                    case 5:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BLINK
                    case 7:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_INVERSE
                    case 22:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BOLD
                        setOrClear = false
                    case 24:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                        setOrClear = false
                    case 25:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_BLINK
                        setOrClear = false
                    case 27:
                        bits = TextStyle.CHARACTER_ATTRIBUTE_INVERSE
                        setOrClear = false
                    default:
                        break
                    }
                    if reverse && !setOrClear {
                    } else {
                        screen.setOrClearEffect(bits, setOrClear, reverse, isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_RECTANGULAR_CHANGEATTRIBUTE),
                                                effectiveLeftMargin, effectiveRightMargin, top, left, bottom, right)
                    }
                }
            } else {
            }
        default:
            unknownSequence(b)
        }
    }

    private func doDcs(_ b: Int) {
        if
            (ESC_DCS__ESC && b == ch("\\")) ||
            (ESC_DCS__SIXEL && ((b == ch("#") || b == ch("!") || b == ch("\"")) &&
                ((terminalControlArgs.count >= (terminalControlArgsMaxLength / 2)) || (terminalControlArgs.count > 1 && sixelCommandPartNum == 1)))) {
            let dcs = terminalControlArgs

            if dcs.starts(with: [UInt16(ch("$")), UInt16(ch("q"))]) {
                if UTF16Util.string(dcs) == "$q\"p" {
                    let csiString = "64;1\"p"
                    session?.write("\u{1B}P1$r" + csiString + "\u{1B}\\")
                } else {
                    finishSequenceAndLogError("Unrecognized DECRQSS string: '\(UTF16Util.string(dcs))'")
                }
            } else if dcs.starts(with: [UInt16(ch("+")), UInt16(ch("q"))]) {
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
                            responseValue = "256"
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
                            case "%1", "&8":
                                break
                            default:
                                Logger.logWarn(client, TerminalEmulator.LOG_TAG, "Unhandled termcap/terminfo name: '\(trans)'")
                            }
                            session?.write("\u{1B}P0+r" + partSub + "\u{1B}\\")
                        }
                    } else {
                        Logger.logError(client, TerminalEmulator.LOG_TAG, "Invalid device termcap/terminfo name of odd length: \(partSub)")
                    }
                }
            }
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
                } else {
                    ESC_DCS__ESC = false

                    clearTerminalControlArgs()

                    _ = collectTerminalControlArgs(b)
                    return
                }
            } else {
                if TerminalEmulator.LOG_ESCAPE_SEQUENCES {
                    Logger.logError(client, TerminalEmulator.LOG_TAG, "Unrecognized device control string: \(UTF16Util.string(dcs))")
                }
            }

            clearTerminalControlArgs()
            clearDcsTypeVariables()
            finishSequence()
        } else {
            ESC_DCS__ESC = false

            if !collectTerminalControlArgs(b) { return }

            if ESC_DCS__CHECK_IF_SIXEL && !ESC_DCS__SIXEL {
                if b == ch("q") {
                    startIfSixelDcs()
                } else if b == ch(";") || (b >= ch("0") && b <= ch("9")) {
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

            screen.sixelStart(100, 100)
            clearTerminalControlArgs()
        }
    }

    private func getSixelDcsSetupArgs(_ dcs: [UInt16], _ indexIn: Int) -> [Int]? {
        var index = indexIn
        var args = [ 0,  0,  0]

        if index < dcs.count && Int(dcs[index]) == ch("q") { return args }

        var arg = 0
        var incArg = false
        while index < dcs.count {
            let c = Int(dcs[index])
            if c >= ch("0") && c <= ch("9") {
                if incArg { arg += 1; incArg = false }
                if arg > 2 { break }
                args[arg] = args[arg] &* 10 &+ (c - ch("0"))
                if args[arg] < 0 || args[arg] > Int(Int32.max) {
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
                            ESC_DCS__CHECK_IF_SIXEL = false
                        }
                    }
                    break
                }

                incArg = true
            } else if c == ch("q") {
                return args
            } else {
                break
            }
        }

        return nil
    }

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
                    if args[arg] > maxValue {
                        Logger.logError(client, TerminalEmulator.LOG_TAG, "The sixel \(name) command value overflow at index \(index)")
                        return nil
                    }
                } else if c == ch(";") {
                    if arg == 3 {
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
                (c >= ch("?") && c <= ch("~"))
                || c == ch("$")
                || c == ch("-") {
                screen.sixelReadData(c, repeatCount)
                index += 1
                repeatCount = 1
            }
            else if c == ch("#") {
                index += 1

                var color = 0
                while index < dcs.count {
                    let d = Int(dcs[index])
                    if d >= ch("0") && d <= ch("9") {
                        color = color &* 10 &+ (d - ch("0"))
                        if color > maxValue {
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

                if index == dcs.count || Int(dcs[index]) != ch(";") {
                    screen.sixelSetColor(color)
                }
                else {
                    index += 1

                    guard let (args, arg) = parseNumberedArgs("non-basic color") else {
                        isValidDcs = false
                        break
                    }

                    for i in 0..<args.count {
                        if i == 0 {
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

                    if isValidDcs && arg == 3 {
                        if args[0] == 2 {
                            screen.sixelSetRGBColor(color, args[1], args[2], args[3])
                        } else if args[0] == 1 {
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
            else if c == ch("!") {
                index += 1

                repeatCount = 0
                while index < dcs.count {
                    let d = Int(dcs[index])
                    if d >= ch("0") && d <= ch("9") {
                        repeatCount = repeatCount &* 10 &+ (d - ch("0"))
                        if repeatCount > maxValue {
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
            else if c == ch("\"") {
                index += 1

                guard let (args, arg) = parseNumberedArgs("raster") else {
                    isValidDcs = false
                    break
                }

                if arg == 3 {
                    let sixelWidth = args[2]
                    let sixelHeight = args[3]
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

    private func doCsiUnsupportedParameterOrIntermediateByte(_ b: Int) {
        if escapeState == TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE && b >= 0x30 && b <= 0x3F {
            continueSequence(TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE)
        } else if b >= 0x20 && b <= 0x2F {
            continueSequence(TerminalEmulator.ESC_CSI_UNSUPPORTED_INTERMEDIATE_BYTE)
        } else if b >= 0x40 && b <= 0x7E {
            finishSequence()
        } else {
            unknownSequence(b)
        }
    }

    private func doCsiQuestionMark(_ b: Int) {
        switch b {
        case ch("J"), ch("K"):
            aboutToAutoWrap = false
            let fillChar = 32
            var startCol = -1
            var startRow = -1
            var endCol = -1
            var endRow = -1
            let justRow = (b == ch("K"))
            switch getArg0(0) {
            case 0:
                startCol = cursorCol
                startRow = cursorRow
                endCol = columns
                endRow = justRow ? (cursorRow + 1) : rows
            case 1:
                startCol = 0
                startRow = justRow ? cursorRow : 0
                endCol = cursorCol + 1
                endRow = cursorRow + 1
            case 2:
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
        case ch("n"):
            switch getArg0(-1) {
            case 6:
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
        case 1:
            break
        case 3:
            leftMargin = 0
            topMargin = 0
            bottomMargin = rows
            rightMargin = columns
            setDecsetinternalBit(TerminalEmulator.DECSET_BIT_LEFTRIGHT_MARGIN_MODE, false)
            blockClear(0, 0, columns, rows)
            setCursorRowCol(0, 0)
        case 4:
            break
        case 5:
            break
        case 6:
            if setting { setCursorPosition(0, 0) }
        case 7, 8, 9, 12, 25:
            client?.onTerminalCursorStateChange(setting)
        case 40, 45, 66:
            break
        case 69:
            if !setting {
                leftMargin = 0
                rightMargin = columns
            }
        case 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 1034:
            break
        case 1048:
            if setting {
                saveCursor()
            } else {
                restoreCursor()
            }
        case 47, 1047, 1049:
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
                        cursorCol = col
                        cursorRow = row
                    }
                }
                if resized { resizeScreen() }
                if newScreen === altBuffer {
                    newScreen.blockSet(0, 0, columns, rows, 32, getStyle())
                }
            }
        case 2004:
            break
        default:
            unknownParameter(externalBit)
        }
    }

    private func doCsiBiggerThan(_ b: Int) {
        switch b {
        case ch("c"):
            session?.write("\u{1B}[>41;320;0c")
        case ch("m"):
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
        case ch("8"):
            screen.blockSet(0, 0, columns, rows, ch("E"), getStyle())
        default:
            unknownSequence(b)
        }
    }

    private func doEsc(_ b: Int) {
        switch b {
        case ch("#"):
            continueSequence(TerminalEmulator.ESC_POUND)
        case ch("("):
            continueSequence(TerminalEmulator.ESC_SELECT_LEFT_PAREN)
        case ch(")"):
            continueSequence(TerminalEmulator.ESC_SELECT_RIGHT_PAREN)
        case ch("6"):
            if cursorCol > leftMargin {
                cursorCol -= 1
            } else {
                let rows = bottomMargin - topMargin
                screen.blockCopy(leftMargin, topMargin, rightMargin - leftMargin - 1, rows, leftMargin + 1, topMargin)
                screen.blockSet(leftMargin, topMargin, 1, rows, 32, TextStyle.encode(foreColor: foreColor, backColor: backColor, effect: 0))
            }
        case ch("7"):
            saveCursor()
        case ch("8"):
            restoreCursor()
        case ch("9"):
            if cursorCol < rightMargin - 1 {
                cursorCol += 1
            } else {
                let rows = bottomMargin - topMargin
                screen.blockCopy(leftMargin + 1, topMargin, rightMargin - leftMargin - 1, rows, leftMargin, topMargin)
                screen.blockSet(rightMargin - 1, topMargin, 1, rows, 32, TextStyle.encode(foreColor: foreColor, backColor: backColor, effect: 0))
            }
        case ch("c"):
            reset()
            mainBuffer.clearTranscript()
            blockClear(0, 0, columns, rows)
            setCursorPosition(0, 0)
        case ch("D"):
            doLinefeed()
        case ch("E"):
            setCursorCol(isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_ORIGIN_MODE) ? leftMargin : 0)
            doLinefeed()
        case ch("F"):
            setCursorRowCol(0, bottomMargin - 1)
        case ch("H"):
            tabStop[cursorCol] = true
        case ch("M"):
            if cursorRow <= topMargin {
                screen.blockCopy(leftMargin, topMargin, rightMargin - leftMargin, bottomMargin - (topMargin + 1), leftMargin, topMargin + 1)
                blockClear(leftMargin, topMargin, rightMargin - leftMargin)
            } else {
                cursorRow -= 1
            }
        case ch("N"), ch("0"):
            break
        case ch("P"):
            clearTerminalControlArgs()
            clearDcsTypeVariables()
            continueSequence(TerminalEmulator.ESC_DCS)
        case ch("["):
            continueSequence(TerminalEmulator.ESC_CSI)
        case ch("="):
            setDecsetinternalBit(TerminalEmulator.DECSET_BIT_APPLICATION_KEYPAD, true)
        case ch("]"):
            clearTerminalControlArgs()
            clearOscTypeVariables()
            continueSequence(TerminalEmulator.ESC_OSC)
        case ch(">"):
            setDecsetinternalBit(TerminalEmulator.DECSET_BIT_APPLICATION_KEYPAD, false)
        case ch("_"):
            clearTerminalControlArgs()
            continueSequence(TerminalEmulator.ESC_APC)
        default:
            unknownSequence(b)
        }
    }

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
            aboutToAutoWrap = false
            let columnsAfterCursor = columns - cursorCol
            let spacesToInsert = min(getArg0(1), columnsAfterCursor)
            let charsToMove = columnsAfterCursor - spacesToInsert
            screen.blockCopy(cursorCol, cursorRow, charsToMove, 1, cursorCol + spacesToInsert, cursorRow)
            blockClear(cursorCol, cursorRow, spacesToInsert)
        case ch("A"):
            setCursorRow(max(0, cursorRow - getArg0(1)))
        case ch("B"):
            setCursorRow(min(rows - 1, cursorRow + getArg0(1)))
        case ch("C"), ch("a"):
            setCursorCol(min(rightMargin - 1, cursorCol + getArg0(1)))
        case ch("D"):
            setCursorCol(max(leftMargin, cursorCol - getArg0(1)))
        case ch("E"):
            setCursorPosition(0, cursorRow + getArg0(1))
        case ch("F"):
            setCursorPosition(0, cursorRow - getArg0(1))
        case ch("G"):
            setCursorCol(min(max(1, getArg0(1)), columns) - 1)
        case ch("H"), ch("f"):
            setCursorPosition(getArg1(1) - 1, getArg0(1) - 1)
        case ch("I"):
            setCursorCol(nextTabStop(getArg0(1)))
        case ch("J"):
            switch getArg0(0) {
            case 0:
                blockClear(cursorCol, cursorRow, columns - cursorCol)
                blockClear(0, cursorRow + 1, columns, rows - (cursorRow + 1))
            case 1:
                blockClear(0, 0, columns, cursorRow)
                blockClear(0, cursorRow, cursorCol + 1)
            case 2:
                blockClear(0, 0, columns, rows)
            case 3:
                mainBuffer.clearTranscript()
            default:
                unknownSequence(b)
                return
            }
            aboutToAutoWrap = false
        case ch("K"):
            switch getArg0(0) {
            case 0:
                blockClear(cursorCol, cursorRow, columns - cursorCol)
            case 1:
                blockClear(0, cursorRow, cursorCol + 1)
            case 2:
                blockClear(0, cursorRow, columns)
            default:
                unknownSequence(b)
                return
            }
            aboutToAutoWrap = false
        case ch("L"):
            let linesAfterCursor = bottomMargin - cursorRow
            let linesToInsert = min(getArg0(1), linesAfterCursor)
            let linesToMove = linesAfterCursor - linesToInsert
            screen.blockCopy(0, cursorRow, columns, linesToMove, 0, cursorRow + linesToInsert)
            blockClear(0, cursorRow, columns, linesToInsert)
        case ch("M"):
            aboutToAutoWrap = false
            let linesAfterCursor = bottomMargin - cursorRow
            let linesToDelete = min(getArg0(1), linesAfterCursor)
            let linesToMove = linesAfterCursor - linesToDelete
            screen.blockCopy(0, cursorRow + linesToDelete, columns, linesToMove, 0, cursorRow)
            blockClear(0, cursorRow + linesToMove, columns, linesToDelete)
        case ch("P"):
            aboutToAutoWrap = false
            let cellsAfterCursor = columns - cursorCol
            let cellsToDelete = min(getArg0(1), cellsAfterCursor)
            let cellsToMove = cellsAfterCursor - cellsToDelete
            screen.blockCopy(cursorCol + cellsToDelete, cursorRow, cellsToMove, 1, cursorCol, cursorRow)
            blockClear(cursorCol + cellsToMove, cursorRow, cellsToDelete)
        case ch("S"):
            let linesToScroll = getArg0(1)
            for _ in 0..<max(0, linesToScroll) {
                scrollDownOneLine()
            }
        case ch("T"):
            if argIndex == 0 {
                let linesToScrollArg = getArg0(1)
                let linesBetweenTopAndBottomMargins = bottomMargin - topMargin
                let linesToScroll = min(linesBetweenTopAndBottomMargins, linesToScrollArg)
                screen.blockCopy(leftMargin, topMargin, rightMargin - leftMargin, linesBetweenTopAndBottomMargins - linesToScroll, leftMargin, topMargin + linesToScroll)
                blockClear(leftMargin, topMargin, rightMargin - leftMargin, linesToScroll)
            } else {
                unimplementedSequence(b)
            }
        case ch("X"):
            aboutToAutoWrap = false
            screen.blockSet(cursorCol, cursorRow, min(getArg0(1), columns - cursorCol), 1, 32, getStyle())
        case ch("Z"):
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
        case ch("?"):
            continueSequence(TerminalEmulator.ESC_CSI_QUESTIONMARK)
        case ch(">"):
            continueSequence(TerminalEmulator.ESC_CSI_BIGGERTHAN)
        case ch("<"), ch("="):
            continueSequence(TerminalEmulator.ESC_CSI_UNSUPPORTED_PARAMETER_BYTE)
        case ch("`"):
            setCursorColRespectingOriginMode(getArg0(1) - 1)
        case ch("b"):
            if lastEmittedCodePoint == -1 { break }
            let numRepeat = getArg0(1)
            for _ in 0..<max(0, numRepeat) { emitCodePoint(lastEmittedCodePoint) }
        case ch("c"):
            if getArg0(0) == 0 { session?.write("\u{1B}[?64;1;2;4;6;9;15;18;21;22c") }
        case ch("d"):
            setCursorRow(min(max(1, getArg0(1)), rows) - 1)
        case ch("e"):
            setCursorPosition(cursorCol, cursorRow + getArg0(1))
        case ch("g"):
            switch getArg0(0) {
            case 0:
                tabStop[cursorCol] = false
            case 3:
                for i in 0..<columns {
                    tabStop[i] = false
                }
            default:
                break
            }
        case ch("h"):
            doSetMode(true)
        case ch("l"):
            doSetMode(false)
        case ch("m"):
            selectGraphicRendition()
        case ch("n"):
            switch getArg0(0) {
            case 5:
                let dsr: [UInt8] = [27, UInt8(ascii: "["), UInt8(ascii: "0"), UInt8(ascii: "n")]
                session?.write(dsr)
            case 6:
                session?.write("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R")
            default:
                break
            }
        case ch("r"):
            topMargin = max(0, min(getArg0(1) - 1, rows - 2))
            bottomMargin = max(topMargin + 2, min(getArg1(rows), rows))

            setCursorPosition(0, 0)
        case ch("s"):
            if isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_LEFTRIGHT_MARGIN_MODE) {
                leftMargin = min(getArg0(1) - 1, columns - 2)
                rightMargin = max(leftMargin + 1, min(getArg1(columns), columns))
                setCursorPosition(0, 0)
            } else {
                saveCursor()
            }
        case ch("t"):
            switch getArg0(0) {
            case 11:
                session?.write("\u{1B}[1t")
            case 13:
                session?.write("\u{1B}[3;0;0t")
            case 14:
                session?.write("\u{1B}[4;\(rows * cellHeightPixels);\(columns * cellWidthPixels)t")
            case 16:
                session?.write("\u{1B}[6;\(cellHeightPixels);\(cellWidthPixels)t")
            case 18:
                session?.write("\u{1B}[8;\(rows);\(columns)t")
            case 19:
                session?.write("\u{1B}[9;\(rows);\(columns)t")
            case 20:
                session?.write("\u{1B}]LIconLabel\u{1B}\\")
            case 21:
                session?.write("\u{1B}]l\u{1B}\\")
            case 22:
                titleStack.append(title)
                if titleStack.count > 20 {
                    titleStack.remove(at: 0)
                }
            case 23:
                if !titleStack.isEmpty { setTitle(titleStack.removeLast()) }
            default:
                break
            }
        case ch("u"):
            restoreCursor()
        case ch(" "):
            continueSequence(TerminalEmulator.ESC_CSI_ARGS_SPACE)
        default:
            parseArg(b)
        }
    }

    private func selectGraphicRendition() {
        if argIndex >= args.count { argIndex = args.count - 1 }
        var i = 0
        while i <= argIndex {
            defer { i += 1 }
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
            if code == 0 {
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
                    i += 1
                    if args[i] == 0 {
                        effect &= ~TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
                    } else {
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
            } else if code == 11 {
            } else if code == 22 {
                effect &= ~(TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_DIM)
            } else if code == 23 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_ITALIC
            } else if code == 24 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE
            } else if code == 25 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_BLINK
            } else if code == 27 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_INVERSE
            } else if code == 28 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE
            } else if code == 29 {
                effect &= ~TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH
            } else if code >= 30 && code <= 37 {
                foreColor = code - 30
            } else if code == 38 || code == 48 || code == 58 {
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
                        i += 4
                    }
                } else if firstArg == 5 {
                    let color = getArg(i + 2, 0, false)
                    i += 2
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
            } else if code == 39 {
                foreColor = TextStyle.COLOR_INDEX_FOREGROUND
            } else if code >= 40 && code <= 47 {
                backColor = code - 40
            } else if code == 49 {
                backColor = TextStyle.COLOR_INDEX_BACKGROUND
            } else if code == 59 {
                underlineColor = TextStyle.COLOR_INDEX_FOREGROUND
            } else if code >= 90 && code <= 97 {
                foreColor = code - 90 + 8
            } else if code >= 100 && code <= 107 {
                backColor = code - 100 + 8
            } else {
                if TerminalEmulator.LOG_ESCAPE_SEQUENCES {
                    Logger.logWarn(client, TerminalEmulator.LOG_TAG, "SGR unknown code \(code)")
                }
            }
        }
    }

    private func receiveApc(_ b: Int) {
        switch b {
        case 27:
            continueSequence(TerminalEmulator.ESC_APC__ESC)
        default:
            if !collectTerminalControlArgs(b) { return }
        }
    }

    private func receiveApcEsc(_ b: Int) {
        switch b {
        case ch("\\"):
            break
        default:
            if !collectTerminalControlArgs(27) { return }
            if !collectTerminalControlArgs(b) { return }
            continueSequence(TerminalEmulator.ESC_APC)
        }
    }

    public func clearApcTypeVariables() {}

    private func receiveOsc(_ b: Int) {
        switch b {
        case 7:
            doOsc("\u{07}")
            clearOscTypeVariables()
        case 27:
            continueSequence(TerminalEmulator.ESC_OSC__ESC)
        default:
            if oscType == 1337 && terminalControlArgs.count >= TerminalEmulator.OSC_1337__MAX_KEPT_LENGTH {
                continueSequence(escapeState)
                return
            }
            if !collectTerminalControlArgs(b) { return }
            if oscType == -1 {
                setOscTypeVariables()
            }
        }
    }

    private func receiveOscEsc(_ b: Int) {
        switch b {
        case ch("\\"):
            doOsc("\u{1B}\\")
            clearOscTypeVariables()
        default:
            if oscType == 1337 && terminalControlArgs.count >= TerminalEmulator.OSC_1337__MAX_KEPT_LENGTH {
                continueSequence(TerminalEmulator.ESC_OSC)
                return
            }
            if !collectTerminalControlArgs(27) { return }
            if !collectTerminalControlArgs(b) { return }
            continueSequence(TerminalEmulator.ESC_OSC)
        }
    }

    func setOscTypeVariables() {
        if oscType >= 0 { return }
        if !terminalControlArgs.contains(UInt16(ch(";"))) { return }

        var value = -1

        for c in terminalControlArgs {
            let b = Int(c)
            if b == ch(";") {
                oscType = value
                break
            } else if b >= ch("0") && b <= ch("9") {
                value = ((value < 0) ? 0 : value * 10) + (b - ch("0"))
                if value > 1_000_000 { oscType = -2; return }
            } else {
                oscType = -2
                return
            }
        }

        if oscType >= 0 {
            switch oscType {
            case 52:
                setTerminalControlArgsMaxLength((100 * 1024) +  10)
            case 1337:
                isFastPathOsc = true
                ignoreCrLfForOsc = true
            default:
                break
            }
        }
    }

    public func clearOscTypeVariables() {
        oscType = -1
        isFastPathOsc = false
        ignoreCrLfForOsc = false
    }

    private func doOsc(_ bellOrStringTerminator: String) {
        var value = -1
        var textParameter: [UInt16] = []
        let argsLength = terminalControlArgs.count

        var i = 0
        while i < argsLength {
            let b = Int(terminalControlArgs[i])
            if b == ch(";") {
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
            setTitle(UTF16Util.string(textParameter))
        case 4:
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
            var specialIndex = TextStyle.COLOR_INDEX_FOREGROUND + (value - 10)
            var lastSemiIndex = 0
            var charIndex = 0
            while true {
                let endOfInput = charIndex == textParameter.count
                if endOfInput || textParameter[charIndex] == semicolon {
                    let colorSpec = UTF16Util.string(textParameter[lastSemiIndex..<charIndex])
                    if colorSpec == "?" {
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
        case 52:
            let startIndex = (textParameter.firstIndex(of: semicolon) ?? -1) + 1
            if let decoded = TerminalEmulator.decodeBase64Lenient(Array(textParameter[startIndex...])) {
                let clipboardText = String(decoding: decoded, as: UTF8.self)
                session?.onCopyTextToClipboard(clipboardText)
            } else {
                Logger.logError(client, TerminalEmulator.LOG_TAG, "OSC Manipulate selection, invalid string '\(UTF16Util.string(textParameter))'")
            }
        case 104:
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
                            if endOfInput { break }
                        }
                    }
                    charIndex += 1
                }
            }
        case 110, 111, 112:
            colors.reset(TextStyle.COLOR_INDEX_FOREGROUND + (value - 110))
            session?.onColorsChanged()
        case 119:
            break
        case 1337:
            let prefixEnd = min(19, argsLength)
            let controlCommandPrefix = prefixEnd > 5 ? UTF16Util.string(terminalControlArgs[5..<prefixEnd]) : ""

            if controlCommandPrefix.hasPrefix("File=") ||
                controlCommandPrefix.hasPrefix("MultipartFile=") ||
                controlCommandPrefix.hasPrefix("FilePart=") ||
                controlCommandPrefix == "FileEnd" {
                clearTerminalControlArgs()
                break
            } else if controlCommandPrefix.hasPrefix("ReportCellSize") {
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

    private func doSetMode(_ newValue: Bool) {
        let modeBit = getArg0(0)
        switch modeBit {
        case 4:
            insertMode = newValue
        case 20:
            unknownParameter(modeBit)
        case 34:
            break
        default:
            unknownParameter(modeBit)
        }
    }

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
            screen.blockCopy(leftMargin, topMargin + 1, rightMargin - leftMargin, bottomMargin - topMargin - 1, leftMargin, topMargin)
            screen.blockSet(leftMargin, bottomMargin - 1, rightMargin - leftMargin, 1, 32, currentStyle)
        } else {
            screen.scrollDownOneLine(topMargin, bottomMargin, currentStyle)
        }
    }

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
        if index < 0 || index >= args.count { return defaultValue }
        var result = args[index]
        if result < 0 || (result == 0 && treatZeroAsDefault) {
            result = defaultValue
        }
        return result
    }

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

    private func clearTerminalControlArgs() {
        terminalControlArgsMaxLength = TerminalEmulator.TERMINAL_CONTROL_ARGS__DEFAULT_MAX_LENGTH
        if terminalControlArgs.capacity > 4096 {
            terminalControlArgs = []
        } else {
            terminalControlArgs.removeAll(keepingCapacity: true)
        }
    }

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

    private static func lineDrawingCodePoint(_ codePoint: Int) -> Int {
        switch codePoint {
        case ch("_"): return 32
        case ch("`"): return 0x25C6
        case ch("0"): return 0x2588
        case ch("a"): return 0x2592
        case ch("b"): return 0x2409
        case ch("c"): return 0x240C
        case ch("d"): return 13
        case ch("e"): return 0x240A
        case ch("f"): return 0x00B0
        case ch("g"): return 0x00B1
        case ch("h"): return 10
        case ch("i"): return 0x240B
        case ch("j"): return 0x2518
        case ch("k"): return 0x2510
        case ch("l"): return 0x250C
        case ch("m"): return 0x2514
        case ch("n"): return 0x253C
        case ch("o"): return 0x23BA
        case ch("p"): return 0x23BB
        case ch("q"): return 0x2500
        case ch("r"): return 0x23BC
        case ch("s"): return 0x23BD
        case ch("t"): return 0x251C
        case ch("u"): return 0x2524
        case ch("v"): return 0x2534
        case ch("w"): return 0x252C
        case ch("x"): return 0x2502
        case ch("y"): return 0x2264
        case ch("z"): return 0x2265
        case ch("{"): return 0x03C0
        case ch("|"): return 0x2260
        case ch("}"): return 0x00A3
        case ch("~"): return 0x00B7
        default: return codePoint
        }
    }

    private func emitCodePoint(_ codePointIn: Int) {
        var codePoint = codePointIn
        lastEmittedCodePoint = codePoint
        if useLineDrawingUsesG0 ? useLineDrawingG0 : useLineDrawingG1 {
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
            return
        }

        if insertMode && displayWidth > 0 {
            let destCol = cursorCol + displayWidth
            if destCol < rightMargin {
                screen.blockCopy(cursorCol, cursorRow, rightMargin - destCol, 1, destCol, cursorRow)
            }
        }

        let offsetDueToCombiningChar = ((displayWidth <= 0 && cursorCol > 0 && !aboutToAutoWrap) ? 1 : 0)
        var column = cursorCol - offsetDueToCombiningChar

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

    private func setCursorColRespectingOriginMode(_ col: Int) {
        setCursorPosition(col, cursorRow)
    }

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
        setDecsetinternalBit(TerminalEmulator.DECSET_BIT_AUTOWRAP, true)
        setDecsetinternalBit(TerminalEmulator.DECSET_BIT_CURSOR_ENABLED, true)
        savedDecSetFlags = currentDecSetFlags
        savedStateMain.savedDecFlags = currentDecSetFlags
        savedStateAlt.savedDecFlags = currentDecSetFlags

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

    private func setTitle(_ newTitle: String?) {
        let oldTitle = title
        title = newTitle
        if oldTitle != newTitle {
            session?.titleChanged(oldTitle: oldTitle, newTitle: newTitle)
        }
    }

    public func paste(_ textIn: String) {
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

        let bracketed = isDecsetInternalBitSet(TerminalEmulator.DECSET_BIT_BRACKETED_PASTE_MODE)
        if bracketed { session?.write("\u{1B}[200~") }
        session?.write(text)
        if bracketed { session?.write("\u{1B}[201~") }
    }

    final class SavedScreenState {
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

    static func hex(_ value: Int, width: Int, uppercase: Bool = false) -> String {
        var s = String(value, radix: 16, uppercase: uppercase)
        while s.count < width { s = "0" + s }
        return s
    }

    static func javaSplit(_ s: String, separator: Character) -> [String] {
        var parts = s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        while let last = parts.last, last.isEmpty, parts.count > 0 {
            parts.removeLast()
            if parts.isEmpty { break }
        }
        if parts.isEmpty && s.isEmpty { return [""] }
        return parts
    }

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
            case 0x2B, 0x2D: v = 62
            case 0x2F, 0x5F: v = 63
            case 0x3D: sawPadding = true; continue
            default: continue
            }
            if sawPadding { return nil }
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

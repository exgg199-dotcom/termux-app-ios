import Foundation

public final class LineEditor {
    public enum Event: Equatable {
        case submit(String)
        case interrupt
        case endOfFile
    }

    public struct FeedResult {
        public var output: [UInt8]
        public var event: Event?
        public var consumed: Int
        public var outputString: String { String(decoding: output, as: UTF8.self) }
    }

    public var columns: Int = 80
    public var history: [String] = [] { didSet { historyIndex = history.count } }
    public var completer: ((String) -> ShellInterpreter.Completion)?
    public var enablesBracketedPaste = false

    public private(set) var buffer: [Character] = []
    public private(set) var cursor = 0
    public var line: String { String(buffer) }

    private var promptPrefix = ""
    private var promptLine = ""
    private var promptWidth = 0
    private var cursorRow = 0
    private var out: [UInt8] = []

    private enum InputState { case normal, escape, csi([UInt8]), ss3 }
    private var state = InputState.normal
    private var pendingUTF8: [UInt8] = []
    private var neededUTF8Bytes = 0
    private var inPaste = false
    private var lastWasCarriageReturn = false
    private var lastWasTab = false
    private var historyIndex = 0
    private var savedLine: [Character] = []
    private var killBuffer: [Character] = []

    public init() {}

    public func begin(prompt: String) -> [UInt8] {
        out = []
        buffer = []
        cursor = 0
        cursorRow = 0
        historyIndex = history.count
        savedLine = []
        lastWasTab = false
        if let newlineIndex = prompt.lastIndex(of: "\n") {
            promptPrefix = String(prompt[...newlineIndex])
            promptLine = String(prompt[prompt.index(after: newlineIndex)...])
        } else {
            promptPrefix = ""
            promptLine = prompt
        }
        promptWidth = DisplayWidth.of(ANSI.strip(promptLine))
        if enablesBracketedPaste { emit("\u{1B}[?2004h") }
        emit(LineEditor.carriageReturnLineFeed(promptPrefix) + promptLine)
        return takeOutput()
    }

    public func feed(_ bytes: [UInt8]) -> FeedResult {
        out = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            if let event = process(b) {
                return FeedResult(output: takeOutput(), event: event, consumed: i)
            }
        }
        return FeedResult(output: takeOutput(), event: nil, consumed: bytes.count)
    }

    public func feed(_ string: String) -> FeedResult { feed(Array(string.utf8)) }

    public func resize(columns: Int) { self.columns = max(1, columns) }

    private func emit(_ s: String) { out.append(contentsOf: s.utf8) }
    private func takeOutput() -> [UInt8] { let o = out; out = []; return o }

    static func carriageReturnLineFeed(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private func width(_ range: Range<Int>) -> Int {
        var w = 0
        for k in range { w += DisplayWidth.of(buffer[k]) }
        return w
    }

    private var columnCount: Int { max(1, columns) }

    private func position(of index: Int) -> (Int, Int) {
        let off = promptWidth + width(0..<index)
        return (off / columnCount, off % columnCount)
    }

    private func moveCursor(to index: Int) {
        let (row, column) = position(of: index)
        let oldColumn = position(of: cursor).1
        if row < cursorRow { emit("\u{1B}[\(cursorRow - row)A") }
        if row > cursorRow { emit("\u{1B}[\(row - cursorRow)B") }
        if row == cursorRow && column < oldColumn && oldColumn - column <= 4 {
            emit(String(repeating: "\u{8}", count: oldColumn - column))
        } else if row == cursorRow && column > oldColumn {
            emit(column - oldColumn == 1 ? "\u{1B}[C" : "\u{1B}[\(column - oldColumn)C")
        } else if row != cursorRow || column != oldColumn {
            emit("\r")
            if column > 0 { emit("\u{1B}[\(column)C") }
        }
        cursor = index
        cursorRow = row
    }

    private func refresh() {
        if cursorRow > 0 { emit("\u{1B}[\(cursorRow)A") }
        emit("\r\u{1B}[J")
        emit(promptLine)
        emit(String(buffer))
        let total = promptWidth + width(0..<buffer.count)
        if total > 0 && total % columnCount == 0 { emit("\r\n") }
        cursorRow = total / columnCount
        let target = cursor
        cursor = buffer.count
        moveCursor(to: target)
    }

    private func redrawAll() {
        emit(LineEditor.carriageReturnLineFeed(promptPrefix))
        cursorRow = 0
        refresh()
    }

    private func insert(_ chars: [Character]) {
        for c in chars {
            if cursor > 0 {
                let merged = String(buffer[cursor - 1]) + String(c)
                if merged.count == 1 {
                    buffer[cursor - 1] = Character(merged)
                    refresh()
                    continue
                }
            }
            buffer.insert(c, at: cursor)
            cursor += 1
            if cursor == buffer.count {
                emit(String(c))
                let total = promptWidth + width(0..<buffer.count)
                if total % columnCount == 0 { emit("\r\n") }
                cursorRow = total / columnCount
            } else {
                refresh()
            }
        }
    }

    private func backspace() {
        guard cursor > 0 else { emit("\u{7}"); return }
        let w = DisplayWidth.of(buffer[cursor - 1])
        let (_, column) = position(of: cursor)
        if cursor == buffer.count && column >= w && w > 0 {
            buffer.remove(at: cursor - 1)
            cursor -= 1
            let b = String(repeating: "\u{8}", count: w)
            emit(b + String(repeating: " ", count: w) + b)
        } else {
            buffer.remove(at: cursor - 1)
            cursor -= 1
            refresh()
        }
    }

    private func deleteForward() {
        guard cursor < buffer.count else { return }
        buffer.remove(at: cursor)
        refresh()
    }

    private func deleteRange(_ r: Range<Int>, kill: Bool = true) {
        guard !r.isEmpty else { return }
        if kill { killBuffer = Array(buffer[r]) }
        buffer.removeSubrange(r)
        cursor = r.lowerBound
        refresh()
    }

    private func wordStart(before index: Int) -> Int {
        var k = index
        while k > 0 && buffer[k - 1].isWhitespace { k -= 1 }
        while k > 0 && !buffer[k - 1].isWhitespace { k -= 1 }
        return k
    }

    private func alphanumericWordStart(before index: Int) -> Int {
        var k = index
        while k > 0 && !(buffer[k - 1].isLetter || buffer[k - 1].isNumber) { k -= 1 }
        while k > 0 && (buffer[k - 1].isLetter || buffer[k - 1].isNumber) { k -= 1 }
        return k
    }

    private func alphanumericWordEnd(after index: Int) -> Int {
        var k = index
        while k < buffer.count && !(buffer[k].isLetter || buffer[k].isNumber) { k += 1 }
        while k < buffer.count && (buffer[k].isLetter || buffer[k].isNumber) { k += 1 }
        return k
    }

    private func setLine(_ chars: [Character]) {
        buffer = chars
        cursor = chars.count
        refresh()
    }

    private func historyUp() {
        guard historyIndex > 0 else { emit("\u{7}"); return }
        if historyIndex == history.count { savedLine = buffer }
        historyIndex -= 1
        setLine(Array(history[historyIndex]))
    }

    private func historyDown() {
        guard historyIndex < history.count else { emit("\u{7}"); return }
        historyIndex += 1
        setLine(historyIndex == history.count ? savedLine : Array(history[historyIndex]))
    }

    private func submit() -> Event {
        moveCursor(to: buffer.count)
        let total = promptWidth + width(0..<buffer.count)
        if !(total > 0 && total % columnCount == 0) { emit("\r\n") }
        if enablesBracketedPaste { emit("\u{1B}[?2004l") }
        let text = line
        buffer = []; cursor = 0; cursorRow = 0
        return .submit(text)
    }

    private func complete() {
        guard let completer = completer else { emit("\u{7}"); return }
        let before = String(buffer[0..<cursor])
        let result = completer(before)
        let wordLength = before.count - result.wordStart
        let candidates = result.candidates
        guard !candidates.isEmpty else { emit("\u{7}"); lastWasTab = false; return }
        func replaceWord(_ with: String) {
            let start = cursor - wordLength
            buffer.replaceSubrange(start..<cursor, with: Array(with))
            cursor = start + with.count
            refresh()
        }
        if candidates.count == 1 {
            let c = candidates[0]
            replaceWord(c.hasSuffix("/") ? c : c + " ")
            lastWasTab = false
            return
        }
        var prefix = candidates[0]
        for c in candidates.dropFirst() {
            while !c.hasPrefix(prefix) { prefix.removeLast() }
        }
        let currentWord = String(buffer[(cursor - wordLength)..<cursor])
        if prefix.count > currentWord.count && prefix != currentWord {
            replaceWord(prefix)
            lastWasTab = false
            return
        }
        if lastWasTab {
            let target = cursor
            moveCursor(to: buffer.count)
            let total = promptWidth + width(0..<buffer.count)
            if !(total > 0 && total % columnCount == 0) { emit("\r\n") }
            let listing = ShellFormat.columns(result.displays, width: columnCount)
            emit(LineEditor.carriageReturnLineFeed(listing))
            cursor = target
            redrawAll()
            lastWasTab = false
        } else {
            emit("\u{7}")
            lastWasTab = true
        }
    }

    private func process(_ b: UInt8) -> Event? {
        let wasTab = lastWasTab
        if b != 0x09 { lastWasTab = false }
        let wasCarriageReturn = lastWasCarriageReturn
        lastWasCarriageReturn = false

        switch state {
        case .escape:
            state = .normal
            switch b {
            case UInt8(ascii: "["): state = .csi([]); return nil
            case UInt8(ascii: "O"): state = .ss3; return nil
            case UInt8(ascii: "b"): moveCursor(to: alphanumericWordStart(before: cursor)); return nil
            case UInt8(ascii: "f"): moveCursor(to: alphanumericWordEnd(after: cursor)); return nil
            case UInt8(ascii: "d"): deleteRange(cursor..<alphanumericWordEnd(after: cursor)); return nil
            case 0x7F, 0x08: deleteRange(alphanumericWordStart(before: cursor)..<cursor); return nil
            case 0x1B: state = .escape; return nil
            default: return nil
            }
        case .csi(var parameters):
            if (0x20...0x3F).contains(b) {
                parameters.append(b)
                state = .csi(parameters)
                return nil
            }
            state = .normal
            return csi(String(decoding: parameters, as: UTF8.self), final: b)
        case .ss3:
            state = .normal
            return csi("", final: b)
        case .normal:
            break
        }

        if neededUTF8Bytes > 0 {
            if b & 0xC0 == 0x80 {
                pendingUTF8.append(b)
                neededUTF8Bytes -= 1
                if neededUTF8Bytes == 0 {
                    insert(Array(String(decoding: pendingUTF8, as: UTF8.self)))
                    pendingUTF8 = []
                }
                return nil
            }
            pendingUTF8 = []
            neededUTF8Bytes = 0
        }
        if b >= 0x80 {
            switch b {
            case 0xC0...0xDF: neededUTF8Bytes = 1
            case 0xE0...0xEF: neededUTF8Bytes = 2
            case 0xF0...0xF7: neededUTF8Bytes = 3
            default: return nil
            }
            pendingUTF8 = [b]
            return nil
        }

        if b == 0x1B { state = .escape; return nil }

        if inPaste {
            switch b {
            case 0x0D: lastWasCarriageReturn = true; return submit()
            case 0x0A: return wasCarriageReturn ? nil : submit()
            case 0x09: insert([" "])
            case 0x20...0x7E: insert([Character(Unicode.Scalar(b))])
            default: break
            }
            return nil
        }

        switch b {
        case 0x0D:
            lastWasCarriageReturn = true
            return submit()
        case 0x0A:
            if wasCarriageReturn { return nil }
            return submit()
        case 0x03:
            moveCursor(to: buffer.count)
            emit("^C\r\n")
            if enablesBracketedPaste { emit("\u{1B}[?2004l") }
            buffer = []; cursor = 0; cursorRow = 0
            return .interrupt
        case 0x04:
            if buffer.isEmpty {
                if enablesBracketedPaste { emit("\u{1B}[?2004l") }
                return .endOfFile
            }
            deleteForward()
        case 0x7F, 0x08:
            backspace()
        case 0x01: moveCursor(to: 0)
        case 0x05: moveCursor(to: buffer.count)
        case 0x02: if cursor > 0 { moveCursor(to: cursor - 1) }
        case 0x06: if cursor < buffer.count { moveCursor(to: cursor + 1) }
        case 0x0B: deleteRange(cursor..<buffer.count)
        case 0x15: deleteRange(0..<cursor)
        case 0x17: deleteRange(wordStart(before: cursor)..<cursor)
        case 0x19: if !killBuffer.isEmpty { insert(killBuffer) }
        case 0x0C:
            emit("\u{1B}[H\u{1B}[2J")
            redrawAll()
        case 0x10: historyUp()
        case 0x0E: historyDown()
        case 0x14:
            if cursor > 0 && buffer.count >= 2 {
                let k = cursor == buffer.count ? cursor - 1 : cursor
                buffer.swapAt(k - 1, k)
                cursor = min(buffer.count, k + 1)
                refresh()
            }
        case 0x09:
            lastWasTab = wasTab
            complete()
        case 0x20...0x7E:
            insert([Character(Unicode.Scalar(b))])
        default:
            break
        }
        return nil
    }

    private func csi(_ parameters: String, final: UInt8) -> Event? {
        let modified = parameters.contains(";5") || parameters.contains(";3")
        switch final {
        case UInt8(ascii: "A"): historyUp()
        case UInt8(ascii: "B"): historyDown()
        case UInt8(ascii: "C"):
            if modified { moveCursor(to: alphanumericWordEnd(after: cursor)) }
            else if cursor < buffer.count { moveCursor(to: cursor + 1) }
        case UInt8(ascii: "D"):
            if modified { moveCursor(to: alphanumericWordStart(before: cursor)) }
            else if cursor > 0 { moveCursor(to: cursor - 1) }
        case UInt8(ascii: "H"): moveCursor(to: 0)
        case UInt8(ascii: "F"): moveCursor(to: buffer.count)
        case UInt8(ascii: "~"):
            switch parameters.split(separator: ";").first.map(String.init) ?? "" {
            case "1", "7": moveCursor(to: 0)
            case "4", "8": moveCursor(to: buffer.count)
            case "3": deleteForward()
            case "200": inPaste = true
            case "201": inPaste = false
            default: break
            }
        default:
            break
        }
        return nil
    }
}

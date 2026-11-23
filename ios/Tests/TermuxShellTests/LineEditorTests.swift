import XCTest
@testable import TermuxShell

final class LineEditorTests: XCTestCase {
    var editor: LineEditor!

    override func setUp() {
        editor = LineEditor()
        editor.columns = 80
        _ = editor.begin(prompt: "$ ")
    }

    private func feed(_ s: String) -> LineEditor.FeedResult { editor.feed(s) }

    func testBeginPrintsPrompt() {
        let e = LineEditor()
        XCTAssertEqual(String(decoding: e.begin(prompt: "line1\n$ "), as: UTF8.self), "line1\r\n$ ")
        e.enablesBracketedPaste = true
        XCTAssertEqual(String(decoding: e.begin(prompt: "$ "), as: UTF8.self), "\u{1B}[?2004h$ ")
    }

    func testTypingEchoesAndSubmits() {
        let r1 = feed("ls")
        XCTAssertEqual(r1.outputString, "ls")
        XCTAssertNil(r1.event)
        let r2 = feed("\r")
        XCTAssertEqual(r2.outputString, "\r\n")
        XCTAssertEqual(r2.event, .submit("ls"))
    }

    func testCRLFCountsAsOneEnter() {
        let r = feed("a\r\nb")
        XCTAssertEqual(r.event, .submit("a"))
        XCTAssertEqual(r.consumed, 2)
        _ = editor.begin(prompt: "$ ")
        let r2 = editor.feed(Array("\nb".utf8))
        XCTAssertNil(r2.event, "LF right after CR is ignored")
        XCTAssertEqual(editor.line, "b")
    }

    func testFeedStopsAtEvent() {
        let r = feed("one\rtwo\r")
        XCTAssertEqual(r.event, .submit("one"))
        XCTAssertEqual(r.consumed, 4)
    }

    func testBackspace() {
        _ = feed("abc")
        let r = editor.feed([0x7F])
        XCTAssertEqual(r.outputString, "\u{8} \u{8}")
        XCTAssertEqual(editor.line, "ab")
        _ = editor.feed([0x08])
        XCTAssertEqual(editor.line, "a")
    }

    func testBackspaceOnEmptyRings() {
        XCTAssertEqual(editor.feed([0x7F]).outputString, "\u{7}")
    }

    func testCursorMovementAndInsert() {
        _ = feed("ac")
        let left = feed("\u{1B}[D")
        XCTAssertEqual(left.outputString, "\u{8}")
        XCTAssertEqual(editor.cursor, 1)
        let ins = feed("b")
        XCTAssertTrue(ins.outputString.contains("$ abc"), ins.outputString)
        XCTAssertTrue(ins.outputString.hasSuffix("\u{8}"), ins.outputString)
        XCTAssertEqual(editor.line, "abc")
        XCTAssertEqual(editor.cursor, 2)
        let right = feed("\u{1B}OC")
        XCTAssertEqual(right.outputString, "\u{1B}[C")
        XCTAssertEqual(editor.cursor, 3)
    }

    func testHomeEndAndControlAE() {
        _ = feed("hello")
        _ = feed("\u{1B}[H")
        XCTAssertEqual(editor.cursor, 0)
        _ = feed("\u{1B}[F")
        XCTAssertEqual(editor.cursor, 5)
        _ = editor.feed([0x01])
        XCTAssertEqual(editor.cursor, 0)
        _ = editor.feed([0x05])
        XCTAssertEqual(editor.cursor, 5)
        _ = feed("\u{1B}[1~")
        XCTAssertEqual(editor.cursor, 0)
        _ = feed("\u{1B}[4~")
        XCTAssertEqual(editor.cursor, 5)
    }

    func testDeleteKey() {
        _ = feed("abc")
        _ = editor.feed([0x01])
        _ = feed("\u{1B}[3~")
        XCTAssertEqual(editor.line, "bc")
        XCTAssertEqual(editor.cursor, 0)
    }

    func testControlUAndControlWAndControlK() {
        _ = feed("echo foo bar")
        _ = editor.feed([0x17])
        XCTAssertEqual(editor.line, "echo foo ")
        _ = editor.feed([0x17])
        XCTAssertEqual(editor.line, "echo ")
        _ = editor.feed([0x15])
        XCTAssertEqual(editor.line, "")
        _ = feed("abcdef")
        _ = feed("\u{1B}[D\u{1B}[D")
        _ = editor.feed([0x0B])
        XCTAssertEqual(editor.line, "abcd")
        _ = editor.feed([0x19])
        XCTAssertEqual(editor.line, "abcdef")
    }

    func testControlC() {
        _ = feed("partial")
        let r = editor.feed([0x03])
        XCTAssertEqual(r.event, .interrupt)
        XCTAssertEqual(r.outputString, "^C\r\n")
    }

    func testControlD() {
        XCTAssertEqual(editor.feed([0x04]).event, .endOfFile)
        _ = editor.begin(prompt: "$ ")
        _ = feed("ab")
        _ = editor.feed([0x01])
        let r = editor.feed([0x04])
        XCTAssertNil(r.event)
        XCTAssertEqual(editor.line, "b")
    }

    func testControlLClears() {
        _ = feed("x")
        let r = editor.feed([0x0C])
        XCTAssertTrue(r.outputString.hasPrefix("\u{1B}[H\u{1B}[2J"))
        XCTAssertTrue(r.outputString.contains("$ x"))
    }

    func testHistory() {
        editor.history = ["first", "second"]
        _ = feed("cur")
        _ = feed("\u{1B}[A")
        XCTAssertEqual(editor.line, "second")
        _ = feed("\u{1B}[A")
        XCTAssertEqual(editor.line, "first")
        _ = feed("\u{1B}[A")
        XCTAssertEqual(editor.line, "first")
        _ = feed("\u{1B}[B")
        XCTAssertEqual(editor.line, "second")
        _ = feed("\u{1B}[B")
        XCTAssertEqual(editor.line, "cur")
        _ = feed("\u{1B}OA")
        XCTAssertEqual(editor.line, "second")
        XCTAssertEqual(feed("\r").event, .submit("second"))
    }

    func testUTF8MultiByteInput() {
        let bytes = Array("héllo €𝄞".utf8)
        var output: [UInt8] = []
        for b in bytes { output += editor.feed([b]).output }
        XCTAssertEqual(editor.line, "héllo €𝄞")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "héllo €𝄞")
        _ = editor.feed([0x7F])
        XCTAssertEqual(editor.line, "héllo €")
    }

    func testWideCharacterBackspace() {
        _ = feed("日本")
        XCTAssertEqual(editor.feed([0x7F]).outputString, "\u{8}\u{8}  \u{8}\u{8}")
        XCTAssertEqual(editor.line, "日")
    }

    func testCombiningCharacterMerges() {
        _ = feed("e\u{301}")
        XCTAssertEqual(editor.buffer.count, 1)
        XCTAssertEqual(editor.line, "e\u{301}")
    }

    func testBracketedPaste() {
        let r = feed("\u{1B}[200~ls\u{03}\t-l\u{1B}[201~")
        XCTAssertNil(r.event, "control characters inside a paste must not act")
        XCTAssertEqual(editor.line, "ls -l")
        let r2 = feed("\u{1B}[200~echo a\necho b\u{1B}[201~")
        XCTAssertEqual(r2.event, .submit("ls -lecho a"))
    }

    func testLineWrapping() {
        editor.columns = 10
        _ = editor.begin(prompt: "$ ")
        let r = feed("12345678")
        XCTAssertTrue(r.outputString.hasSuffix("8\r\n"), r.outputString)
        _ = feed("9")
        _ = editor.feed([0x01])
        XCTAssertEqual(editor.cursor, 0)
        let end = editor.feed([0x05])
        XCTAssertEqual(end.outputString, "\u{1B}[1B\r\u{1B}[1C")
    }

    func testTabCompletionSingle() {
        editor.completer = { line in
            XCTAssertEqual(line, "ec")
            return ShellInterpreter.Completion(wordStart: 0, candidates: ["echo"], displays: ["echo"])
        }
        _ = feed("ec\t")
        XCTAssertEqual(editor.line, "echo ")
    }

    func testTabCompletionCommonPrefixAndListing() {
        editor.completer = { line in
            let start = (line.lastIndex(of: " ").map { line.distance(from: line.startIndex, to: $0) + 1 }) ?? 0
            return ShellInterpreter.Completion(wordStart: start, candidates: ["alpha.txt", "alpine.txt"], displays: ["alpha.txt", "alpine.txt"])
        }
        _ = feed("cat a\t")
        XCTAssertEqual(editor.line, "cat alp")
        let first = feed("\t")
        XCTAssertEqual(first.outputString, "\u{7}")
        let second = feed("\t")
        XCTAssertTrue(second.outputString.contains("alpha.txt  alpine.txt\r\n"), second.outputString)
        XCTAssertTrue(second.outputString.hasSuffix("$ cat alp"), second.outputString)
    }

    func testIntegrationWithInterpreterCompletion() throws {
        let home = NSTemporaryDirectory() + "le-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/Documents", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let shell = ShellInterpreter(homeDirectory: home)
        editor.completer = shell.complete
        _ = feed("cd Doc\t")
        XCTAssertEqual(editor.line, "cd Documents/")
    }
}

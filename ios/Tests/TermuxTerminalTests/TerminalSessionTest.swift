import XCTest
@testable import TermuxTerminal

/// iOS-specific tests (no Java counterpart): `TerminalSession` driven by a mock `TerminalBackend`, and checks that
/// unsupported image sequences (sixel, iTerm inline images) are consumed without corrupting the screen.
final class TerminalSessionTest: TerminalTestCase {

    final class MockBackend: TerminalBackend {
        var onOutput: (([UInt8]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var started: (Int, Int)?
        var resized: (Int, Int)?
        var written = [UInt8]()
        var terminated = false
        var pid: Int32 { return -1 }

        func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) { started = (columns, rows) }
        func write(_ data: [UInt8]) { written.append(contentsOf: data) }
        func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) { resized = (columns, rows) }
        func terminate() { terminated = true; onExit?(-9) }
    }

    final class MockClient: TerminalSessionClient {
        var textChanged = 0
        var finished = 0
        var titles = [String?]()
        var clipboard = [String]()
        var bells = 0
        var onFinish: (() -> Void)?
        var onText: (() -> Void)?

        func onTextChanged(_ session: TerminalSession) { textChanged += 1; onText?() }
        func onTitleChanged(_ session: TerminalSession) { titles.append(session.title) }
        func onSessionFinished(_ session: TerminalSession) { finished += 1; onFinish?() }
        func onCopyTextToClipboard(_ session: TerminalSession, text: String) { clipboard.append(text) }
        func onPasteTextFromClipboard(_ session: TerminalSession?) {}
        func onBell(_ session: TerminalSession) { bells += 1 }
        func onColorsChanged(_ session: TerminalSession) {}
        func onTerminalCursorStateChange(_ state: Bool) {}
        var terminalCursorStyle: Int? { return TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR }
        func log(_ level: LogLevel, tag: String, _ message: String) {}
    }

    func testSessionOutputAndExit() {
        let backend = MockBackend()
        let client = MockClient()
        let session = TerminalSession(backend: backend, transcriptRows: nil, client: client)
        XCTAssertNil(session.emulator)
        XCTAssertEqual(0, session.pid)
        session.updateSize(columns: 20, rows: 4, cellWidthPixels: 10, cellHeightPixels: 20)
        XCTAssertNotNil(session.emulator)
        XCTAssertEqual(20, backend.started?.0)
        XCTAssertEqual(TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR, session.emulator?.cursorStyle)
        XCTAssertTrue(session.isRunning)

        // Input is forwarded to the backend:
        session.writeCodePoint(prependEscape: true, codePoint: 0x20AC)
        XCTAssertEqual([27, 0xE2, 0x82, 0xAC], backend.written)

        // Output is delivered on the main queue from any thread:
        let textExpectation = expectation(description: "text")
        client.onText = { textExpectation.fulfill() }
        DispatchQueue.global().async {
            backend.onOutput?(Array("hello\u{1B}]0;title\u{07}\u{07}".utf8))
        }
        wait(for: [textExpectation], timeout: 5)
        client.onText = nil
        XCTAssertEqual("hello", session.emulator?.screen.transcriptText)
        XCTAssertEqual("title", session.title)
        XCTAssertEqual(["title"], client.titles)
        XCTAssertEqual(1, client.bells)

        session.updateSize(columns: 30, rows: 5, cellWidthPixels: 10, cellHeightPixels: 20)
        XCTAssertEqual(30, backend.resized?.0)
        XCTAssertEqual(30, session.emulator?.columns)

        let finishExpectation = expectation(description: "finish")
        client.onFinish = { finishExpectation.fulfill() }
        DispatchQueue.global().async {
            backend.onExit?(3)
        }
        wait(for: [finishExpectation], timeout: 5)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(3, session.exitStatus)
        XCTAssertEqual(-1, session.pid)
        XCTAssertEqual(1, client.finished)
        XCTAssertEqual("hello\n[Process completed (code 3) - press Enter]", session.emulator?.screen.transcriptText)

        // Writes after exit are dropped:
        backend.written.removeAll()
        session.write("x")
        XCTAssertTrue(backend.written.isEmpty)
    }

    func testFinishIfRunning() {
        let backend = MockBackend()
        let client = MockClient()
        let session = TerminalSession(backend: backend, transcriptRows: 500, client: client)
        session.updateSize(columns: 40, rows: 3, cellWidthPixels: 10, cellHeightPixels: 20)
        let finishExpectation = expectation(description: "finish")
        client.onFinish = { finishExpectation.fulfill() }
        session.finishIfRunning()
        XCTAssertTrue(backend.terminated)
        wait(for: [finishExpectation], timeout: 5)
        XCTAssertEqual("[Process completed (signal 9) - press Enter]", session.emulator?.screen.transcriptText)
    }

    func testSixelIsConsumed() {
        withTerminalSized(10, 3).enterString("A\u{1B}Pq\"1;1;4;4#0;2;100;0;0#0~~~~-~~~~\u{1B}\\B").assertLinesAre("AB        ", "          ", "          ")
        withTerminalSized(10, 3).enterString("A\u{1B}P0;0;0q#1!10~$-#2??\r\n??\u{1B}\\B").assertLinesAre("AB        ", "          ", "          ")
    }

    func testITermImageIsConsumed() {
        let data = String(repeating: "QUJD", count: 5000)
        withTerminalSized(10, 3).enterString("A\u{1B}]1337;File=inline=1;size=15000:" + data + "\r\n" + data + "\u{07}B")
            .assertLinesAre("AB        ", "          ", "          ")
        withTerminalSized(10, 3).enterString("A\u{1B}]1337;MultipartFile=inline=1:\u{07}\u{1B}]1337;FilePart=" + data + "\u{07}\u{1B}]1337;FileEnd\u{07}B")
            .assertLinesAre("AB        ", "          ", "          ")
        assertEnteringStringGivesResponse("\u{1B}]1337;ReportCellSize\u{07}", "\u{1B}]1337;ReportCellSize=15;13\u{07}")
    }
}

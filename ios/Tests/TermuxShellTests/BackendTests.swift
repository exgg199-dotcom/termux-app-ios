import XCTest
@testable import TermuxShell

/// Collects backend output thread-safely and lets tests wait for text.
final class OutputCollector {
    private let condition = NSCondition()
    private var data: [UInt8] = []
    private(set) var exitCode: Int32?

    func append(_ bytes: [UInt8]) { condition.lock(); data += bytes; condition.broadcast(); condition.unlock() }
    func exited(_ code: Int32) { condition.lock(); exitCode = code; condition.broadcast(); condition.unlock() }

    var text: String { condition.lock(); defer { condition.unlock() }; return String(decoding: data, as: UTF8.self) }

    @discardableResult
    func wait(for substring: String, after offset: Int = 0, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        while true {
            let s = String(decoding: data, as: UTF8.self)
            if s.count >= offset, s.dropFirst(offset).contains(substring) { return true }
            if !condition.wait(until: deadline) { return false }
        }
    }

    func waitForExit(timeout: TimeInterval = 5) -> Int32? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        while exitCode == nil { if !condition.wait(until: deadline) { break } }
        return exitCode
    }
}

let promptEnd = "$\u{1B}[0m "

final class BuiltinShellBackendTests: XCTestCase {
    var home: URL!
    var backend: BuiltinShellBackend!
    var output: OutputCollector!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("backend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        backend?.terminate()
        try? FileManager.default.removeItem(at: home)
    }

    private func startBackend(welcome: Bool = false) {
        backend = BuiltinShellBackend(homeDirectory: home)
        backend.showsWelcome = welcome
        output = OutputCollector()
        backend.onOutput = { [output] in output!.append($0) }
        backend.onExit = { [output] in output!.exited($0) }
        backend.start(columns: 80, rows: 24, cellWidthPixels: 10, cellHeightPixels: 20)
        XCTAssertTrue(output.wait(for: promptEnd), output.text)
    }

    private func type(_ s: String) { backend.write(Array(s.utf8)) }

    func testPromptAndEcho() {
        startBackend()
        XCTAssertTrue(output.text.contains("\u{1B}[0;32m~\u{1B}[0m \u{1B}[0;97m$\u{1B}[0m "))
        let before = output.text.count
        type("echo hello\r")
        XCTAssertTrue(output.wait(for: "hello\r\n", after: before + 12), output.text)
        XCTAssertTrue(output.wait(for: promptEnd, after: before + 12))
    }

    func testOutputUsesCRLF() {
        startBackend()
        type("printf 'a\\nb\\n'\r")
        XCTAssertTrue(output.wait(for: "a\r\nb\r\n"), output.text)
    }

    func testWelcomeMessage() {
        startBackend(welcome: true)
        XCTAssertTrue(output.text.contains("Welcome to Termux"))
    }

    func testExitCallsOnExit() {
        startBackend()
        type("exit 7\r")
        XCTAssertEqual(output.waitForExit(), 7)
    }

    func testCtrlDOnEmptyLineExits() {
        startBackend()
        backend.write([0x04])
        XCTAssertEqual(output.waitForExit(), 0)
    }

    func testCtrlCInterruptsRunningCommand() {
        startBackend()
        type("sleep 30; echo done\r")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(backend.isRunningCommand)
        let start = Date()
        backend.write([0x03])
        XCTAssertTrue(output.wait(for: "^C\r\n"))
        let promptOffset = output.text.count
        XCTAssertTrue(output.wait(for: promptEnd, after: promptOffset - 5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let afterInterrupt = output.text.components(separatedBy: "^C").last ?? ""
        XCTAssertFalse(afterInterrupt.contains("done"))
    }

    func testCtrlCStopsYes() {
        startBackend()
        type("yes\r")
        XCTAssertTrue(output.wait(for: "y\r\ny\r\n"))
        backend.write([0x03])
        XCTAssertTrue(output.wait(for: "^C\r\n"))
        let deadline = Date(timeIntervalSinceNow: 5)
        while backend.isRunningCommand && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(backend.isRunningCommand)
    }

    func testInteractiveStdinCat() {
        startBackend()
        type("cat\r")
        Thread.sleep(forTimeInterval: 0.2)
        let offset = output.text.count
        type("typed line\r")
        // Echo by the line discipline, then cat's output.
        XCTAssertTrue(output.wait(for: "typed line\r\ntyped line\r\n", after: offset), output.text)
        backend.write([0x04])
        XCTAssertTrue(output.wait(for: promptEnd, after: offset))
    }

    func testTypeaheadIsKept() {
        startBackend()
        type("sleep 0.3\r")
        type("echo later\r")
        XCTAssertTrue(output.wait(for: "later\r\n"), output.text)
    }

    func testContinuationPrompt() {
        startBackend()
        type("echo 'a\r")
        XCTAssertTrue(output.wait(for: "> "))
        type("b'\r")
        XCTAssertTrue(output.wait(for: "a\r\nb\r\n"), output.text)
    }

    func testProfileIsLoadedAndHistorySaved() throws {
        try "export FROM_PROFILE=yes\nalias greet='echo hi'\n".write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        startBackend()
        type("echo $FROM_PROFILE; greet\r")
        XCTAssertTrue(output.wait(for: "yes\r\nhi\r\n"), output.text)
        let deadline = Date(timeIntervalSinceNow: 2)
        var history = ""
        while Date() < deadline {
            history = (try? String(contentsOf: home.appendingPathComponent(".termux_history"), encoding: .utf8)) ?? ""
            if !history.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(history, "echo $FROM_PROFILE; greet\n")
    }

    func testResizeAffectsLs() throws {
        for i in 0..<12 { FileManager.default.createFile(atPath: home.appendingPathComponent("file\(i)").path, contents: nil) }
        startBackend()
        backend.resize(columns: 200, rows: 24, cellWidthPixels: 10, cellHeightPixels: 20)
        var offset = output.text.count
        type("ls\r")
        XCTAssertTrue(output.wait(for: promptEnd, after: offset + 5))
        let wide = output.text.dropFirst(offset)
        backend.resize(columns: 20, rows: 24, cellWidthPixels: 10, cellHeightPixels: 20)
        offset = output.text.count
        type("ls\r")
        XCTAssertTrue(output.wait(for: promptEnd, after: offset + 5))
        let narrow = output.text.dropFirst(offset)
        XCTAssertLessThan(wide.components(separatedBy: "\r\n").count, narrow.components(separatedBy: "\r\n").count)
    }

    func testTerminateCallsOnExit() {
        startBackend()
        type("sleep 30\r")
        backend.terminate()
        XCTAssertEqual(output.waitForExit(), -9)
    }

    func testPid() {
        XCTAssertEqual(BuiltinShellBackend(homeDirectory: home).pid, -1)
    }
}

#if !os(iOS)
final class PTYProcessBackendTests: XCTestCase {
    func testEchoThroughPty() {
        let backend = PTYProcessBackend(executable: "/bin/echo", arguments: ["hello", "pty"], environment: ["TERM=xterm-256color"],
                                        workingDirectory: NSTemporaryDirectory())
        let output = OutputCollector()
        backend.onOutput = { output.append($0) }
        backend.onExit = { output.exited($0) }
        backend.start(columns: 80, rows: 24, cellWidthPixels: 10, cellHeightPixels: 20)
        XCTAssertGreaterThan(backend.pid, 0)
        XCTAssertEqual(output.waitForExit(), 0)
        XCTAssertTrue(output.wait(for: "hello pty\r\n"), output.text)
    }

    func testWindowSizeAndWorkingDirectory() {
        let backend = PTYProcessBackend(executable: "/bin/sh", arguments: ["-c", "stty size; pwd; exit 3"],
                                        environment: ["PATH=/usr/bin:/bin"], workingDirectory: "/")
        let output = OutputCollector()
        backend.onOutput = { output.append($0) }
        backend.onExit = { output.exited($0) }
        backend.start(columns: 100, rows: 30, cellWidthPixels: 10, cellHeightPixels: 20)
        XCTAssertEqual(output.waitForExit(), 3)
        XCTAssertTrue(output.wait(for: "30 100"), output.text)
        XCTAssertTrue(output.wait(for: "/\r\n"), output.text)
    }

    func testInputAndTerminate() {
        let backend = PTYProcessBackend(executable: "/bin/cat", arguments: [], environment: [], workingDirectory: "/")
        let output = OutputCollector()
        backend.onOutput = { output.append($0) }
        backend.onExit = { output.exited($0) }
        backend.start(columns: 80, rows: 24, cellWidthPixels: 10, cellHeightPixels: 20)
        backend.write(Array("ping\r".utf8))
        XCTAssertTrue(output.wait(for: "ping\r\nping\r\n"), output.text)
        backend.terminate()
        XCTAssertEqual(output.waitForExit(), -9)
    }

    func testMissingExecutable() {
        let backend = PTYProcessBackend(executable: "/nonexistent/program", arguments: [], environment: [], workingDirectory: "/")
        let output = OutputCollector()
        backend.onOutput = { output.append($0) }
        backend.onExit = { output.exited($0) }
        backend.start(columns: 80, rows: 24, cellWidthPixels: 10, cellHeightPixels: 20)
        XCTAssertNotNil(output.waitForExit())
        XCTAssertNotEqual(output.exitCode, 0)
    }
}
#endif

import XCTest
import WAT
import TermuxShell
@testable import TermuxWasm

final class WasmProgramRunnerTests: XCTestCase {
    var home: String!
    var shell: ShellInterpreter!

    static let header = """
    (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
    (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
    (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
    """

    override func setUpWithError() throws {
        home = ShellPath.normalize(NSTemporaryDirectory() + "termux-wasm-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        shell = ShellInterpreter(homeDirectory: home, environment: ["USER": "tester", "TMPDIR": home + "/missing"])
        shell.programRunner = WasmProgramRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    static func module(_ body: String, imports: String = "") -> String {
        "(module \(header) \(imports) (memory (export \"memory\") 1) \(body))"
    }

    func install(_ name: String, imports: String = "", _ body: String) throws {
        let bytes = try wat2wasm(WasmProgramRunnerTests.module(body, imports: imports))
        try installBytes(name, bytes)
    }

    func installBytes(_ name: String, _ bytes: [UInt8]) throws {
        let path = home + "/bin/" + name
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    static let hello = """
    (data (i32.const 16) "hello\\n")
    (func (export "_start")
      (i32.store (i32.const 0) (i32.const 16))
      (i32.store (i32.const 4) (i32.const 6))
      (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8))))
    """

    static let echo = """
    (func (export "_start") (local $count i32)
      (block $done
        (loop $again
          (i32.store (i32.const 0) (i32.const 64))
          (i32.store (i32.const 4) (i32.const 1024))
          (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))
          (local.set $count (i32.load (i32.const 8)))
          (br_if $done (i32.eqz (local.get $count)))
          (i32.store (i32.const 16) (i32.const 64))
          (i32.store (i32.const 20) (local.get $count))
          (drop (call $fd_write (i32.const 1) (i32.const 16) (i32.const 1) (i32.const 24)))
          (br $again))))
    """

    func testHelloWorld() throws {
        try install("hello", WasmProgramRunnerTests.hello)
        let result = shell.runCapturing("hello")
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.status, 0)
    }

    func testExitCode() throws {
        try install("exit-three", "(func (export \"_start\") (call $proc_exit (i32.const 3)))")
        XCTAssertEqual(shell.runCapturing("exit-three").status, 3)
        XCTAssertEqual(shell.runCapturing("exit-three || echo failed").stdout, "failed\n")
    }

    func testStandardInputEcho() throws {
        try install("echo-program", WasmProgramRunnerTests.echo)
        XCTAssertEqual(shell.runCapturing("echo-program", stdin: "abc\n").stdout, "abc\n")
        XCTAssertEqual(shell.runCapturing("echo hi | echo-program").stdout, "hi\n")
        XCTAssertEqual(shell.runCapturing("echo-program < /dev/null").stdout, "")
    }

    func testStandardError() throws {
        try install("complain", """
        (data (i32.const 16) "oops\\n")
        (func (export "_start")
          (i32.store (i32.const 0) (i32.const 16))
          (i32.store (i32.const 4) (i32.const 5))
          (drop (call $fd_write (i32.const 2) (i32.const 0) (i32.const 1) (i32.const 8))))
        """)
        let result = shell.runCapturing("complain")
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "oops\n")
        XCTAssertEqual(shell.runCapturing("complain 2>&1").stdout, "oops\n")
    }

    func testArgumentCount() throws {
        try install("count-arguments", imports: #"(import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))"#, """
        (func (export "_start")
          (drop (call $args_sizes_get (i32.const 0) (i32.const 4)))
          (call $proc_exit (i32.load (i32.const 0))))
        """)
        XCTAssertEqual(shell.runCapturing("count-arguments a b").status, 3)
        XCTAssertEqual(shell.runCapturing("count-arguments").status, 1)
    }

    func testEnvironmentPrefixReachesProgram() throws {
        try install("count-environment", imports: #"(import "wasi_snapshot_preview1" "environ_sizes_get" (func $environ_sizes_get (param i32 i32) (result i32)))"#, """
        (func (export "_start")
          (drop (call $environ_sizes_get (i32.const 0) (i32.const 4)))
          (call $proc_exit (i32.load (i32.const 0))))
        """)
        let base = shell.runCapturing("count-environment").status
        XCTAssertEqual(shell.runCapturing("NEW_VARIABLE=1 count-environment").status, base + 1)
    }

    func testFileAccessThroughPreopen() throws {
        try install("write-file", imports: #"(import "wasi_snapshot_preview1" "path_open" (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))"#, """
        (data (i32.const 100) "out.txt")
        (data (i32.const 200) "written\\n")
        (func (export "_start") (local $status i32)
          (local.set $status (call $path_open (i32.const 3) (i32.const 0) (i32.const 100) (i32.const 7)
            (i32.const 9) (i64.const 0x1fffffff) (i64.const 0) (i32.const 0) (i32.const 300)))
          (if (local.get $status) (then (call $proc_exit (local.get $status))))
          (i32.store (i32.const 0) (i32.const 200))
          (i32.store (i32.const 4) (i32.const 8))
          (drop (call $fd_write (i32.load (i32.const 300)) (i32.const 0) (i32.const 1) (i32.const 8))))
        """)
        let result = shell.runCapturing("write-file")
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(FileManager.default.contents(atPath: home + "/out.txt").map { String(decoding: $0, as: UTF8.self) }, "written\n")
    }

    func testCurrentDirectoryAliasDescriptor() throws {
        try install("write-here", imports: #"(import "wasi_snapshot_preview1" "path_open" (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))"#, """
        (data (i32.const 100) "here.txt")
        (data (i32.const 200) "here\\n")
        (func (export "_start") (local $status i32)
          (local.set $status (call $path_open (i32.const -2) (i32.const 0) (i32.const 100) (i32.const 8)
            (i32.const 9) (i64.const 0x1fffffff) (i64.const 0) (i32.const 0) (i32.const 300)))
          (if (local.get $status) (then (call $proc_exit (local.get $status))))
          (i32.store (i32.const 0) (i32.const 200))
          (i32.store (i32.const 4) (i32.const 5))
          (drop (call $fd_write (i32.load (i32.const 300)) (i32.const 0) (i32.const 1) (i32.const 8))))
        """)
        try FileManager.default.createDirectory(atPath: home + "/work", withIntermediateDirectories: true)
        let result = shell.runCapturing("cd work && write-here")
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(FileManager.default.contents(atPath: home + "/work/here.txt").map { String(decoding: $0, as: UTF8.self) }, "here\n")
    }

    func testCancellationStopsWritingLoop() throws {
        try install("spin", """
        (data (i32.const 16) "x")
        (func (export "_start")
          (i32.store (i32.const 0) (i32.const 16))
          (i32.store (i32.const 4) (i32.const 1))
          (loop $again
            (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
            (br $again)))
        """)
        let token = CancellationToken()
        let output = BufferOutputStream()
        let errors = BufferOutputStream()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
        let start = Date()
        let status = shell.run("spin", streams: StandardStreams(stdin: EmptyInputStream(), stdout: output, stderr: errors), cancellation: token)
        XCTAssertEqual(status, 130)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(output.bytes.isEmpty)
    }

    func testClockPollSleepsAndIsInterruptible() throws {
        try install("nap", imports: #"(import "wasi_snapshot_preview1" "poll_oneoff" (func $poll_oneoff (param i32 i32 i32 i32) (result i32)))"#, """
        (func (export "_start")
          (i64.store (i32.const 0) (i64.const 7))
          (i32.store8 (i32.const 8) (i32.const 0))
          (i32.store (i32.const 16) (i32.const 1))
          (i64.store (i32.const 24) (i64.const 200000000))
          (i32.store16 (i32.const 40) (i32.const 0))
          (call $proc_exit (call $poll_oneoff (i32.const 0) (i32.const 64) (i32.const 1) (i32.const 128))))
        """)
        let start = Date()
        XCTAssertEqual(shell.runCapturing("nap").status, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.19)
    }

    func testUnknownImportIsStubbed() throws {
        try install("system-call", imports: #"(import "wasi_snapshot_preview1" "ashell_system" (func $system (param i32) (result i32)))"#, """
        (func (export "_start")
          (call $proc_exit (call $system (i32.const 0))))
        """)
        XCTAssertEqual(shell.runCapturing("system-call").status, -1)
    }

    func testOutOfBoundsVectorReturnsFault() throws {
        try install("bad-pointer", """
        (func (export "_start")
          (i32.store (i32.const 0) (i32.const 0x7ffffff0))
          (i32.store (i32.const 4) (i32.const 16))
          (call $proc_exit (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8))))
        """)
        XCTAssertEqual(shell.runCapturing("bad-pointer").status, 21)
    }

    func testTrap() throws {
        try install("crash", "(func (export \"_start\") unreachable)")
        let result = shell.runCapturing("crash")
        XCTAssertEqual(result.status, 134)
        XCTAssertTrue(result.stderr.contains("crash: WebAssembly trap"), result.stderr)
    }

    func testInvalidModule() throws {
        try installBytes("broken", [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        let result = shell.runCapturing("broken")
        XCTAssertEqual(result.status, 126)
        XCTAssertTrue(result.stderr.contains("not a valid WebAssembly program"), result.stderr)
    }

    func testComponentIsRejected() throws {
        try installBytes("component", [0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00])
        let result = shell.runCapturing("component")
        XCTAssertEqual(result.status, 126)
        XCTAssertTrue(result.stderr.contains("WASI preview 2"), result.stderr)
    }

    func testWasmSuffixAndRelativePath() throws {
        let bytes = try wat2wasm(WasmProgramRunnerTests.module(WasmProgramRunnerTests.hello))
        FileManager.default.createFile(atPath: home + "/bin/greet.wasm", contents: Data(bytes))
        XCTAssertEqual(shell.runCapturing("greet").stdout, "hello\n")
        FileManager.default.createFile(atPath: home + "/local.wasm", contents: Data(bytes))
        XCTAssertEqual(shell.runCapturing("./local.wasm").stdout, "hello\n")
    }

    func testModuleCacheReusesModule() throws {
        try install("hello", WasmProgramRunnerTests.hello)
        for _ in 0..<3 { XCTAssertEqual(shell.runCapturing("hello").stdout, "hello\n") }
    }
}

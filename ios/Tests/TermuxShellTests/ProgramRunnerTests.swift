import XCTest
@testable import TermuxShell

final class FakeProgramRunner: ProgramRunner {
    var paths: [String] = []
    var argumentVectors: [[String]] = []
    var environments: [[String: String]] = []

    func run(programAt path: String, context: CommandContext) -> Int32 {
        paths.append(path)
        argumentVectors.append(context.argumentVector)
        environments.append(context.environment)
        context.print("ran \(context.name)")
        return 42
    }
}

final class ProgramRunnerTests: ShellTestCase {
    var runner: FakeProgramRunner!
    let webAssemblyHeader: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

    override func setUpWithError() throws {
        try super.setUpWithError()
        runner = FakeProgramRunner()
        shell.programRunner = runner
    }

    func writeProgram(_ name: String, executable: Bool) throws {
        let path = home + "/" + name
        try FileManager.default.createDirectory(atPath: ShellPath.dirname(path), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(webAssemblyHeader))
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
    }

    func testRunsWebAssemblyFromPath() throws {
        try writeProgram("bin/tool", executable: true)
        let result = run("tool a b")
        XCTAssertEqual(result.status, 42)
        XCTAssertEqual(result.stdout, "ran tool\n")
        XCTAssertEqual(runner.argumentVectors, [["tool", "a", "b"]])
        XCTAssertEqual(runner.paths, [home + "/bin/tool"])
    }

    func testWasmSuffixIsOptional() throws {
        try writeProgram("bin/tool.wasm", executable: false)
        XCTAssertEqual(run("tool").status, 42)
        XCTAssertEqual(runner.paths, [home + "/bin/tool.wasm"])
        XCTAssertEqual(out("which tool"), home + "/bin/tool.wasm\n")
    }

    func testRelativeWasmFileWithoutExecutableBit() throws {
        try writeProgram("x.wasm", executable: false)
        XCTAssertEqual(run("./x.wasm").status, 42)
        XCTAssertEqual(runner.argumentVectors, [["./x.wasm"]])
    }

    func testWithoutRunner() throws {
        shell.programRunner = nil
        try writeProgram("bin/tool", executable: true)
        let result = run("tool")
        XCTAssertEqual(result.status, 126)
        XCTAssertEqual(result.stderr, "sh: tool: cannot execute WebAssembly program: no WebAssembly runtime in this build\n")
    }

    func testEnvironmentPrefixReachesProgram() throws {
        try writeProgram("bin/tool", executable: true)
        XCTAssertEqual(run("FOO=1 tool").status, 42)
        XCTAssertEqual(runner.environments.first?["FOO"], "1")
        XCTAssertNil(shell.variable("FOO"))
    }

    func testRunnerIsInheritedBySubshells() throws {
        try writeProgram("bin/tool", executable: true)
        XCTAssertEqual(out("(tool)"), "ran tool\n")
        XCTAssertEqual(out("echo $(tool)"), "ran tool\n")
    }

    func testEnvironmentPrefixReachesScripts() throws {
        write("bin/show", "echo $GREETING\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/bin/show")
        XCTAssertEqual(out("GREETING=hi show"), "hi\n")
    }

    func testNativeBinaryMessage() throws {
        let path = home + "/bin/native"
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let result = run("native")
        XCTAssertEqual(result.status, 126)
        XCTAssertTrue(result.stderr.contains("native Linux/Android programs cannot run on iOS"), result.stderr)
    }
}

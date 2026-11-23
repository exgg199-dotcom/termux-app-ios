import XCTest
import TermuxShell
@testable import TermuxWasm

final class RealPackageTests: XCTestCase {
    static let enabled = ProcessInfo.processInfo.environment["TERMUX_NETWORK_TESTS"] == "1"
    static let indexURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../packages/index.json").standardizedFileURL

    var home: String!
    var shell: ShellInterpreter!

    override func setUpWithError() throws {
        try XCTSkipUnless(RealPackageTests.enabled, "set TERMUX_NETWORK_TESTS=1 to download and run the real packages")
        home = ShellPath.normalize(NSTemporaryDirectory() + "termux-real-packages-" + UUID().uuidString)
        let prefix = home + "/usr"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let layout = PackageLayout(prefix: prefix)
        try layout.createDirectories()
        try Data((RealPackageTests.indexURL.absoluteString + "\n").utf8).write(to: URL(fileURLWithPath: layout.sourcesFile))
        shell = ShellInterpreter(homeDirectory: home, environment: [
            "PREFIX": prefix,
            "PATH": prefix + "/bin:" + home + "/bin",
            "TMPDIR": layout.temporaryDirectory,
        ])
        shell.programRunner = WasmProgramRunner()
    }

    override func tearDownWithError() throws {
        if let home = home { try? FileManager.default.removeItem(atPath: home) }
    }

    @discardableResult
    func install(_ package: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let result = shell.runCapturing("pkg install \(package)")
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr, file: file, line: line)
        return result.status == 0
    }

    func check(_ command: String, stdin: String = "", expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = shell.runCapturing(command, stdin: stdin)
        XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)", file: file, line: line)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expected, "\(command): \(result.stderr)", file: file, line: line)
    }

    func testQuickJavaScript() {
        guard install("quickjs") else { return }
        check("qjs -e 'console.log(6*7)'", expected: "42")
    }

    func testPython() {
        guard install("python") else { return }
        check("python3 -c 'print(6*7)'", expected: "42")
        check("python3 -", stdin: "print(6*7)\n", expected: "42")
        check("python3 -c \"open('t.txt','w').write('x')\" && cat t.txt", expected: "x")
    }

    func testRuby() {
        guard install("ruby") else { return }
        check("ruby -e 'puts 6*7'", expected: "42")
    }

    func testPhp() {
        guard install("php") else { return }
        FileManager.default.createFile(atPath: home + "/answer.php", contents: Data("<?php echo 6*7;".utf8))
        check("php-cgi -q answer.php", expected: "42")
    }

    func testXz() {
        guard install("xz-utils") else { return }
        XCTAssertEqual(shell.runCapturing("xz --version").status, 0)
        FileManager.default.createFile(atPath: home + "/data.txt", contents: Data("compress me\n".utf8))
        check("xz data.txt && unxz data.txt.xz && cat data.txt", expected: "compress me")
    }

    func testSqlite() {
        guard install("sqlite") else { return }
        check("printf 'select 6*7;' | sqlite3", expected: "42")
    }

    func testZipRoundTrip() {
        guard install("zip"), install("unzip") else { return }
        FileManager.default.createFile(atPath: home + "/note.txt", contents: Data("zipped\n".utf8))
        let zip = shell.runCapturing("zip archive.zip note.txt")
        XCTAssertEqual(zip.status, 0, zip.stdout + zip.stderr)
        check("rm note.txt && unzip archive.zip >/dev/null && cat note.txt", expected: "zipped")
    }
}

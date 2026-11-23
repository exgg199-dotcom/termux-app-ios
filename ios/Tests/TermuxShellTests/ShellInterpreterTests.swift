import XCTest
@testable import TermuxShell

class ShellTestCase: XCTestCase {
    var home: String!
    var shell: ShellInterpreter!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "termux-shell-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        home = ShellPath.normalize(home)
        shell = ShellInterpreter(homeDirectory: home, environment: ["USER": "tester"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    @discardableResult
    func run(_ source: String, stdin: String = "") -> (status: Int32, stdout: String, stderr: String) {
        shell.runCapturing(source, stdin: stdin)
    }

    func out(_ source: String, stdin: String = "", file: StaticString = #filePath, line: UInt = #line) -> String {
        let r = run(source, stdin: stdin)
        XCTAssertEqual(r.stderr, "", "stderr of `\(source)`", file: file, line: line)
        return r.stdout
    }

    func write(_ name: String, _ content: String) {
        let path = home + "/" + name
        try? FileManager.default.createDirectory(atPath: ShellPath.dirname(path), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(content.utf8))
    }

    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: home + "/" + name).map { String(decoding: $0, as: UTF8.self) }
    }
}

final class ShellInterpreterTests: ShellTestCase {
    func testEcho() {
        XCTAssertEqual(out("echo hello world"), "hello world\n")
        XCTAssertEqual(out("echo -n hi"), "hi")
        XCTAssertEqual(out(#"echo -e 'a\tb\nc'"#), "a\tb\nc\n")
        XCTAssertEqual(out(#"echo 'a\tb'"#), "a\\tb\n")
    }

    func testQuotingAndSplitting() {
        XCTAssertEqual(out("echo 'a   b'   c"), "a   b c\n")
        XCTAssertEqual(out(#"X="1  2"; echo $X; echo "$X""#), "1 2\n1  2\n")
        XCTAssertEqual(out(#"printf '%s|' $(echo a b c); echo"#), "a|b|c|\n")
        XCTAssertEqual(out(#"printf '%s|' "$(echo a b c)"; echo"#), "a b c|\n")
        XCTAssertEqual(out(#"echo "\$HOME" \\ "a\"b""#), "$HOME \\ a\"b\n")
    }

    func testVariables() {
        XCTAssertEqual(out("FOO=bar; echo $FOO ${FOO}x \"$FOO\""), "bar barx bar\n")
        XCTAssertEqual(out("echo ${UNSET:-default} ${UNSET-d2} [${UNSET}]"), "default d2 []\n")
        XCTAssertEqual(out("X=abc; echo ${#X} ${X:+set}"), "3 set\n")
        XCTAssertEqual(out("F=archive.tar.gz; echo ${F%.gz} ${F%%.*} ${F#*.} ${F##*.}"), "archive.tar archive tar.gz gz\n")
        XCTAssertEqual(out("echo $HOME"), home + "\n")
        XCTAssertEqual(out("A=1 env | grep '^A='"), "A=1\n")
        XCTAssertEqual(out("echo [$A]"), "[]\n", "per-command assignment must not leak")
        XCTAssertEqual(out("export B=2; echo $B; unset B; echo [$B]"), "2\n[]\n")
    }

    func testExitStatusVariable() {
        XCTAssertEqual(out("false; echo $?; true; echo $?"), "1\n0\n")
        XCTAssertEqual(out("! false; echo $?"), "0\n")
    }

    func testTildeExpansion() {
        XCTAssertEqual(out("echo ~ ~/x '~'"), "\(home!) \(home!)/x ~\n")
    }

    func testArithmetic() {
        XCTAssertEqual(out("echo $((1 + 2 * 3)) $(( (1+2)*3 )) $((10 / 3)) $((10 % 3)) $((2 ** 10))"), "7 9 3 1 1024\n")
        XCTAssertEqual(out("X=5; echo $((X + 1)) $(($X * 2)); Y=$((X > 3 ? 1 : 0)); echo $Y"), "6 10\n1\n")
        XCTAssertEqual(out("i=0; : $((i += 5)); echo $i"), "5\n")
    }

    func testAndOr() {
        XCTAssertEqual(out("true && echo yes || echo no"), "yes\n")
        XCTAssertEqual(out("false && echo yes || echo no"), "no\n")
        XCTAssertEqual(out("false || false || echo third"), "third\n")
        XCTAssertEqual(out("true || echo skipped; echo after"), "after\n")
    }

    func testPipes() {
        XCTAssertEqual(out("printf 'c\\nb\\na\\n' | sort"), "a\nb\nc\n")
        XCTAssertEqual(out("echo hello | tr a-z A-Z | rev"), "OLLEH\n")
        XCTAssertEqual(out("yes | head -n 3"), "y\ny\ny\n")
        XCTAssertEqual(out("seq 1 100000 | tail -n 1"), "100000\n")
        XCTAssertEqual(out("printf 'a\\nb\\n' | wc -l"), "2\n")
    }

    func testRedirections() {
        run("echo one > f.txt; echo two >> f.txt")
        XCTAssertEqual(read("f.txt"), "one\ntwo\n")
        XCTAssertEqual(out("cat < f.txt"), "one\ntwo\n")
        let r = run("ls /nonexistent-dir 2>&1")
        XCTAssertTrue(r.stdout.contains("No such file or directory"))
        XCTAssertEqual(r.stderr, "")
        run("ls /nonexistent-dir 2> err.txt")
        XCTAssertTrue(read("err.txt")?.contains("cannot access") ?? false)
        run("echo x > /dev/null")
        XCTAssertEqual(out("cat <<< 'here string'"), "here string\n")
        run("(echo a; echo b) > sub.txt")
        XCTAssertEqual(read("sub.txt"), "a\nb\n")
        run("{ echo nope; } 2>/dev/null; echo both &> both.txt")
        XCTAssertEqual(read("both.txt"), "both\n")
    }

    func testRedirectionErrors() {
        let r = run("echo x > nodir/file")
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.stderr.contains("No such file or directory"))
        let r2 = run("cat < missing")
        XCTAssertEqual(r2.status, 1)
    }

    func testCommandNotFound() {
        let r = run("definitely-not-a-command")
        XCTAssertEqual(r.status, 127)
        XCTAssertEqual(r.stderr, "sh: definitely-not-a-command: command not found\n")
    }

    func testGlobbing() {
        write("a.txt", ""); write("b.txt", ""); write("c.md", ""); write(".hidden.txt", "")
        XCTAssertEqual(out("echo *.txt"), "a.txt b.txt\n")
        XCTAssertEqual(out("echo ?.md"), "c.md\n")
        XCTAssertEqual(out("echo [ab].txt"), "a.txt b.txt\n")
        XCTAssertEqual(out("echo '*.txt' \\*.txt"), "*.txt *.txt\n")
        XCTAssertEqual(out("echo *.none"), "*.none\n")
        XCTAssertEqual(out("echo .*.txt"), ".hidden.txt\n")
        write("dir/x.swift", ""); write("dir/y.swift", "")
        XCTAssertEqual(out("echo dir/*.swift"), "dir/x.swift dir/y.swift\n")
        XCTAssertEqual(out("echo \(home!)/dir/x*"), "\(home!)/dir/x.swift\n")
        XCTAssertEqual(out("echo */"), "dir/\n")
    }

    func testCommandSubstitution() {
        XCTAssertEqual(out("echo \"[$(echo hi)]\" `echo there`"), "[hi] there\n")
        XCTAssertEqual(out("X=$(printf 'a\\n\\n'); echo \"$X|\""), "a|\n")
        XCTAssertEqual(out("cd /; echo $(pwd); pwd"), "/\n/\n")
    }

    func testSubshellIsolation() {
        XCTAssertEqual(out("(cd /; X=1); pwd; echo [$X]"), home + "\n[]\n")
    }

    func testAliases() {
        run("alias hi='echo hello'")
        XCTAssertEqual(out("hi there"), "hello there\n")
        XCTAssertEqual(out("alias"), "alias hi='echo hello'\n")
        XCTAssertEqual(out("unalias hi; alias"), "")
    }

    func testCdAndPwd() throws {
        try FileManager.default.createDirectory(atPath: home + "/sub/deeper", withIntermediateDirectories: true)
        XCTAssertEqual(out("cd sub/deeper; pwd"), home + "/sub/deeper\n")
        XCTAssertEqual(out("cd ..; pwd"), home + "/sub\n")
        XCTAssertEqual(out("cd -"), home + "/sub/deeper\n")
        XCTAssertEqual(out("cd; pwd"), home + "\n")
        let r = run("cd nope")
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.stderr, "cd: nope: No such file or directory\n")
        XCTAssertEqual(out("cd /; pwd"), "/\n")
    }

    func testExit() {
        let r = run("echo a; exit 3; echo b")
        XCTAssertEqual(r.stdout, "a\n")
        XCTAssertEqual(shell.exitRequested, 3)
    }

    func testSourceAndScripts() throws {
        write("lib.sh", "GREETING=hello\nsay() { :; }\n".replacingOccurrences(of: "say() { :; }\n", with: ""))
        XCTAssertEqual(out(". ./lib.sh; echo $GREETING"), "hello\n")
        write("script.sh", "#!/bin/sh\necho \"args: $# $1 $2\"\necho $0\n")
        XCTAssertEqual(out("sh_status=1; ./script.sh x y"), "args: 2 x y\n./script.sh\n")
        write("bin/hello", "echo hi from path\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/bin/hello")
        XCTAssertEqual(out("hello"), "hi from path\n")
        write("prog.py", "#!/usr/bin/env python3\nprint(1)\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/prog.py")
        let r = run("./prog.py")
        XCTAssertEqual(r.status, 126)
        XCTAssertTrue(r.stderr.contains("python3"))
    }

    func testSyntaxErrorReported() {
        let r = run("echo ;; echo")
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.stderr.contains("syntax error"))
    }

    func testCancellationStopsSleep() {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        let start = Date()
        let status = shell.run("sleep 10; echo not reached", streams: StandardStreams(stdin: EmptyInputStream(), stdout: BufferOutputStream(), stderr: BufferOutputStream()), cancellation: token)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(status, 130)
    }

    func testCancellationStopsYes() {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        let out = BufferOutputStream()
        let status = shell.run("yes", streams: StandardStreams(stdin: EmptyInputStream(), stdout: NullOutputStream(), stderr: out), cancellation: token)
        XCTAssertEqual(status, 130)
    }

    func testPrompt() {
        XCTAssertEqual(shell.prompt(), "\u{1B}[0;32m~\u{1B}[0m \u{1B}[0;97m$\u{1B}[0m ")
        run("mkdir -p a/b; cd a/b")
        XCTAssertTrue(shell.prompt().contains("~/a/b"))
        run("PS1='\\W> '")
        XCTAssertEqual(shell.prompt(), "b> ")
    }

    func testCompletion() throws {
        write("alpha.txt", ""); write("alpine.txt", ""); try FileManager.default.createDirectory(atPath: home + "/my dir", withIntermediateDirectories: true)
        var c = shell.complete("ech")
        XCTAssertEqual(c.candidates, ["echo"])
        XCTAssertEqual(c.wordStart, 0)
        c = shell.complete("cat al")
        XCTAssertEqual(c.candidates, ["alpha.txt", "alpine.txt"])
        XCTAssertEqual(c.wordStart, 4)
        c = shell.complete("cd my")
        XCTAssertEqual(c.candidates, ["my\\ dir/"])
        c = shell.complete("ls | gre")
        XCTAssertEqual(c.candidates, ["grep"])
        c = shell.complete("cat ~/alph")
        XCTAssertEqual(c.candidates, ["~/alpha.txt"])
    }

    func testHistoryPersistence() {
        let file = home + "/.termux_history"
        let h = ShellHistory(file: file)
        h.add("ls -l")
        h.add("ls -l")
        h.add(" secret")
        h.add("pwd")
        XCTAssertEqual(h.all, ["ls -l", "pwd"])
        XCTAssertEqual(ShellHistory(file: file).all, ["ls -l", "pwd"])
    }

    func testStdinFromCaller() {
        XCTAssertEqual(out("cat", stdin: "piped\n"), "piped\n")
        XCTAssertEqual(out("read A B; echo \"$B-$A\"", stdin: "one two three\n"), "two three-one\n")
    }
}

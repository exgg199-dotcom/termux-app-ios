import XCTest
@testable import TermuxShell

final class BuiltinCommandTests: ShellTestCase {
    func testMkdirTouchLsRm() {
        XCTAssertEqual(run("mkdir a/b").status, 1)
        XCTAssertEqual(out("mkdir -p a/b && touch a/f1 a/f2 && ls a"), "b\nf1\nf2\n")
        XCTAssertEqual(out("ls -1 a"), "b\nf1\nf2\n")
        let r = run("rm a")
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.stderr, "rm: cannot remove 'a': Is a directory\n")
        XCTAssertEqual(out("rm -rf a; ls"), "")
        XCTAssertEqual(run("rm missing").status, 1)
        XCTAssertEqual(run("rm -f missing").status, 0)
    }

    func testLsHiddenAndLong() {
        write(".dot", ""); write("file", "12345")
        XCTAssertEqual(out("ls"), "file\n")
        XCTAssertEqual(out("ls -a"), ".\n..\n.dot\nfile\n")
        XCTAssertEqual(out("ls -A"), ".dot\nfile\n")
        let long = out("ls -l file")
        XCTAssertTrue(long.hasPrefix("-rw"), long)
        XCTAssertTrue(long.contains(" 5 "), long)
        XCTAssertTrue(long.hasSuffix(" file\n"), long)
        write("big", String(repeating: "x", count: 2048))
        XCTAssertTrue(out("ls -lh big").contains("2.0K"))
    }

    func testLsColumnsAndColorsOnTerminal() {
        for n in ["one", "two", "three", "four"] { write(n, "") }
        try? FileManager.default.createDirectory(atPath: home + "/dir", withIntermediateDirectories: true)
        let terminal = BufferOutputStream(isTerminal: true)
        shell.terminalColumns = 80
        shell.run("ls", streams: StandardStreams(stdin: EmptyInputStream(), stdout: terminal, stderr: terminal))
        let s = terminal.string
        XCTAssertTrue(s.contains("\u{1B}[1;34mdir\u{1B}[0m"), s)
        XCTAssertEqual(s.split(separator: "\n").count, 1, "should fit in one row: \(s)")
        terminal.clear()
        shell.terminalColumns = 10
        shell.run("ls", streams: StandardStreams(stdin: EmptyInputStream(), stdout: terminal, stderr: terminal))
        XCTAssertGreaterThan(terminal.string.split(separator: "\n").count, 1)
    }

    func testCatAndNumbers() {
        write("x", "a\nb\n")
        XCTAssertEqual(out("cat x x"), "a\nb\na\nb\n")
        XCTAssertEqual(out("cat -n x"), "     1\ta\n     2\tb\n")
        XCTAssertEqual(run("cat nofile").stderr, "cat: nofile: No such file or directory\n")
    }

    func testCpMvLn() {
        write("src/f", "data")
        XCTAssertEqual(run("cp src dst").status, 1)
        XCTAssertEqual(out("cp -r src dst && cat dst/f"), "data")
        XCTAssertEqual(out("cp src/f copy && cat copy"), "data")
        XCTAssertEqual(out("mv copy moved && ls"), "dst\nmoved\nsrc\n")
        XCTAssertEqual(out("mkdir d2; mv moved d2; ls d2"), "moved\n")
        XCTAssertEqual(out("ln -s src/f link && cat link"), "data")
        XCTAssertTrue(out("ls -l link").contains("link -> src/f"))
    }

    func testHeadTailWc() {
        run("seq 1 20 > n")
        XCTAssertEqual(out("head -n 3 n"), "1\n2\n3\n")
        XCTAssertEqual(out("head -2 n"), "1\n2\n")
        XCTAssertEqual(out("tail -n 2 n"), "19\n20\n")
        XCTAssertEqual(out("tail -n +19 n"), "19\n20\n")
        XCTAssertEqual(out("head -c 3 n"), "1\n2")
        XCTAssertEqual(out("wc -l n"), "20 n\n")
        XCTAssertEqual(out("echo 'a b c' | wc -w"), "3\n")
        XCTAssertEqual(out("printf 'ab' | wc -c"), "2\n")
    }

    func testGrep() {
        write("g.txt", "Apple\nbanana\ncherry\napple pie\n")
        XCTAssertEqual(out("grep apple g.txt"), "apple pie\n")
        XCTAssertEqual(out("grep -i apple g.txt"), "Apple\napple pie\n")
        XCTAssertEqual(out("grep -v a g.txt"), "Apple\ncherry\n")
        XCTAssertEqual(out("grep -n an g.txt"), "2:banana\n")
        XCTAssertEqual(out("grep -c a g.txt"), "2\n")
        XCTAssertEqual(out("grep -E '^(b|c)' g.txt"), "banana\ncherry\n")
        XCTAssertEqual(out("grep '^\\(b\\|c\\)' g.txt"), "banana\ncherry\n")
        XCTAssertEqual(out("grep -o 'an' g.txt"), "an\nan\n")
        XCTAssertEqual(run("grep zzz g.txt").status, 1)
        write("sub/one.txt", "needle\n"); write("sub/two.txt", "hay\n")
        XCTAssertEqual(out("grep -r needle sub"), "sub/one.txt:needle\n")
        XCTAssertEqual(out("grep -rl needle ."), "./sub/one.txt\n")
        XCTAssertEqual(out("cd sub; grep -rl needle"), "one.txt\n")
        XCTAssertEqual(out("echo 'a.b' | grep -F ."), "a.b\n")
    }

    func testSortUniqCutTr() {
        XCTAssertEqual(out("printf '10\\n9\\n100\\n' | sort -n"), "9\n10\n100\n")
        XCTAssertEqual(out("printf 'b\\na\\nc\\n' | sort -r"), "c\nb\na\n")
        XCTAssertEqual(out("printf 'a\\na\\nb\\na\\n' | uniq -c"), "      2 a\n      1 b\n      1 a\n")
        XCTAssertEqual(out("printf 'a\\nb\\na\\n' | sort -u"), "a\nb\n")
        XCTAssertEqual(out("echo 'a:b:c:d' | cut -d: -f2,4"), "b:d\n")
        XCTAssertEqual(out("echo 'a:b:c:d' | cut -d: -f2-"), "b:c:d\n")
        XCTAssertEqual(out("echo hello | cut -c1-3"), "hel\n")
        XCTAssertEqual(out("echo hello | tr el ip"), "hippo\n")
        XCTAssertEqual(out("echo hello | tr -d l"), "heo\n")
        XCTAssertEqual(out("echo 'aaabbb' | tr -s ab"), "ab\n")
        XCTAssertEqual(out("echo Hello | tr '[:lower:]' '[:upper:]'"), "HELLO\n")
        XCTAssertEqual(out("printf 'b 2\\na 1\\n' | sort -k 2"), "a 1\nb 2\n")
    }

    func testSed() {
        XCTAssertEqual(out("echo hello world | sed s/o/0/"), "hell0 world\n")
        XCTAssertEqual(out("echo hello world | sed 's/o/0/g'"), "hell0 w0rld\n")
        XCTAssertEqual(out("echo 'a-b' | sed 's|-|/|'"), "a/b\n")
        XCTAssertEqual(out("echo 'John Smith' | sed -E 's/(\\w+) (\\w+)/\\2, \\1/'"), "Smith, John\n")
        XCTAssertEqual(out("echo 'John Smith' | sed 's/\\(J[a-z]*\\)/[&]/'"), "[John] Smith\n")
        XCTAssertEqual(out("echo 'cost $5' | sed 's/\\$5/five/'"), "cost five\n")
        XCTAssertEqual(out("printf '1\\n2\\n3\\n' | sed -n 2p"), "2\n")
        XCTAssertEqual(out("printf '1\\n2\\n3\\n' | sed 2d"), "1\n3\n")
        write("edit.txt", "foo\nbar\n")
        run("sed -i 's/foo/baz/' edit.txt")
        XCTAssertEqual(read("edit.txt"), "baz\nbar\n")
    }

    func testFindDuTree() {
        write("p/a.swift", "x"); write("p/q/b.swift", "y"); write("p/q/c.txt", "z")
        XCTAssertEqual(out("find p -name '*.swift'"), "p/a.swift\np/q/b.swift\n")
        XCTAssertEqual(out("find p -type d"), "p\np/q\n")
        XCTAssertEqual(out("find p -maxdepth 1 -type f"), "p/a.swift\n")
        XCTAssertTrue(out("du -sh p").hasSuffix("\tp\n"))
        XCTAssertEqual(out("tree p"), "p\n├── a.swift\n└── q\n    ├── b.swift\n    └── c.txt\n\n1 directory, 3 files\n")
    }

    func testStatChmodTest() {
        write("s", "abc")
        XCTAssertTrue(out("stat s").contains("Size: 3"))
        XCTAssertEqual(out("chmod 700 s; stat -c %a s"), "700\n")
        XCTAssertEqual(out("chmod g+r,o+r s; stat -c %a s"), "744\n")
        XCTAssertEqual(out("chmod u-x s; stat -c %A s"), "-rw-r--r--\n")
        XCTAssertEqual(out("test -f s && echo file; [ -d s ] || echo notdir; [ -e nope ] || echo missing"), "file\nnotdir\nmissing\n")
        XCTAssertEqual(out("[ 3 -gt 2 ] && echo gt; [ abc = abc ] && echo eq; [ -z '' ] && echo empty; [ ! -n '' ] && echo neg"), "gt\neq\nempty\nneg\n")
        XCTAssertEqual(out("[ 1 -eq 1 -a 2 -eq 3 ] || echo and; [ 1 -eq 1 -o 2 -eq 3 ] && echo or"), "and\nor\n")
    }

    func testBasenameDirnameRealpath() {
        XCTAssertEqual(out("basename /a/b/c.txt .txt; dirname /a/b/c.txt; dirname file; basename /"), "c\n/a/b\n.\n/\n")
        XCTAssertEqual(out("mkdir x; realpath x"), URL(fileURLWithPath: home + "/x").resolvingSymlinksInPath().path + "\n")
    }

    func testPrintfAndSeq() {
        XCTAssertEqual(out("printf '%s=%d\\n' a 1 b 2"), "a=1\nb=2\n")
        XCTAssertEqual(out("printf '%5s|%-5s|%03d|%.2f|%x\\n' ab cd 7 3.14159 255"), "   ab|cd   |007|3.14|ff\n")
        XCTAssertEqual(out("seq 3"), "1\n2\n3\n")
        XCTAssertEqual(out("seq 2 2 6"), "2\n4\n6\n")
        XCTAssertEqual(out("seq -s, 1 3"), "1,2,3\n")
        XCTAssertEqual(out("seq 3 -1 1"), "3\n2\n1\n")
    }

    func testEnvExportHistoryType() {
        XCTAssertTrue(out("env").contains("HOME=\(home!)\n"))
        XCTAssertEqual(out("env X=1 printenv X"), "1\n")
        XCTAssertEqual(out("type cd"), "cd is a shell builtin\n")
        run("alias ll='ls -l'")
        XCTAssertEqual(out("type ll"), "ll is aliased to `ls -l'\n")
        XCTAssertEqual(run("which nope").status, 1)
        shell.history.add("first"); shell.history.add("second")
        XCTAssertEqual(out("history"), "    1  first\n    2  second\n")
    }

    func testSystemInfoCommands() {
        XCTAssertFalse(out("whoami").isEmpty)
        XCTAssertFalse(out("hostname").isEmpty)
        #if os(Linux)
        XCTAssertEqual(out("uname"), "Linux\n")
        XCTAssertTrue(out("uname -a").hasSuffix("GNU/Linux\n"))
        #endif
        XCTAssertTrue(out("id").hasPrefix("uid="))
        XCTAssertTrue(out("uptime").contains("up"))
        XCTAssertEqual(out("date -u -d @0 +%Y-%m-%dT%H:%M:%S"), "1970-01-01T00:00:00\n")
        XCTAssertTrue(out("df").contains("Filesystem"))
    }

    func testHashesAndEncoding() {
        XCTAssertEqual(out("printf 'abc' | md5sum"), "900150983cd24fb0d6963f7d28e17f72  -\n")
        XCTAssertEqual(out("printf 'abc' | sha1sum"), "a9993e364706816aba3e25717850c26c9cd0d89d  -\n")
        XCTAssertEqual(out("printf 'abc' | sha256sum"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -\n")
        XCTAssertEqual(out("printf '' | sha256sum"), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -\n")
        XCTAssertEqual(out("echo hello | base64"), "aGVsbG8K\n")
        XCTAssertEqual(out("echo aGVsbG8K | base64 -d"), "hello\n")
        XCTAssertEqual(out("printf 'Hi\\n' | xxd"), "00000000: 4869 0a                                  Hi.\n")
        XCTAssertEqual(out("printf 'Hi' | xxd -p"), "4869\n")
        XCTAssertEqual(out("printf 'Hi' | hexdump -C"), "00000000  48 69                                             |Hi|\n00000002\n")
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(Hashing.hex(Hashing.md5(Array(long.utf8))), "cabe45dcc9ae5b66ba86600cca6b8ba8")
    }

    func testHelpListsCommands() {
        let h = out("help")
        for c in ["ls", "grep", "sed", "curl", "exit"] { XCTAssertTrue(h.contains("  \(c) "), c) }
    }

    func testXargsAndTee() {
        write("t1", ""); write("t2", "")
        XCTAssertEqual(out("printf 't1\\nt2\\n' | xargs rm; ls"), "")
        XCTAssertEqual(out("echo hi | tee copy.txt"), "hi\n")
        XCTAssertEqual(read("copy.txt"), "hi\n")
    }

    func testCustomCommandRegistration() {
        struct Hello: ShellCommand {
            let name = "hello"
            let summary = "say hello"
            func run(_ context: CommandContext) -> Int32 {
                context.print("Hello, \(context.arguments.first ?? "world")!")
                return 0
            }
        }
        shell.registry.register(Hello())
        XCTAssertEqual(out("hello there | tr a-z A-Z"), "HELLO, THERE!\n")
    }
}

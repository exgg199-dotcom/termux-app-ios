import XCTest
@testable import TermuxShell

final class ShellSyntaxTests: XCTestCase {
    private func words(_ source: String) throws -> [ShellWord] {
        try ShellLexer.tokenize(source).compactMap { if case .word(let w) = $0 { return w }; return nil }
    }

    private func simple(_ list: CommandList, _ i: Int = 0) -> SimpleCommand? {
        guard i < list.items.count, case .simple(let c) = list.items[i].first.commands[0] else { return nil }
        return c
    }

    func testPlainWords() throws {
        let w = try words("ls -la  /tmp")
        XCTAssertEqual(w.map { $0.plainLiteral }, ["ls", "-la", "/tmp"])
    }

    func testSingleAndDoubleQuotes() throws {
        let w = try words(#"echo 'a b' "c d" e\ f"#)
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w[1].parts, [.quoted("a b")])
        XCTAssertEqual(w[2].parts, [.quoted("c d")])
        XCTAssertEqual(w[3].parts, [.literal("e"), .quoted(" f")])
    }

    func testEmptyQuotesProduceWord() throws {
        let w = try words("echo '' \"\"")
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[1].parts, [.quoted("")])
        XCTAssertEqual(w[2].parts, [.quoted("")])
    }

    func testVariables() throws {
        let w = try words(#"echo $HOME ${USER} "x${A:-def}y" $? $1"#)
        XCTAssertEqual(w[1].parts, [.parameter(ParameterExpansion(name: "HOME"), quoted: false)])
        XCTAssertEqual(w[2].parts, [.parameter(ParameterExpansion(name: "USER"), quoted: false)])
        XCTAssertEqual(w[3].parts, [.quoted("x"), .parameter(ParameterExpansion(name: "A", op: ":-", argument: "def"), quoted: true), .quoted("y")])
        XCTAssertEqual(w[4].parts, [.parameter(ParameterExpansion(name: "?"), quoted: false)])
        XCTAssertEqual(w[5].parts, [.parameter(ParameterExpansion(name: "1"), quoted: false)])
    }

    func testSingleQuotesPreventExpansion() throws {
        let w = try words("echo '$HOME'")
        XCTAssertEqual(w[1].parts, [.quoted("$HOME")])
    }

    func testCommandSubstitutionAndArithmetic() throws {
        let w = try words("echo $(ls -1 | wc -l) `pwd` $((1 + 2))")
        XCTAssertEqual(w[1].parts, [.command("ls -1 | wc -l", quoted: false)])
        XCTAssertEqual(w[2].parts, [.command("pwd", quoted: false)])
        XCTAssertEqual(w[3].parts, [.arithmetic("1 + 2", quoted: false)])
    }

    func testOperators() throws {
        let t = try ShellLexer.tokenize("a && b || c; d | e")
        XCTAssertEqual(t.filter { if case .op = $0 { return true }; return false }, [.op("&&"), .op("||"), .op(";"), .op("|")])
    }

    func testRedirections() throws {
        let list = try ShellParser.parse("cmd > out.txt 2>&1 < in.txt >> log")
        let c = try XCTUnwrap(simple(list))
        XCTAssertEqual(c.words.map { $0.plainLiteral }, ["cmd"])
        XCTAssertEqual(c.redirections.map { $0.op }, [.output, .duplicateOutput, .input, .append])
        XCTAssertEqual(c.redirections.map { $0.fd }, [1, 2, 0, 1])
        XCTAssertEqual(c.redirections.map { $0.target.plainLiteral }, ["out.txt", "1", "in.txt", "log"])
    }

    func testDigitsNotFollowedByRedirectAreWords() throws {
        let c = try XCTUnwrap(simple(try ShellParser.parse("echo 2 3>x")))
        XCTAssertEqual(c.words.map { $0.plainLiteral }, ["echo", "2"])
        XCTAssertEqual(c.redirections.first?.fd, 3)
    }

    func testPipelineAndAndOr() throws {
        let list = try ShellParser.parse("a | b | c && d || e; f")
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].first.commands.count, 3)
        XCTAssertEqual(list.items[0].rest.map { $0.0 }, [.and, .or])
    }

    func testAssignments() throws {
        let c = try XCTUnwrap(simple(try ShellParser.parse("A=1 B=\"x y\" env")))
        XCTAssertEqual(c.assignments.map { $0.name }, ["A", "B"])
        XCTAssertEqual(c.words.map { $0.plainLiteral }, ["env"])
    }

    func testComments() throws {
        let list = try ShellParser.parse("echo hi # comment\n# whole line\necho there")
        XCTAssertEqual(list.items.count, 2)
    }

    func testSubshell() throws {
        let list = try ShellParser.parse("(cd /; pwd) > x")
        guard case .subshell(let inner, let redirs) = list.items[0].first.commands[0] else { return XCTFail() }
        XCTAssertEqual(inner.items.count, 2)
        XCTAssertEqual(redirs.count, 1)
    }

    func testIncompleteInput() {
        for src in ["echo 'abc", "echo \"abc", "ls |", "true &&", "echo \\", "echo $(ls", "(echo"] {
            XCTAssertThrowsError(try ShellParser.parse(src), src) { XCTAssertEqual($0 as? ShellSyntaxError, .incomplete, src) }
        }
    }

    func testSyntaxErrors() {
        XCTAssertThrowsError(try ShellParser.parse("| ls")) { XCTAssertEqual($0 as? ShellSyntaxError, .unexpected("|")) }
        XCTAssertThrowsError(try ShellParser.parse("ls ;; ls"))
        XCTAssertThrowsError(try ShellParser.parse("echo >"))
    }

    func testAliasExpansion() throws {
        let list = try ShellParser.parse("ll /tmp", aliases: ["ll": "ls -l", "ls": "ls --color"])
        let c = try XCTUnwrap(simple(list))
        XCTAssertEqual(c.words.map { $0.plainLiteral }, ["ls", "--color", "-l", "/tmp"])
    }

    func testAliasWithPipe() throws {
        let list = try ShellParser.parse("countfiles", aliases: ["countfiles": "ls | wc -l"])
        XCTAssertEqual(list.items[0].first.commands.count, 2)
    }
}

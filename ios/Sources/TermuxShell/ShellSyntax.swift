import Foundation

public struct ParameterExpansion: Equatable {
    public var name: String
    public var operation: String?
    public var argument: String?
    public var length: Bool
    public init(name: String, operation: String? = nil, argument: String? = nil, length: Bool = false) {
        self.name = name; self.operation = operation; self.argument = argument; self.length = length
    }
}

public enum WordPart: Equatable {
    case literal(String)
    case quoted(String)
    case parameter(ParameterExpansion, quoted: Bool)
    case command(String, quoted: Bool)
    case arithmetic(String, quoted: Bool)
}

public struct ShellWord: Equatable {
    public var parts: [WordPart]
    public init(_ parts: [WordPart]) { self.parts = parts }

    public var plainLiteral: String? {
        if parts.count == 1, case .literal(let s) = parts[0] { return s }
        return nil
    }
}

public enum RedirectionOperator: String, Equatable {
    case output = ">", append = ">>", input = "<", duplicateOutput = ">&", duplicateInput = "<&"
    case outputBoth = "&>", appendBoth = "&>>", hereString = "<<<"
}

public struct Redirection: Equatable {
    public var fileDescriptor: Int
    public var operation: RedirectionOperator
    public var target: ShellWord
}

public struct Assignment: Equatable {
    public var name: String
    public var value: ShellWord
}

public struct SimpleCommand: Equatable {
    public var assignments: [Assignment] = []
    public var words: [ShellWord] = []
    public var redirections: [Redirection] = []
}

public indirect enum CommandNode: Equatable {
    case simple(SimpleCommand)
    case subshell(CommandList, [Redirection])
}

public struct Pipeline: Equatable {
    public var negated = false
    public var commands: [CommandNode] = []
}

public enum AndOrOperator: String, Equatable { case and = "&&", or = "||" }

public struct AndOrList: Equatable {
    public var first: Pipeline
    public var rest: [(AndOrOperator, Pipeline)] = []
    public static func == (a: AndOrList, b: AndOrList) -> Bool {
        a.first == b.first && a.rest.count == b.rest.count && zip(a.rest, b.rest).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public struct CommandList: Equatable {
    public var items: [AndOrList] = []
}

public enum ShellSyntaxError: Error, Equatable, CustomStringConvertible {
    case incomplete
    case unexpected(String)

    public var description: String {
        switch self {
        case .incomplete: return "syntax error: unexpected end of file"
        case .unexpected(let t): return "syntax error near unexpected token `\(t)'"
        }
    }
}

public enum ShellToken: Equatable {
    case word(ShellWord)
    case controlOperator(String)
    case redirect(Int?, RedirectionOperator)
    case newline
}

public struct ShellLexer {
    private let s: [Unicode.Scalar]
    private var i = 0

    public init(_ source: String) { s = Array(source.unicodeScalars) }

    public static func tokenize(_ source: String) throws -> [ShellToken] {
        var lexer = ShellLexer(source)
        return try lexer.tokens()
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let j = i + offset
        return j < s.count ? s[j] : nil
    }

    private static func isMeta(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case " ", "\t", "\n", ";", "&", "|", "<", ">", "(", ")": return true
        default: return false
        }
    }

    public mutating func tokens() throws -> [ShellToken] {
        var out: [ShellToken] = []
        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\r" { i += 1; continue }
            if c == "\\" && peek(1) == "\n" { i += 2; continue }
            if c == "#" {
                while i < s.count && s[i] != "\n" { i += 1 }
                continue
            }
            if c == "\n" { out.append(.newline); i += 1; continue }
            if let (fileDescriptor, operation) = readRedirect(fileDescriptor: nil) { out.append(.redirect(fileDescriptor, operation)); continue }
            if let operation = readOperator() { out.append(.controlOperator(operation)); continue }
            let word = try readWord()
            if let literalText = word.plainLiteral, !literalText.isEmpty, literalText.allSatisfy({ $0.isASCII && $0.isNumber }),
               let fileDescriptor = Int(literalText), let (_, operation) = readRedirect(fileDescriptor: fileDescriptor) {
                out.append(.redirect(fileDescriptor, operation))
                continue
            }
            out.append(.word(word))
        }
        return out
    }

    private mutating func readRedirect(fileDescriptor: Int?) -> (Int?, RedirectionOperator)? {
        func match(_ text: String) -> Bool {
            let scalars = Array(text.unicodeScalars)
            for (k, scalar) in scalars.enumerated() where peek(k) != scalar { return false }
            return true
        }
        let candidates: [(String, RedirectionOperator)] = fileDescriptor == nil
            ? [("&>>", .appendBoth), ("&>", .outputBoth), ("<<<", .hereString), (">>", .append), (">&", .duplicateOutput),
               ("<&", .duplicateInput), (">|", .output), (">", .output), ("<", .input)]
            : [("<<<", .hereString), (">>", .append), (">&", .duplicateOutput), ("<&", .duplicateInput), (">|", .output), (">", .output), ("<", .input)]
        for (text, operation) in candidates where match(text) {
            i += text.unicodeScalars.count
            return (fileDescriptor, operation)
        }
        return nil
    }

    private mutating func readOperator() -> String? {
        guard let c = peek() else { return nil }
        let n = peek(1)
        switch c {
        case "&": if n == "&" { i += 2; return "&&" }; i += 1; return "&"
        case "|": if n == "|" { i += 2; return "||" }; i += 1; return "|"
        case ";": i += 1; return ";"
        case "(": i += 1; return "("
        case ")": i += 1; return ")"
        default: return nil
        }
    }

    private mutating func readWord() throws -> ShellWord {
        var parts: [WordPart] = []
        var literal = ""
        var quoted = ""
        func flushLiteral() { if !literal.isEmpty { parts.append(.literal(literal)); literal = "" } }
        func flushQuoted() { if !quoted.isEmpty { parts.append(.quoted(quoted)); quoted = "" } }
        func flush() { flushLiteral(); flushQuoted() }

        while i < s.count {
            let c = s[i]
            if ShellLexer.isMeta(c) { break }
            switch c {
            case "\\":
                guard let next = peek(1) else { throw ShellSyntaxError.incomplete }
                i += 2
                if next == "\n" { continue }
                flushLiteral(); quoted.unicodeScalars.append(next)
            case "'":
                i += 1
                flushLiteral()
                var text = ""
                while true {
                    guard i < s.count else { throw ShellSyntaxError.incomplete }
                    if s[i] == "'" { i += 1; break }
                    text.unicodeScalars.append(s[i]); i += 1
                }
                quoted += text
                if quoted.isEmpty { parts.append(.quoted("")) }
            case "\"":
                i += 1
                flushLiteral()
                let before = parts.count
                try readDoubleQuoted(into: &parts, quoted: &quoted)
                if quoted.isEmpty && parts.count == before { parts.append(.quoted("")) }
            case "$":
                if let part = try readDollar(quoted: false) { flush(); parts.append(part) } else { flushQuoted(); literal.append("$") }
            case "`":
                flush()
                parts.append(.command(try readBackquote(), quoted: false))
            default:
                flushQuoted()
                literal.unicodeScalars.append(c); i += 1
            }
        }
        flush()
        return ShellWord(parts)
    }

    private mutating func readDoubleQuoted(into parts: inout [WordPart], quoted: inout String) throws {
        while true {
            guard i < s.count else { throw ShellSyntaxError.incomplete }
            let c = s[i]
            switch c {
            case "\"":
                i += 1
                return
            case "\\":
                guard let next = peek(1) else { throw ShellSyntaxError.incomplete }
                if next == "$" || next == "`" || next == "\"" || next == "\\" {
                    quoted.unicodeScalars.append(next); i += 2
                } else if next == "\n" {
                    i += 2
                } else {
                    quoted.append("\\"); i += 1
                }
            case "$":
                if let part = try readDollar(quoted: true) {
                    if !quoted.isEmpty { parts.append(.quoted(quoted)); quoted = "" }
                    parts.append(part)
                } else {
                    quoted.append("$")
                }
            case "`":
                if !quoted.isEmpty { parts.append(.quoted(quoted)); quoted = "" }
                parts.append(.command(try readBackquote(), quoted: true))
            default:
                quoted.unicodeScalars.append(c); i += 1
            }
        }
    }

    private mutating func readBackquote() throws -> String {
        i += 1
        var text = ""
        while true {
            guard i < s.count else { throw ShellSyntaxError.incomplete }
            let c = s[i]
            if c == "`" { i += 1; return text }
            if c == "\\", let n = peek(1), n == "`" || n == "\\" || n == "$" { text.unicodeScalars.append(n); i += 2; continue }
            text.unicodeScalars.append(c); i += 1
        }
    }

    private static func isNameStart(_ c: Unicode.Scalar) -> Bool { c == "_" || (c.isASCII && CharacterSet.letters.contains(c)) }
    private static func isNameChar(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || ("0"..."9").contains(c) }

    private mutating func readDollar(quoted: Bool) throws -> WordPart? {
        guard let n = peek(1) else { i += 1; return nil }
        if n == "{" {
            i += 2
            var content = ""
            var depth = 0
            while true {
                guard i < s.count else { throw ShellSyntaxError.incomplete }
                let c = s[i]
                if c == "}" && depth == 0 { i += 1; break }
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1 }
                if c == "\\", let nextScalar = peek(1) { content.unicodeScalars.append(c); content.unicodeScalars.append(nextScalar); i += 2; continue }
                content.unicodeScalars.append(c); i += 1
            }
            return .parameter(try ShellLexer.parseBraced(content), quoted: quoted)
        }
        if n == "(" {
            if peek(2) == "(" {
                i += 3
                var depth = 0
                var text = ""
                while true {
                    guard i < s.count else { throw ShellSyntaxError.incomplete }
                    let c = s[i]
                    if c == ")" && depth == 0 && peek(1) == ")" { i += 2; break }
                    if c == "(" { depth += 1 }
                    if c == ")" { depth -= 1 }
                    text.unicodeScalars.append(c); i += 1
                }
                return .arithmetic(text, quoted: quoted)
            }
            i += 2
            return .command(try readUntilMatchingParen(), quoted: quoted)
        }
        if "?$#!@*-0123456789".unicodeScalars.contains(n) {
            i += 2
            return .parameter(ParameterExpansion(name: String(n)), quoted: quoted)
        }
        if ShellLexer.isNameStart(n) {
            i += 1
            var name = ""
            while let c = peek(), ShellLexer.isNameChar(c) { name.unicodeScalars.append(c); i += 1 }
            return .parameter(ParameterExpansion(name: name), quoted: quoted)
        }
        i += 1
        return nil
    }

    private mutating func readUntilMatchingParen() throws -> String {
        var depth = 0
        var text = ""
        while true {
            guard i < s.count else { throw ShellSyntaxError.incomplete }
            let c = s[i]
            switch c {
            case "(":
                depth += 1
            case ")":
                if depth == 0 { i += 1; return text }
                depth -= 1
            case "'":
                text.unicodeScalars.append(c); i += 1
                while i < s.count && s[i] != "'" { text.unicodeScalars.append(s[i]); i += 1 }
                guard i < s.count else { throw ShellSyntaxError.incomplete }
            case "\"":
                text.unicodeScalars.append(c); i += 1
                while i < s.count && s[i] != "\"" {
                    if s[i] == "\\" && i + 1 < s.count { text.unicodeScalars.append(s[i]); i += 1 }
                    text.unicodeScalars.append(s[i]); i += 1
                }
                guard i < s.count else { throw ShellSyntaxError.incomplete }
            case "\\":
                if i + 1 < s.count { text.unicodeScalars.append(c); i += 1 }
            default:
                break
            }
            text.unicodeScalars.append(s[i]); i += 1
        }
    }

    static func parseBraced(_ content: String) throws -> ParameterExpansion {
        var scalars = Array(content.unicodeScalars)
        var length = false
        if scalars.first == "#" && scalars.count > 1 { length = true; scalars.removeFirst() }
        var name = ""
        var k = 0
        if let f = scalars.first, ("0"..."9").contains(f) {
            while k < scalars.count, ("0"..."9").contains(scalars[k]) { name.unicodeScalars.append(scalars[k]); k += 1 }
        } else if let f = scalars.first, "?$#!@*-".unicodeScalars.contains(f) {
            name = String(f); k = 1
        } else {
            while k < scalars.count, isNameChar(scalars[k]) { name.unicodeScalars.append(scalars[k]); k += 1 }
        }
        if name.isEmpty { throw ShellSyntaxError.unexpected("${\(content)}: bad substitution") }
        if length {
            guard k == scalars.count else { throw ShellSyntaxError.unexpected("${\(content)}: bad substitution") }
            return ParameterExpansion(name: name, length: true)
        }
        if k == scalars.count { return ParameterExpansion(name: name) }
        let rest = String(String.UnicodeScalarView(scalars[k...]))
        for operation in [":-", ":=", ":+", ":?", "##", "%%", "-", "=", "+", "?", "#", "%"] where rest.hasPrefix(operation) {
            return ParameterExpansion(name: name, operation: operation, argument: String(rest.dropFirst(operation.count)))
        }
        throw ShellSyntaxError.unexpected("${\(content)}: bad substitution")
    }
}

public struct ShellParser {
    private var tokens: [ShellToken]
    private var position = 0
    private let aliases: [String: String]

    public init(tokens: [ShellToken], aliases: [String: String] = [:]) {
        self.tokens = tokens
        self.aliases = aliases
    }

    public static func parse(_ source: String, aliases: [String: String] = [:]) throws -> CommandList {
        var parser = ShellParser(tokens: try ShellLexer.tokenize(source), aliases: aliases)
        return try parser.parseProgram()
    }

    private var atEnd: Bool { position >= tokens.count }
    private func peek() -> ShellToken? { position < tokens.count ? tokens[position] : nil }
    private func peekOperation() -> String? { if case .controlOperator(let o)? = peek() { return o }; return nil }

    private static func describe(_ t: ShellToken?) -> String {
        switch t {
        case .controlOperator(let o)?: return o
        case .redirect(_, let r)?: return r.rawValue
        case .newline?, nil: return "newline"
        case .word(let w)?: return w.plainLiteral ?? "word"
        }
    }

    public mutating func parseProgram() throws -> CommandList {
        let list = try parseList(endAt: nil)
        if !atEnd { throw ShellSyntaxError.unexpected(ShellParser.describe(peek())) }
        return list
    }

    private mutating func skipNewlines() { while case .newline? = peek() { position += 1 } }

    private mutating func parseList(endAt: String?) throws -> CommandList {
        var list = CommandList()
        while true {
            skipNewlines()
            if atEnd { break }
            if let end = endAt, peekOperation() == end { break }
            if peekOperation() == ";" || peekOperation() == "&" {
                throw ShellSyntaxError.unexpected(peekOperation()!)
            }
            list.items.append(try parseAndOr())
            if let operation = peekOperation(), operation == ";" || operation == "&" { position += 1; continue }
            if case .newline? = peek() { position += 1; continue }
            if atEnd { break }
            if let end = endAt, peekOperation() == end { break }
            throw ShellSyntaxError.unexpected(ShellParser.describe(peek()))
        }
        return list
    }

    private mutating func parseAndOr() throws -> AndOrList {
        var result = AndOrList(first: try parsePipeline())
        while let operation = peekOperation(), operation == "&&" || operation == "||" {
            position += 1
            skipNewlines()
            if atEnd { throw ShellSyntaxError.incomplete }
            result.rest.append((operation == "&&" ? .and : .or, try parsePipeline()))
        }
        return result
    }

    private mutating func parsePipeline() throws -> Pipeline {
        var p = Pipeline()
        if case .word(let w)? = peek(), w.plainLiteral == "!" { p.negated = true; position += 1 }
        p.commands.append(try parseCommand())
        while peekOperation() == "|" {
            position += 1
            skipNewlines()
            if atEnd { throw ShellSyntaxError.incomplete }
            p.commands.append(try parseCommand())
        }
        return p
    }

    private mutating func parseCommand() throws -> CommandNode {
        if peekOperation() == "(" {
            position += 1
            let list = try parseList(endAt: ")")
            if atEnd { throw ShellSyntaxError.incomplete }
            guard peekOperation() == ")" else { throw ShellSyntaxError.unexpected(ShellParser.describe(peek())) }
            position += 1
            var redirs: [Redirection] = []
            while case .redirect(let fileDescriptor, let operation)? = peek() {
                position += 1
                redirs.append(try parseRedirectTarget(fileDescriptor: fileDescriptor, operation: operation))
            }
            return .subshell(list, redirs)
        }
        return .simple(try parseSimple())
    }

    private mutating func parseRedirectTarget(fileDescriptor: Int?, operation: RedirectionOperator) throws -> Redirection {
        guard case .word(let target)? = peek() else { throw ShellSyntaxError.unexpected(ShellParser.describe(peek())) }
        position += 1
        let defaultFd: Int
        switch operation {
        case .input, .duplicateInput, .hereString: defaultFd = 0
        default: defaultFd = 1
        }
        return Redirection(fileDescriptor: fileDescriptor ?? defaultFd, operation: operation, target: target)
    }

    private static func assignment(from word: ShellWord) -> Assignment? {
        guard case .literal(let first)? = word.parts.first, let eq = first.firstIndex(of: "=") else { return nil }
        let name = String(first[first.startIndex..<eq])
        guard let f = name.unicodeScalars.first, f == "_" || (f.isASCII && CharacterSet.letters.contains(f)),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }) else { return nil }
        var valueParts = Array(word.parts.dropFirst())
        let rest = String(first[first.index(after: eq)...])
        if !rest.isEmpty { valueParts.insert(.literal(rest), at: 0) }
        return Assignment(name: name, value: ShellWord(valueParts))
    }

    private mutating func expandAlias() throws {
        var used = Set<String>()
        while case .word(let w)? = peek(), let name = w.plainLiteral, !used.contains(name), let value = aliases[name] {
            used.insert(name)
            let replacement = try ShellLexer.tokenize(value)
            tokens.replaceSubrange(position..<(position + 1), with: replacement)
            if replacement.isEmpty { break }
        }
    }

    private mutating func parseSimple() throws -> SimpleCommand {
        try expandAlias()
        var command = SimpleCommand()
        loop: while let t = peek() {
            switch t {
            case .word(let w):
                position += 1
                if command.words.isEmpty, let a = ShellParser.assignment(from: w) {
                    command.assignments.append(a)
                    try expandAlias()
                } else {
                    command.words.append(w)
                }
            case .redirect(let fileDescriptor, let operation):
                position += 1
                command.redirections.append(try parseRedirectTarget(fileDescriptor: fileDescriptor, operation: operation))
            default:
                break loop
            }
        }
        if command.words.isEmpty && command.assignments.isEmpty && command.redirections.isEmpty {
            if atEnd { throw ShellSyntaxError.incomplete }
            throw ShellSyntaxError.unexpected(ShellParser.describe(peek()))
        }
        return command
    }
}

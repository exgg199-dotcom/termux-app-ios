import Foundation

/// Evaluates shell arithmetic `$(( ... ))` with 64-bit integers.
struct ArithmeticEvaluator {
    enum ArithError: Error { case syntax, divisionByZero }

    private enum Tok: Equatable { case num(Int64), name(String), op(String) }
    private var toks: [Tok] = []
    private var pos = 0
    private let lookup: (String) -> String?
    private var assign: ((String, Int64) -> Void)?
    private let source: String

    init(_ source: String, lookup: @escaping (String) -> String?) {
        self.source = source
        self.lookup = lookup
    }

    mutating func evaluate(assign: @escaping (String, Int64) -> Void) throws -> Int64 {
        self.assign = assign
        toks = try ArithmeticEvaluator.lex(source)
        if toks.isEmpty { return 0 }
        let v = try parseAssign()
        guard pos == toks.count else { throw ArithError.syntax }
        return v
    }

    private static func lex(_ s: String) throws -> [Tok] {
        var out: [Tok] = []
        let c = Array(s)
        var i = 0
        let ops = ["<<=", ">>=", "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "++", "--",
                   "+", "-", "*", "/", "%", "(", ")", "<", ">", "!", "~", "&", "|", "^", "?", ":", "="]
        while i < c.count {
            if c[i].isWhitespace { i += 1; continue }
            if c[i].isNumber {
                var j = i
                while j < c.count && (c[j].isHexDigit || c[j] == "x" || c[j] == "X") { j += 1 }
                let text = String(c[i..<j])
                let v: Int64?
                if text.hasPrefix("0x") || text.hasPrefix("0X") { v = Int64(text.dropFirst(2), radix: 16) }
                else if text.hasPrefix("0") && text.count > 1 { v = Int64(text.dropFirst(), radix: 8) }
                else { v = Int64(text) }
                guard let val = v else { throw ArithError.syntax }
                out.append(.num(val)); i = j; continue
            }
            if c[i].isLetter || c[i] == "_" {
                var j = i
                while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_") { j += 1 }
                out.append(.name(String(c[i..<j]))); i = j; continue
            }
            var matched = false
            for op in ops {
                let oc = Array(op)
                if i + oc.count <= c.count && Array(c[i..<(i + oc.count)]) == oc {
                    out.append(.op(op)); i += oc.count; matched = true; break
                }
            }
            if !matched { throw ArithError.syntax }
        }
        return out
    }

    private func peekOp() -> String? { if pos < toks.count, case .op(let o) = toks[pos] { return o }; return nil }

    private func value(of name: String) -> Int64 {
        guard let s = lookup(name)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        return Int64(s) ?? 0
    }

    private mutating func parseAssign() throws -> Int64 {
        if pos + 1 < toks.count, case .name(let n) = toks[pos], case .op(let o) = toks[pos + 1],
           ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>="].contains(o) {
            pos += 2
            let rhs = try parseAssign()
            let cur = value(of: n)
            let v: Int64
            switch o {
            case "=": v = rhs
            case "+=": v = cur &+ rhs
            case "-=": v = cur &- rhs
            case "*=": v = cur &* rhs
            case "/=": guard rhs != 0 else { throw ArithError.divisionByZero }; v = cur / rhs
            case "%=": guard rhs != 0 else { throw ArithError.divisionByZero }; v = cur % rhs
            case "<<=": v = cur << rhs
            default: v = cur >> rhs
            }
            assign?(n, v)
            return v
        }
        return try parseTernary()
    }

    private mutating func parseTernary() throws -> Int64 {
        let cond = try parseBinary(0)
        if peekOp() == "?" {
            pos += 1
            let a = try parseAssign()
            guard peekOp() == ":" else { throw ArithError.syntax }
            pos += 1
            let b = try parseAssign()
            return cond != 0 ? a : b
        }
        return cond
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="],
                                             ["<<", ">>"], ["+", "-"], ["*", "/", "%"], ["**"]]

    private mutating func parseBinary(_ level: Int) throws -> Int64 {
        if level >= ArithmeticEvaluator.levels.count { return try parseUnary() }
        var lhs = try parseBinary(level + 1)
        while let op = peekOp(), ArithmeticEvaluator.levels[level].contains(op) {
            pos += 1
            let rhs = try parseBinary(op == "**" ? level : level + 1)
            switch op {
            case "||": lhs = (lhs != 0 || rhs != 0) ? 1 : 0
            case "&&": lhs = (lhs != 0 && rhs != 0) ? 1 : 0
            case "|": lhs |= rhs
            case "^": lhs ^= rhs
            case "&": lhs &= rhs
            case "==": lhs = lhs == rhs ? 1 : 0
            case "!=": lhs = lhs != rhs ? 1 : 0
            case "<": lhs = lhs < rhs ? 1 : 0
            case ">": lhs = lhs > rhs ? 1 : 0
            case "<=": lhs = lhs <= rhs ? 1 : 0
            case ">=": lhs = lhs >= rhs ? 1 : 0
            case "<<": lhs = lhs << rhs
            case ">>": lhs = lhs >> rhs
            case "+": lhs = lhs &+ rhs
            case "-": lhs = lhs &- rhs
            case "*": lhs = lhs &* rhs
            case "/": guard rhs != 0 else { throw ArithError.divisionByZero }; lhs = lhs / rhs
            case "%": guard rhs != 0 else { throw ArithError.divisionByZero }; lhs = lhs % rhs
            case "**":
                var r: Int64 = 1
                if rhs > 0 { for _ in 0..<rhs { r = r &* lhs } }
                lhs = r
            default: throw ArithError.syntax
            }
        }
        return lhs
    }

    private mutating func parseUnary() throws -> Int64 {
        if let op = peekOp() {
            switch op {
            case "-": pos += 1; return 0 &- (try parseUnary())
            case "+": pos += 1; return try parseUnary()
            case "!": pos += 1; return (try parseUnary()) == 0 ? 1 : 0
            case "~": pos += 1; return ~(try parseUnary())
            case "++", "--":
                pos += 1
                guard pos < toks.count, case .name(let n) = toks[pos] else { throw ArithError.syntax }
                pos += 1
                let v = value(of: n) + (op == "++" ? 1 : -1)
                assign?(n, v)
                return v
            case "(":
                pos += 1
                let v = try parseAssign()
                guard peekOp() == ")" else { throw ArithError.syntax }
                pos += 1
                return v
            default: throw ArithError.syntax
            }
        }
        guard pos < toks.count else { throw ArithError.syntax }
        switch toks[pos] {
        case .num(let v): pos += 1; return v
        case .name(let n):
            pos += 1
            let v = value(of: n)
            if let op = peekOp(), op == "++" || op == "--" {
                pos += 1
                assign?(n, v + (op == "++" ? 1 : -1))
            }
            return v
        case .op: throw ArithError.syntax
        }
    }
}

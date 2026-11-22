import Foundation

struct ArithmeticEvaluator {
    enum ArithmeticError: Error { case syntax, divisionByZero }

    private enum ArithmeticToken: Equatable { case number(Int64), name(String), operation(String) }
    private var tokens: [ArithmeticToken] = []
    private var position = 0
    private let lookup: (String) -> String?
    private var assign: ((String, Int64) -> Void)?
    private let source: String

    init(_ source: String, lookup: @escaping (String) -> String?) {
        self.source = source
        self.lookup = lookup
    }

    mutating func evaluate(assign: @escaping (String, Int64) -> Void) throws -> Int64 {
        self.assign = assign
        tokens = try ArithmeticEvaluator.tokenize(source)
        if tokens.isEmpty { return 0 }
        let v = try parseAssign()
        guard position == tokens.count else { throw ArithmeticError.syntax }
        return v
    }

    private static func tokenize(_ s: String) throws -> [ArithmeticToken] {
        var out: [ArithmeticToken] = []
        let c = Array(s)
        var i = 0
        let symbols = ["<<=", ">>=", "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "++", "--",
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
                guard let parsedValue = v else { throw ArithmeticError.syntax }
                out.append(.number(parsedValue)); i = j; continue
            }
            if c[i].isLetter || c[i] == "_" {
                var j = i
                while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_") { j += 1 }
                out.append(.name(String(c[i..<j]))); i = j; continue
            }
            var matched = false
            for operation in symbols {
                let symbolCharacters = Array(operation)
                if i + symbolCharacters.count <= c.count && Array(c[i..<(i + symbolCharacters.count)]) == symbolCharacters {
                    out.append(.operation(operation)); i += symbolCharacters.count; matched = true; break
                }
            }
            if !matched { throw ArithmeticError.syntax }
        }
        return out
    }

    private func peekOperation() -> String? { if position < tokens.count, case .operation(let o) = tokens[position] { return o }; return nil }

    private func value(of name: String) -> Int64 {
        guard let s = lookup(name)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        return Int64(s) ?? 0
    }

    private mutating func parseAssign() throws -> Int64 {
        if position + 1 < tokens.count, case .name(let n) = tokens[position], case .operation(let o) = tokens[position + 1],
           ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>="].contains(o) {
            position += 2
            let rightValue = try parseAssign()
            let current = value(of: n)
            let v: Int64
            switch o {
            case "=": v = rightValue
            case "+=": v = current &+ rightValue
            case "-=": v = current &- rightValue
            case "*=": v = current &* rightValue
            case "/=": guard rightValue != 0 else { throw ArithmeticError.divisionByZero }; v = current / rightValue
            case "%=": guard rightValue != 0 else { throw ArithmeticError.divisionByZero }; v = current % rightValue
            case "<<=": v = current << rightValue
            default: v = current >> rightValue
            }
            assign?(n, v)
            return v
        }
        return try parseTernary()
    }

    private mutating func parseTernary() throws -> Int64 {
        let cond = try parseBinary(0)
        if peekOperation() == "?" {
            position += 1
            let a = try parseAssign()
            guard peekOperation() == ":" else { throw ArithmeticError.syntax }
            position += 1
            let b = try parseAssign()
            return cond != 0 ? a : b
        }
        return cond
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="],
                                             ["<<", ">>"], ["+", "-"], ["*", "/", "%"], ["**"]]

    private mutating func parseBinary(_ level: Int) throws -> Int64 {
        if level >= ArithmeticEvaluator.levels.count { return try parseUnary() }
        var leftValue = try parseBinary(level + 1)
        while let operation = peekOperation(), ArithmeticEvaluator.levels[level].contains(operation) {
            position += 1
            let rightValue = try parseBinary(operation == "**" ? level : level + 1)
            switch operation {
            case "||": leftValue = (leftValue != 0 || rightValue != 0) ? 1 : 0
            case "&&": leftValue = (leftValue != 0 && rightValue != 0) ? 1 : 0
            case "|": leftValue |= rightValue
            case "^": leftValue ^= rightValue
            case "&": leftValue &= rightValue
            case "==": leftValue = leftValue == rightValue ? 1 : 0
            case "!=": leftValue = leftValue != rightValue ? 1 : 0
            case "<": leftValue = leftValue < rightValue ? 1 : 0
            case ">": leftValue = leftValue > rightValue ? 1 : 0
            case "<=": leftValue = leftValue <= rightValue ? 1 : 0
            case ">=": leftValue = leftValue >= rightValue ? 1 : 0
            case "<<": leftValue = leftValue << rightValue
            case ">>": leftValue = leftValue >> rightValue
            case "+": leftValue = leftValue &+ rightValue
            case "-": leftValue = leftValue &- rightValue
            case "*": leftValue = leftValue &* rightValue
            case "/": guard rightValue != 0 else { throw ArithmeticError.divisionByZero }; leftValue = leftValue / rightValue
            case "%": guard rightValue != 0 else { throw ArithmeticError.divisionByZero }; leftValue = leftValue % rightValue
            case "**":
                var r: Int64 = 1
                if rightValue > 0 { for _ in 0..<rightValue { r = r &* leftValue } }
                leftValue = r
            default: throw ArithmeticError.syntax
            }
        }
        return leftValue
    }

    private mutating func parseUnary() throws -> Int64 {
        if let operation = peekOperation() {
            switch operation {
            case "-": position += 1; return 0 &- (try parseUnary())
            case "+": position += 1; return try parseUnary()
            case "!": position += 1; return (try parseUnary()) == 0 ? 1 : 0
            case "~": position += 1; return ~(try parseUnary())
            case "++", "--":
                position += 1
                guard position < tokens.count, case .name(let n) = tokens[position] else { throw ArithmeticError.syntax }
                position += 1
                let v = value(of: n) + (operation == "++" ? 1 : -1)
                assign?(n, v)
                return v
            case "(":
                position += 1
                let v = try parseAssign()
                guard peekOperation() == ")" else { throw ArithmeticError.syntax }
                position += 1
                return v
            default: throw ArithmeticError.syntax
            }
        }
        guard position < tokens.count else { throw ArithmeticError.syntax }
        switch tokens[position] {
        case .number(let v): position += 1; return v
        case .name(let n):
            position += 1
            let v = value(of: n)
            if let operation = peekOperation(), operation == "++" || operation == "--" {
                position += 1
                assign?(n, v + (operation == "++" ? 1 : -1))
            }
            return v
        case .operation: throw ArithmeticError.syntax
        }
    }
}

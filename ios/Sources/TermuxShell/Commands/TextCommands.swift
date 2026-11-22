import Foundation

enum TextCommands {
    static func register(_ r: CommandRegistry) {
        r.register("head", "output the first lines of files (-n N, -c N)") { headTail($0, head: true) }
        r.register("tail", "output the last lines of files (-n N, -n +N, -c N)") { headTail($0, head: false) }
        r.register("wc", "count lines, words and bytes (-l -w -c -m)") { wc($0) }
        r.register("grep", "search for patterns (-i -v -n -r -c -l -E -F -o -w -q)") { grep($0) }
        r.register("egrep", "") { context in grep(context, extended: true) }
        r.register("fgrep", "") { context in grep(context, fixed: true) }
        r.register("sort", "sort lines (-r -n -u -f -k N -t SEP)") { sort($0) }
        r.register("uniq", "filter repeated lines (-c -d -u -i)") { uniq($0) }
        r.register("cut", "select fields or characters (-d SEP -f LIST, -c LIST)") { cut($0) }
        r.register("tr", "translate or delete characters (-d -s)") { tr($0) }
        r.register("sed", "stream editor (s/regex/replacement/[gip], -n -e -E -i, p d)") { sed($0) }
        r.register("tee", "copy stdin to stdout and files (-a)") { tee($0) }
        r.register("rev", "reverse lines characterwise") { context in
            context.forEachInput(context.arguments) { input, _ in
                let reader = LineReader(input)
                while !context.shouldStop, let l = reader.nextLine() { context.print(String(l.reversed())) }
            }
        }
        r.register("nl", "number lines") { context in
            var n = 0
            return context.forEachInput(context.arguments) { input, _ in
                let reader = LineReader(input)
                while !context.shouldStop, let l = reader.nextLine() {
                    if l.isEmpty { context.print(); continue }
                    n += 1; context.print(ShellFormat.pad(String(n), 6, right: true) + "\t" + l)
                }
            }
        }
        r.register("xargs", "build and run commands from stdin") { xargs($0) }
        r.register("base64", "base64 encode/decode (-d, -w COLS)") { base64($0) }
        r.register("md5sum", "compute MD5 checksums") { context in checksum(context) { Hashing.md5($0) } }
        r.register("sha1sum", "compute SHA-1 checksums") { context in checksum(context) { Hashing.sha1($0) } }
        r.register("sha256sum", "compute SHA-256 checksums") { context in checksum(context) { Hashing.sha256($0) } }
        r.register("xxd", "hex dump (-l LEN, -s SKIP, -c COLS, -p plain)") { xxd($0) }
        r.register("hexdump", "hex dump in canonical format (-C)") { hexdump($0) }
        r.alias("hd", to: "hexdump")
    }

    static func headTail(_ context: CommandContext, head: Bool) -> Int32 {
        let arguments = context.arguments.map { a -> String in
            if a.count > 1, a.hasPrefix("-"), Int(a.dropFirst()) != nil { return "-n" + a.dropFirst() }
            return a
        }
        let options = ParsedOptions(arguments, flags: "qvf", withValues: "nc")
        if let e = options.error { context.error(e); return 1 }
        var countText = options.value("n") ?? "10"
        let bytesMode = options.value("c") != nil
        if let c = options.value("c") { countText = c }
        let fromStart = !head && countText.hasPrefix("+")
        let allBut = head && countText.hasPrefix("-")
        guard let count = Int(countText.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) else {
            context.error("invalid number of lines: '\(countText)'"); return 1
        }
        let files = options.operands
        let showHeaders = (files.count > 1 && !options.has("q")) || options.has("v")
        var first = true
        return context.forEachInput(files) { input, name in
            if showHeaders {
                context.print((first ? "" : "\n") + "==> \(name == "-" ? "standard input" : name) <==")
            }
            first = false
            if bytesMode {
                if head && !allBut {
                    var remaining = count
                    while remaining > 0, !context.shouldStop, let chunk = input.read(maxLength: min(remaining, 65536)) {
                        context.stdout.write(chunk); remaining -= chunk.count
                    }
                    return
                }
                let all = input.readAll()
                if head { context.stdout.write(Array(all.dropLast(count))) }
                else if fromStart { context.stdout.write(Array(all.dropFirst(max(0, count - 1)))) }
                else { context.stdout.write(Array(all.suffix(count))) }
                return
            }
            let reader = LineReader(input)
            if head && !allBut {
                var n = 0
                while n < count, !context.shouldStop, let line = reader.nextLineBytes() { context.stdout.write(line + [0x0A]); n += 1 }
                return
            }
            if fromStart {
                var n = 1
                while !context.shouldStop, let line = reader.nextLineBytes() {
                    if n >= count { context.stdout.write(line + [0x0A]) }
                    n += 1
                }
                return
            }
            var ring: [[UInt8]] = []
            while !context.isCancelled, let line = reader.nextLineBytes() {
                if allBut { ring.append(line) } else {
                    ring.append(line)
                    if ring.count > count { ring.removeFirst() }
                }
            }
            if allBut { ring = Array(ring.dropLast(count)) }
            for line in ring { context.stdout.write(line + [0x0A]) }
        }
    }

    static func wc(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "lwcmL")
        if let e = options.error { context.error(e); return 1 }
        var show = (l: options.has("l"), w: options.has("w"), c: options.has("c"), m: options.has("m"))
        if !show.l && !show.w && !show.c && !show.m { show = (true, true, true, false) }
        var rows: [([Int], String)] = []
        var totals = [0, 0, 0, 0]
        let status = context.forEachInput(options.operands) { input, name in
            let data = input.readAll()
            let lines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            let text = String(decoding: data, as: UTF8.self)
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let values = [lines, words, text.count, data.count]
            for k in 0..<4 { totals[k] += values[k] }
            rows.append((values, name == "-" ? "" : name))
        }
        if rows.count > 1 { rows.append((totals, "total")) }
        let width = rows.count == 1 && options.operands.isEmpty ? 0 : max(1, String(totals.max() ?? 0).count)
        for (values, name) in rows {
            var parts: [String] = []
            if show.l { parts.append(ShellFormat.pad(String(values[0]), width, right: true)) }
            if show.w { parts.append(ShellFormat.pad(String(values[1]), width, right: true)) }
            if show.m { parts.append(ShellFormat.pad(String(values[2]), width, right: true)) }
            if show.c { parts.append(ShellFormat.pad(String(values[3]), width, right: true)) }
            if !name.isEmpty { parts.append(name) }
            context.print(parts.joined(separator: " "))
        }
        return status
    }

    static func basicToExtended(_ basicExpression: String) -> String {
        var out = ""
        var chars = Array(basicExpression)[...]
        var inBracket = false
        while let c = chars.first {
            chars = chars.dropFirst()
            if inBracket {
                out.append(c)
                if c == "]" { inBracket = false }
                continue
            }
            switch c {
            case "\\":
                guard let n = chars.first else { out += "\\\\"; continue }
                chars = chars.dropFirst()
                switch n {
                case "(", ")", "{", "}", "|", "+", "?": out.append(n)
                case "<", ">": out += "\\b"
                default: out.append("\\"); out.append(n)
                }
            case "(", ")", "{", "}", "|", "+", "?":
                out.append("\\"); out.append(c)
            case "[":
                inBracket = true
                out.append(c)
                if chars.first == "^" { out.append("^"); chars = chars.dropFirst() }
                if chars.first == "]" { out += "\\]"; chars = chars.dropFirst() }
            default:
                out.append(c)
            }
        }
        return out
    }

    static func posixToICU(_ expression: String) -> String {
        var s = expression
        let classes = ["[:alpha:]": "\\p{L}", "[:digit:]": "0-9", "[:alnum:]": "\\p{L}0-9", "[:upper:]": "\\p{Lu}",
                       "[:lower:]": "\\p{Ll}", "[:space:]": "\\s", "[:blank:]": " \\t", "[:punct:]": "\\p{P}\\p{S}",
                       "[:xdigit:]": "0-9A-Fa-f", "[:cntrl:]": "\\x00-\\x1f", "[:print:]": "\\x20-\\x7e", "[:graph:]": "\\x21-\\x7e"]
        for (k, v) in classes { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\<", with: "\\b").replacingOccurrences(of: "\\>", with: "\\b")
        return s
    }

    static func makeRegularExpression(_ pattern: String, extended: Bool, fixed: Bool, ignoreCase: Bool, word: Bool = false, line: Bool = false) -> NSRegularExpression? {
        var p = fixed ? NSRegularExpression.escapedPattern(for: pattern) : posixToICU(extended ? pattern : basicToExtended(pattern))
        if word { p = "\\b(?:" + p + ")\\b" }
        if line { p = "^(?:" + p + ")$" }
        return try? NSRegularExpression(pattern: p, options: ignoreCase ? [.caseInsensitive] : [])
    }

    static func grep(_ context: CommandContext, extended: Bool = false, fixed: Bool = false) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "ivnrRclLEFowqhHsx", withValues: "eAB")
        if let e = options.error { context.error(e); return 2 }
        var operands = options.operands
        var patterns: [String] = []
        if let e = options.value("e") { patterns.append(e) } else {
            guard !operands.isEmpty else { context.stderr.writeLine("usage: grep [-ivnrclEFowq] PATTERN [FILE...]"); return 2 }
            patterns.append(operands.removeFirst())
        }
        let ignoreCase = options.has("i"), invert = options.has("v"), lineNumbers = options.has("n")
        let countOnly = options.has("c"), filesOnly = options.has("l"), filesWithout = options.has("L"), quiet = options.has("q")
        let onlyMatching = options.has("o"), recursive = options.has("r") || options.has("R")
        let expressions = patterns.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }.compactMap {
            makeRegularExpression($0, extended: extended || options.has("E"), fixed: fixed || options.has("F"), ignoreCase: ignoreCase,
                      word: options.has("w"), line: options.has("x"))
        }
        guard !expressions.isEmpty else { context.error("invalid regular expression"); return 2 }
        let color = context.stdout.isTerminal && !(context.environment["GREP_COLOR"] == "never")

        var files: [String] = []
        if recursive && operands.isEmpty { operands = ["."] }
        var status: Int32 = 1
        var hadError = false
        for operation in operands {
            let path = context.resolve(operation)
            if let info = FileInfo(path: path, follow: true), info.isDirectory {
                if !recursive { if !options.has("s") { context.error("\(operation): Is a directory") }; continue }
                if let en = FileManager.default.enumerator(atPath: path) {
                    var found: [String] = []
                    while let relativePath = en.nextObject() as? String {
                        let full = path + "/" + relativePath
                        if FileInfo(path: full, follow: false)?.isRegular == true {
                            found.append(operation == "." && !context.arguments.contains(".") ? relativePath : (operation.hasSuffix("/") ? operation + relativePath : operation + "/" + relativePath))
                        }
                    }
                    files.append(contentsOf: found.sorted())
                }
            } else {
                files.append(operation)
            }
        }
        let showNames = options.has("H") || (!options.has("h") && (files.count > 1 || recursive))

        func matchRanges(_ line: String) -> [NSRange] {
            let nativeString = line as NSString
            var ranges: [NSRange] = []
            for expression in expressions {
                for m in expression.matches(in: line, range: NSRange(location: 0, length: nativeString.length)) where m.range.length > 0 || expressions.count == 1 {
                    ranges.append(m.range)
                }
            }
            return ranges.sorted { $0.location < $1.location }
        }
        func isMatch(_ line: String) -> Bool {
            let range = NSRange(location: 0, length: (line as NSString).length)
            return expressions.contains { $0.firstMatch(in: line, range: range) != nil }
        }

        func process(_ input: ShellInputStream, _ name: String) -> Bool {
            let reader = LineReader(input)
            var count = 0
            var lineNumber = 0
            let display = name == "-" ? "(standard input)" : name
            let prefixName = showNames ? (color ? ANSI.magenta + display + ANSI.reset + ANSI.cyan + ":" + ANSI.reset : display + ":") : ""
            while !context.shouldStop, let line = reader.nextLine() {
                lineNumber += 1
                let matched = isMatch(line) != invert
                guard matched else { continue }
                count += 1
                if quiet { return true }
                if filesOnly || filesWithout { break }
                if countOnly { continue }
                let numberPrefix = lineNumbers ? (color ? ANSI.green + String(lineNumber) + ANSI.reset + ANSI.cyan + ":" + ANSI.reset : "\(lineNumber):") : ""
                if onlyMatching && !invert {
                    let nativeString = line as NSString
                    for r in matchRanges(line) where r.length > 0 {
                        let s = nativeString.substring(with: r)
                        context.print(prefixName + numberPrefix + (color ? ANSI.boldRed + s + ANSI.reset : s))
                    }
                    continue
                }
                var shown = line
                if color && !invert {
                    let nativeString = line as NSString
                    var out = ""
                    var last = 0
                    for r in matchRanges(line) where r.location >= last && r.length > 0 {
                        out += nativeString.substring(with: NSRange(location: last, length: r.location - last))
                        out += ANSI.boldRed + nativeString.substring(with: r) + ANSI.reset
                        last = r.location + r.length
                    }
                    out += nativeString.substring(from: last)
                    shown = out
                }
                context.print(prefixName + numberPrefix + shown)
            }
            if countOnly { context.print((showNames ? display + ":" : "") + String(count)) }
            if filesOnly && count > 0 { context.print(display) }
            if filesWithout && count == 0 { context.print(display) }
            return count > 0
        }

        if files.isEmpty {
            if process(context.stdin, "-") { status = 0 }
        } else {
            for f in files {
                if context.shouldStop { break }
                guard let input = context.openInputQuiet(f, quiet: options.has("s")) else { hadError = true; continue }
                if process(input, f) { status = 0; if quiet { break } }
                input.close()
            }
        }
        if hadError && status != 0 { return 2 }
        return status
    }

    static func sort(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "rnufbhVR", withValues: "kto")
        if let e = options.error { context.error(e); return 2 }
        var lines: [String] = []
        let status = context.forEachInput(options.operands) { input, _ in lines.append(contentsOf: LineReader(input).allLines()) }
        let separator = options.value("t").flatMap { $0.first }
        let keyField = options.value("k").flatMap { Int($0.split(separator: ",").first.map { String($0.prefix { $0.isNumber }) } ?? "") }
        func key(_ line: String) -> String {
            var k = line
            if let f = keyField {
                let fields: [String] = separator != nil ? line.split(separator: separator!, omittingEmptySubsequences: false).map(String.init)
                                                  : line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                k = f - 1 < fields.count ? fields[(f - 1)...].joined(separator: separator.map(String.init) ?? " ") : ""
            }
            if options.has("b") { k = k.trimmingCharacters(in: .whitespaces) }
            if options.has("f") { k = k.lowercased() }
            return k
        }
        func number(_ s: String) -> Double {
            let t = s.trimmingCharacters(in: .whitespaces)
            var prefix = ""
            for c in t { if c.isNumber || c == "." || (c == "-" && prefix.isEmpty) { prefix.append(c) } else { break } }
            var v = Double(prefix) ?? 0
            if options.has("h"), let unit = t.dropFirst(prefix.count).first, let index = "KMGTP".firstIndex(of: Character(unit.uppercased())) {
                v *= pow(1024, Double("KMGTP".distance(from: "KMGTP".startIndex, to: index) + 1))
            }
            return v
        }
        let keyed = lines.map { (key($0), $0) }
        var sorted: [(String, String)]
        if options.has("R") {
            sorted = keyed.shuffled()
        } else if options.has("n") || options.has("h") {
            let numbered: [(Double, String, String)] = keyed.map { (number($0.0), $0.0, $0.1) }
            let order = numbered.indices.sorted { i, j in
                let a = numbered[i], b = numbered[j]
                if a.0 != b.0 { return a.0 < b.0 }
                if a.2 != b.2 { return a.2 < b.2 }
                return i < j
            }
            sorted = order.map { (numbered[$0].1, numbered[$0].2) }
        } else if options.has("V") {
            sorted = keyed.sorted { $0.0.compare($1.0, options: .numeric) == .orderedAscending }
        } else {
            sorted = keyed.enumerated().sorted { a, b in
                a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset
            }.map { $0.element }
        }
        if options.has("r") { sorted.reverse() }
        var out = sorted.map { $0.1 }
        if options.has("u") {
            var seen = Set<String>()
            out = sorted.filter { seen.insert($0.0).inserted }.map { $0.1 }
        }
        let text = out.map { $0 + "\n" }.joined()
        if let o = options.value("o") {
            guard let f = FileOutputStream(path: context.resolve(o), append: false) else { context.error("cannot open '\(o)' for writing"); return 2 }
            f.write(text); f.close()
        } else {
            context.stdout.write(text)
        }
        return status == 0 ? 0 : 2
    }

    static func uniq(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "cdui")
        if let e = options.error { context.error(e); return 1 }
        let input: ShellInputStream
        if let f = options.operands.first { guard let i = context.openInput(f) else { return 1 }; input = i } else { input = context.stdin }
        let reader = LineReader(input)
        var previous: String? = nil
        var count = 0
        func emit() {
            guard let p = previous else { return }
            if options.has("d") && count < 2 { return }
            if options.has("u") && count > 1 { return }
            context.print(options.has("c") ? ShellFormat.pad(String(count), 7, right: true) + " " + p : p)
        }
        while !context.shouldStop, let line = reader.nextLine() {
            if let p = previous, options.has("i") ? p.lowercased() == line.lowercased() : p == line { count += 1; continue }
            emit()
            previous = line; count = 1
        }
        emit()
        return 0
    }

    static func parseList(_ s: String) -> [(Int, Int)]? {
        var ranges: [(Int, Int)] = []
        for part in s.split(separator: ",") {
            if part.contains("-") {
                let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                let lower = ends[0].isEmpty ? 1 : Int(ends[0])
                let upper = ends.count > 1 && !ends[1].isEmpty ? Int(ends[1]) : Int.max
                guard let l = lower, let h = upper, l >= 1, h >= l else { return nil }
                ranges.append((l, h))
            } else {
                guard let n = Int(part), n >= 1 else { return nil }
                ranges.append((n, n))
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    static func cut(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "s", withValues: "dfcb")
        if let e = options.error { context.error(e); return 1 }
        let fieldList = options.value("f"), charList = options.value("c") ?? options.value("b")
        guard let listText = fieldList ?? charList, let ranges = parseList(listText) else {
            context.error("you must specify a list of bytes, characters, or fields"); return 1
        }
        func selected(_ i: Int) -> Bool { ranges.contains { $0.0 <= i && i <= $0.1 } }
        let delim = options.value("d").map { $0.isEmpty ? "\t" : String($0.prefix(1)) } ?? "\t"
        return context.forEachInput(options.operands) { input, _ in
            let reader = LineReader(input)
            while !context.shouldStop, let line = reader.nextLine() {
                if fieldList != nil {
                    guard line.contains(delim) else { if !options.has("s") { context.print(line) }; continue }
                    let fields = line.components(separatedBy: delim)
                    context.print(fields.enumerated().filter { selected($0.offset + 1) }.map { $0.element }.joined(separator: delim))
                } else {
                    context.print(String(Array(line).enumerated().filter { selected($0.offset + 1) }.map { $0.element }))
                }
            }
        }
    }

    static func expandSet(_ s: String) -> [Character] {
        let (unescaped, _) = ShellFormat.unescape(s)
        var chars = Array(unescaped)
        var out: [Character] = []
        var i = 0
        let classes: [String: [Character]] = [
            "[:upper:]": Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), "[:lower:]": Array("abcdefghijklmnopqrstuvwxyz"),
            "[:digit:]": Array("0123456789"), "[:space:]": [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"],
            "[:blank:]": [" ", "\t"], "[:alpha:]": Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
            "[:alnum:]": Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
            "[:punct:]": Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"), "[:xdigit:]": Array("0123456789ABCDEFabcdef"),
        ]
        while i < chars.count {
            if chars[i] == "[" , let end = (i + 1..<chars.count).first(where: { chars[$0] == "]" }) {
                let name = String(chars[i...end])
                if let characterClass = classes[name] { out.append(contentsOf: characterClass); i = end + 1; continue }
            }
            if i + 2 < chars.count && chars[i + 1] == "-",
               let a = chars[i].unicodeScalars.first?.value, let b = chars[i + 2].unicodeScalars.first?.value, a <= b {
                for v in a...b { if let u = Unicode.Scalar(v) { out.append(Character(u)) } }
                i += 3; continue
            }
            out.append(chars[i]); i += 1
        }
        chars.removeAll()
        return out
    }

    static func tr(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "dscC")
        if let e = options.error { context.error(e); return 1 }
        let operandList = options.operands
        guard !operandList.isEmpty else { context.error("missing operand"); return 1 }
        let set1 = expandSet(operandList[0])
        let set2 = operandList.count > 1 ? expandSet(operandList[1]) : []
        let complement = options.has("c") || options.has("C")
        let member = Set(set1)
        func inSet1(_ c: Character) -> Bool { member.contains(c) != complement }
        if !options.has("d") && !options.has("s") && set2.isEmpty { context.error("missing operand after '\(operandList[0])'"); return 1 }
        var map: [Character: Character] = [:]
        if !options.has("d") && !set2.isEmpty && !complement {
            for (i, c) in set1.enumerated() { map[c] = i < set2.count ? set2[i] : set2.last! }
        }
        let squeezeSet = Set(options.has("d") ? set2 : (set2.isEmpty ? set1 : set2))
        let reader = context.stdin
        var lastOutput: Character? = nil
        while !context.shouldStop, let chunk = reader.read(maxLength: 65536) {
            var out = ""
            for c in String(decoding: chunk, as: UTF8.self) {
                var character = c
                if options.has("d") && inSet1(character) { continue }
                if !options.has("d") {
                    if complement && !set2.isEmpty && inSet1(character) { character = set2.last! }
                    else if let m = map[character] { character = m }
                }
                if options.has("s") && squeezeSet.contains(character) && lastOutput == character { continue }
                out.append(character); lastOutput = character
            }
            context.stdout.write(out)
        }
        return 0
    }

    enum SedCommand {
        case substitute(NSRegularExpression, String, global: Bool, occurrence: Int, print: Bool)
        case delete
        case print
        case quit
    }

    struct SedScript {
        var address: SedAddress?
        var command: SedCommand
    }

    enum SedAddress {
        case line(Int)
        case last
        case pattern(NSRegularExpression)
        case range(Int, Int)
    }

    static func parseSed(_ script: String, extended: Bool) -> [SedScript]? {
        var result: [SedScript] = []
        var chars = Array(script)[...]
        func skipSpace() { while let c = chars.first, c == " " || c == "\t" || c == "\n" || c == ";" { chars = chars.dropFirst() } }
        func readDelimited(_ d: Character) -> String? {
            var s = ""
            while let c = chars.first {
                chars = chars.dropFirst()
                if c == "\\", let n = chars.first {
                    chars = chars.dropFirst()
                    if n == d { s.append(d) } else if n == "n" { s.append("\n") } else { s.append("\\"); s.append(n) }
                    continue
                }
                if c == d { return s }
                s.append(c)
            }
            return nil
        }
        while true {
            skipSpace()
            guard !chars.isEmpty else { break }
            var address: SedAddress? = nil
            if let c = chars.first, c.isNumber {
                var n = ""
                while let d = chars.first, d.isNumber { n.append(d); chars = chars.dropFirst() }
                address = .line(Int(n)!)
                if chars.first == "," {
                    chars = chars.dropFirst()
                    var m = ""
                    while let d = chars.first, d.isNumber { m.append(d); chars = chars.dropFirst() }
                    if chars.first == "$" { chars = chars.dropFirst(); m = String(Int.max) }
                    address = .range(Int(n)!, Int(m) ?? Int.max)
                }
            } else if chars.first == "$" {
                chars = chars.dropFirst(); address = .last
            } else if chars.first == "/" {
                chars = chars.dropFirst()
                guard let expression = readDelimited("/"), let compiledExpression = makeRegularExpression(expression, extended: extended, fixed: false, ignoreCase: false) else { return nil }
                address = .pattern(compiledExpression)
            }
            guard let command = chars.first else { return nil }
            chars = chars.dropFirst()
            switch command {
            case "s":
                guard let d = chars.first else { return nil }
                chars = chars.dropFirst()
                guard let pattern = readDelimited(d), let replacement = readDelimited(d) else { return nil }
                var global = false, ignoreCase = false, print = false, occurrence = 1
                while let f = chars.first, "gIipe0123456789".contains(f) {
                    chars = chars.dropFirst()
                    switch f {
                    case "g": global = true
                    case "i", "I": ignoreCase = true
                    case "p": print = true
                    default: if let n = Int(String(f)) { occurrence = n }
                    }
                }
                guard let expression = makeRegularExpression(pattern, extended: extended, fixed: false, ignoreCase: ignoreCase) else { return nil }
                result.append(SedScript(address: address, command: .substitute(expression, convertReplacement(replacement), global: global, occurrence: occurrence, print: print)))
            case "d": result.append(SedScript(address: address, command: .delete))
            case "p": result.append(SedScript(address: address, command: .print))
            case "q": result.append(SedScript(address: address, command: .quit))
            default: return nil
            }
        }
        return result
    }

    static func convertReplacement(_ r: String) -> String {
        var out = ""
        var it = Array(r)[...]
        while let c = it.first {
            it = it.dropFirst()
            switch c {
            case "&": out += "$0"
            case "$": out += "\\$"
            case "\\":
                guard let n = it.first else { out += "\\\\"; continue }
                it = it.dropFirst()
                if n.isNumber { out += "$" + String(n) }
                else if n == "n" { out += "\n" }
                else if n == "t" { out += "\t" }
                else if n == "&" { out += "&" }
                else { out += "\\" + String(n) }
            default: out.append(c)
            }
        }
        return out
    }

    static func sed(_ context: CommandContext) -> Int32 {
        var arguments = context.arguments
        var scripts: [String] = []
        var quietMode = false, extended = false, inPlace = false
        var files: [String] = []
        while !arguments.isEmpty {
            let a = arguments.removeFirst()
            switch a {
            case "-n", "--quiet", "--silent": quietMode = true
            case "-E", "-r", "--regexp-extended": extended = true
            case "-i": inPlace = true
            case "-e": if !arguments.isEmpty { scripts.append(arguments.removeFirst()) }
            default:
                if a.hasPrefix("-") && a.count > 1 && !a.hasPrefix("--") && a.dropFirst().allSatisfy({ "nErie".contains($0) }) {
                    if a.contains("n") { quietMode = true }
                    if a.contains("E") || a.contains("r") { extended = true }
                    if a.contains("i") { inPlace = true }
                    if a.hasSuffix("e"), !arguments.isEmpty { scripts.append(arguments.removeFirst()) }
                } else if scripts.isEmpty && !a.hasPrefix("-") {
                    scripts.append(a)
                } else {
                    files.append(a)
                }
            }
        }
        guard !scripts.isEmpty else { context.stderr.writeLine("usage: sed [-nE] [-i] 's/regex/replacement/[g]' [FILE...]"); return 1 }
        guard let program = parseSed(scripts.joined(separator: "\n"), extended: extended) else {
            context.error("unsupported or invalid script: \(scripts.joined(separator: "; "))"); return 1
        }

        func runSed(_ lines: [String], emit: (String) -> Void) {
            var inRange = Array(repeating: false, count: program.count)
            outer: for (index, line) in lines.enumerated() {
                if context.isCancelled { break }
                var pattern = line
                var deleted = false
                let lineNumber = index + 1
                for (k, s) in program.enumerated() {
                    if let address = s.address {
                        let applies: Bool
                        switch address {
                        case .line(let n): applies = lineNumber == n
                        case .last: applies = index == lines.count - 1
                        case .pattern(let expression): applies = expression.firstMatch(in: pattern, range: NSRange(location: 0, length: (pattern as NSString).length)) != nil
                        case .range(let a, let b):
                            if lineNumber == a { inRange[k] = true }
                            applies = inRange[k] && lineNumber <= b
                            if lineNumber >= b { inRange[k] = false }
                        }
                        if !applies { continue }
                    }
                    switch s.command {
                    case .delete: deleted = true; break
                    case .print: emit(pattern)
                    case .quit:
                        if !quietMode { emit(pattern) }
                        break outer
                    case .substitute(let expression, let template, let global, let occurrence, let printFlag):
                        let nativeString = pattern as NSString
                        let matches = expression.matches(in: pattern, range: NSRange(location: 0, length: nativeString.length))
                        guard !matches.isEmpty else { continue }
                        let targets = global ? Array(matches.dropFirst(occurrence - 1)) : (matches.count >= occurrence ? [matches[occurrence - 1]] : [])
                        guard !targets.isEmpty else { continue }
                        var out = ""
                        var last = 0
                        for m in targets {
                            out += nativeString.substring(with: NSRange(location: last, length: m.range.location - last))
                            out += expression.replacementString(for: m, in: pattern, offset: 0, template: template)
                            last = m.range.location + m.range.length
                        }
                        out += nativeString.substring(from: last)
                        pattern = out
                        if printFlag { emit(pattern) }
                    }
                    if deleted { break }
                }
                if !deleted && !quietMode { emit(pattern) }
            }
        }

        if inPlace {
            guard !files.isEmpty else { context.error("no input files"); return 1 }
            var status: Int32 = 0
            for f in files {
                let path = context.resolve(f)
                guard let data = FileManager.default.contents(atPath: path) else { context.error("can't read \(f): No such file or directory"); status = 1; continue }
                var text = String(decoding: data, as: UTF8.self)
                let hadTrailingNewline = text.hasSuffix("\n")
                if hadTrailingNewline { text.removeLast() }
                var out = ""
                runSed(text.isEmpty && !hadTrailingNewline ? [] : text.components(separatedBy: "\n")) { out += $0 + "\n" }
                do { try out.write(toFile: path, atomically: true, encoding: .utf8) } catch { context.error("couldn't write \(f)"); status = 1 }
            }
            return status
        }
        var lines: [String] = []
        let status = context.forEachInput(files) { input, _ in lines.append(contentsOf: LineReader(input).allLines()) }
        runSed(lines) { context.print($0) }
        return status
    }

    static func tee(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "ai")
        var outs: [FileOutputStream] = []
        var status: Int32 = 0
        for f in options.operands {
            if let o = FileOutputStream(path: context.resolve(f), append: options.has("a")) { outs.append(o) }
            else { context.error("\(f): No such file or directory"); status = 1 }
        }
        while !context.isCancelled, let chunk = context.stdin.read(maxLength: 65536) {
            context.stdout.write(chunk)
            outs.forEach { $0.write(chunk) }
        }
        outs.forEach { $0.close() }
        return status
    }

    static func xargs(_ context: CommandContext) -> Int32 {
        var arguments = context.arguments
        var maxArgs = Int.max
        var replace: String? = nil
        while let a = arguments.first, a.hasPrefix("-") {
            arguments.removeFirst()
            if a == "-n", let n = arguments.first.flatMap({ Int($0) }) { maxArgs = max(1, n); arguments.removeFirst() }
            else if a.hasPrefix("-n"), let n = Int(a.dropFirst(2)) { maxArgs = max(1, n) }
            else if a == "-I", let r = arguments.first { replace = r; arguments.removeFirst(); maxArgs = 1 }
            else if a == "-0" || a == "-r" || a == "-t" { continue }
        }
        if arguments.isEmpty { arguments = ["echo"] }
        let input = String(decoding: context.stdin.readAll(), as: UTF8.self)
        let items: [String] = replace != nil
            ? input.split(separator: "\n").map(String.init)
            : input.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        if items.isEmpty { return 0 }
        var status: Int32 = 0
        let streams = StandardStreams(stdin: EmptyInputStream(), stdout: context.stdout, stderr: context.stderr)
        var i = 0
        while i < items.count && !context.isCancelled {
            let batch = Array(items[i..<min(items.count, i + maxArgs)])
            i += batch.count
            let argumentVector: [String]
            if let r = replace { argumentVector = arguments.map { $0.replacingOccurrences(of: r, with: batch[0]) } } else { argumentVector = arguments + batch }
            let s = context.shell.runCommand(argumentVector, streams: streams, cancellation: context.cancellation, environment: context.environment)
            if s != 0 { status = 123 }
            if s == 127 { return 127 }
        }
        return status
    }

    static func base64(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "di", withValues: "w", longFlags: ["decode", "ignore-garbage"])
        if let e = options.error { context.error(e); return 1 }
        let decode = options.has("d") || options.longFlags.contains("decode")
        let input: ShellInputStream
        if let f = options.operands.first { guard let i = context.openInput(f) else { return 1 }; input = i } else { input = context.stdin }
        let data = Data(input.readAll())
        if decode {
            let text = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            var padded = text
            while padded.count % 4 != 0 { padded += "=" }
            guard let d = Data(base64Encoded: padded) else { context.error("invalid input"); return 1 }
            context.stdout.write([UInt8](d))
            return 0
        }
        let width = Int(options.value("w") ?? "76") ?? 76
        let encoded = data.base64EncodedString()
        if width <= 0 { context.print(encoded); return 0 }
        var index = encoded.startIndex
        var out = ""
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: width, limitedBy: encoded.endIndex) ?? encoded.endIndex
            out += encoded[index..<end] + "\n"
            index = end
        }
        context.stdout.write(out)
        return 0
    }

    static func checksum(_ context: CommandContext, _ hash: ([UInt8]) -> [UInt8]) -> Int32 {
        let files = context.arguments.filter { !$0.hasPrefix("-") || $0 == "-" }
        return context.forEachInput(files) { input, name in
            let digest = hash(input.readAll())
            context.print(Hashing.hex(digest) + "  " + name)
        }
    }

    static func printable(_ b: UInt8) -> Character { (0x20..<0x7F).contains(b) ? Character(Unicode.Scalar(b)) : "." }

    static func xxd(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "pur", withValues: "lsc")
        if let e = options.error { context.error(e); return 1 }
        let input: ShellInputStream
        if let f = options.operands.first { guard let i = context.openInput(f) else { return 1 }; input = i } else { input = context.stdin }
        var data = input.readAll()
        if options.has("r") {
            let text = String(decoding: data, as: UTF8.self)
            var bytes: [UInt8] = []
            for line in text.split(separator: "\n") {
                var hexPart = Substring(line)
                if !options.has("p"), let colon = line.firstIndex(of: ":") {
                    hexPart = line[line.index(after: colon)...]
                    if let doubleSpace = hexPart.range(of: "  ") { hexPart = hexPart[..<doubleSpace.lowerBound] }
                }
                let digits = hexPart.filter { $0.isHexDigit }
                var it = digits.startIndex
                while it < digits.endIndex, let next = digits.index(it, offsetBy: 2, limitedBy: digits.endIndex) {
                    if let b = UInt8(digits[it..<next], radix: 16) { bytes.append(b) }
                    it = next
                }
            }
            context.stdout.write(bytes)
            return 0
        }
        if let s = options.value("s").flatMap({ Int($0) }) { data = Array(data.dropFirst(s)) }
        if let l = options.value("l").flatMap({ Int($0) }) { data = Array(data.prefix(l)) }
        let upper = options.has("u")
        func hex(_ b: UInt8) -> String { String(format: upper ? "%02X" : "%02x", b) }
        if options.has("p") {
            let columnCount = Int(options.value("c") ?? "30") ?? 30
            var line = ""
            for (i, b) in data.enumerated() {
                line += hex(b)
                if (i + 1) % columnCount == 0 { context.print(line); line = "" }
            }
            if !line.isEmpty { context.print(line) }
            return 0
        }
        let columnCount = max(1, Int(options.value("c") ?? "16") ?? 16)
        let start = options.value("s").flatMap { Int($0) } ?? 0
        var offset = 0
        while offset < data.count && !context.shouldStop {
            let chunk = data[offset..<min(data.count, offset + columnCount)]
            var hexText = ""
            for (k, b) in chunk.enumerated() { hexText += hex(b); if k % 2 == 1 { hexText += " " } }
            let fullWidth = columnCount * 2 + (columnCount + 1) / 2
            context.print(String(format: "%08x", start + offset) + ": " + ShellFormat.pad(hexText, fullWidth) + " " + String(chunk.map(printable)))
            offset += columnCount
        }
        return 0
    }

    static func hexdump(_ context: CommandContext) -> Int32 {
        let files = context.arguments.filter { !$0.hasPrefix("-") }
        var data: [UInt8] = []
        let status = context.forEachInput(files) { input, _ in data.append(contentsOf: input.readAll()) }
        var offset = 0
        var lastLine: ArraySlice<UInt8>? = nil
        var starred = false
        while offset < data.count && !context.shouldStop {
            let chunk = data[offset..<min(data.count, offset + 16)]
            if let l = lastLine, l == chunk, chunk.count == 16 {
                if !starred { context.print("*"); starred = true }
                offset += 16; continue
            }
            starred = false
            lastLine = chunk
            var hexText = ""
            for (k, b) in chunk.enumerated() { hexText += String(format: "%02x ", b); if k == 7 { hexText += " " } }
            context.print(String(format: "%08x", offset) + "  " + ShellFormat.pad(hexText, 49) + " |" + String(chunk.map(printable)) + "|")
            offset += 16
        }
        if !data.isEmpty { context.print(String(format: "%08x", data.count)) }
        return status
    }
}

extension CommandContext {
    func openInputQuiet(_ path: String, quiet: Bool) -> ShellInputStream? {
        if !quiet { return openInput(path) }
        let full = resolve(path)
        return FileInputStream(path: full)
    }
}

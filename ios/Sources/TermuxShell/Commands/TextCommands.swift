import Foundation

/// Text processing commands (head, tail, wc, grep, sort, uniq, cut, tr, sed, ...).
enum TextCommands {
    static func register(_ r: CommandRegistry) {
        r.register("head", "output the first lines of files (-n N, -c N)") { headTail($0, head: true) }
        r.register("tail", "output the last lines of files (-n N, -n +N, -c N)") { headTail($0, head: false) }
        r.register("wc", "count lines, words and bytes (-l -w -c -m)") { wc($0) }
        r.register("grep", "search for patterns (-i -v -n -r -c -l -E -F -o -w -q)") { grep($0) }
        r.register("egrep", "") { ctx in grep(ctx, extended: true) }
        r.register("fgrep", "") { ctx in grep(ctx, fixed: true) }
        r.register("sort", "sort lines (-r -n -u -f -k N -t SEP)") { sort($0) }
        r.register("uniq", "filter repeated lines (-c -d -u -i)") { uniq($0) }
        r.register("cut", "select fields or characters (-d SEP -f LIST, -c LIST)") { cut($0) }
        r.register("tr", "translate or delete characters (-d -s)") { tr($0) }
        r.register("sed", "stream editor (s/regex/replacement/[gip], -n -e -E -i, p d)") { sed($0) }
        r.register("tee", "copy stdin to stdout and files (-a)") { tee($0) }
        r.register("rev", "reverse lines characterwise") { ctx in
            ctx.forEachInput(ctx.args) { input, _ in
                let reader = LineReader(input)
                while !ctx.shouldStop, let l = reader.nextLine() { ctx.print(String(l.reversed())) }
            }
        }
        r.register("nl", "number lines") { ctx in
            var n = 0
            return ctx.forEachInput(ctx.args) { input, _ in
                let reader = LineReader(input)
                while !ctx.shouldStop, let l = reader.nextLine() {
                    if l.isEmpty { ctx.print(); continue }
                    n += 1; ctx.print(ShellFormat.pad(String(n), 6, right: true) + "\t" + l)
                }
            }
        }
        r.register("xargs", "build and run commands from stdin") { xargs($0) }
        r.register("base64", "base64 encode/decode (-d, -w COLS)") { base64($0) }
        r.register("md5sum", "compute MD5 checksums") { ctx in checksum(ctx) { Hashing.md5($0) } }
        r.register("sha1sum", "compute SHA-1 checksums") { ctx in checksum(ctx) { Hashing.sha1($0) } }
        r.register("sha256sum", "compute SHA-256 checksums") { ctx in checksum(ctx) { Hashing.sha256($0) } }
        r.register("xxd", "hex dump (-l LEN, -s SKIP, -c COLS, -p plain)") { xxd($0) }
        r.register("hexdump", "hex dump in canonical format (-C)") { hexdump($0) }
        r.alias("hd", to: "hexdump")
    }

    // MARK: head / tail

    static func headTail(_ ctx: CommandContext, head: Bool) -> Int32 {
        // Support the obsolete `head -5` form.
        let args = ctx.args.map { a -> String in
            if a.count > 1, a.hasPrefix("-"), Int(a.dropFirst()) != nil { return "-n" + a.dropFirst() }
            return a
        }
        let opts = ParsedOptions(args, flags: "qvf", withValues: "nc")
        if let e = opts.error { ctx.error(e); return 1 }
        var countText = opts.value("n") ?? "10"
        let bytesMode = opts.value("c") != nil
        if let c = opts.value("c") { countText = c }
        let fromStart = !head && countText.hasPrefix("+")
        let allBut = head && countText.hasPrefix("-")
        guard let count = Int(countText.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) else {
            ctx.error("invalid number of lines: '\(countText)'"); return 1
        }
        let files = opts.operands
        let showHeaders = (files.count > 1 && !opts.has("q")) || opts.has("v")
        var first = true
        return ctx.forEachInput(files) { input, name in
            if showHeaders {
                ctx.print((first ? "" : "\n") + "==> \(name == "-" ? "standard input" : name) <==")
            }
            first = false
            if bytesMode {
                if head && !allBut {
                    var remaining = count
                    while remaining > 0, !ctx.shouldStop, let chunk = input.read(maxLength: min(remaining, 65536)) {
                        ctx.stdout.write(chunk); remaining -= chunk.count
                    }
                    return
                }
                let all = input.readAll()
                if head { ctx.stdout.write(Array(all.dropLast(count))) }
                else if fromStart { ctx.stdout.write(Array(all.dropFirst(max(0, count - 1)))) }
                else { ctx.stdout.write(Array(all.suffix(count))) }
                return
            }
            let reader = LineReader(input)
            if head && !allBut {
                var n = 0
                while n < count, !ctx.shouldStop, let line = reader.nextLineBytes() { ctx.stdout.write(line + [0x0A]); n += 1 }
                return
            }
            if fromStart {
                var n = 1
                while !ctx.shouldStop, let line = reader.nextLineBytes() {
                    if n >= count { ctx.stdout.write(line + [0x0A]) }
                    n += 1
                }
                return
            }
            var ring: [[UInt8]] = []
            while !ctx.isCancelled, let line = reader.nextLineBytes() {
                if allBut { ring.append(line) } else {
                    ring.append(line)
                    if ring.count > count { ring.removeFirst() }
                }
            }
            if allBut { ring = Array(ring.dropLast(count)) }
            for line in ring { ctx.stdout.write(line + [0x0A]) }
        }
    }

    // MARK: wc

    static func wc(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "lwcmL")
        if let e = opts.error { ctx.error(e); return 1 }
        var show = (l: opts.has("l"), w: opts.has("w"), c: opts.has("c"), m: opts.has("m"))
        if !show.l && !show.w && !show.c && !show.m { show = (true, true, true, false) }
        var rows: [([Int], String)] = []
        var totals = [0, 0, 0, 0]
        let status = ctx.forEachInput(opts.operands) { input, name in
            let data = input.readAll()
            let lines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            let text = String(decoding: data, as: UTF8.self)
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let values = [lines, words, text.count, data.count]
            for k in 0..<4 { totals[k] += values[k] }
            rows.append((values, name == "-" ? "" : name))
        }
        if rows.count > 1 { rows.append((totals, "total")) }
        let width = rows.count == 1 && opts.operands.isEmpty ? 0 : max(1, String(totals.max() ?? 0).count)
        for (values, name) in rows {
            var parts: [String] = []
            if show.l { parts.append(ShellFormat.pad(String(values[0]), width, right: true)) }
            if show.w { parts.append(ShellFormat.pad(String(values[1]), width, right: true)) }
            if show.m { parts.append(ShellFormat.pad(String(values[2]), width, right: true)) }
            if show.c { parts.append(ShellFormat.pad(String(values[3]), width, right: true)) }
            if !name.isEmpty { parts.append(name) }
            ctx.print(parts.joined(separator: " "))
        }
        return status
    }

    // MARK: Regex helpers

    /// Converts a POSIX basic regular expression to the extended (ICU) syntax used by NSRegularExpression.
    static func basicToExtended(_ bre: String) -> String {
        var out = ""
        var chars = Array(bre)[...]
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

    /// Adapts POSIX bracket expressions and other differences to ICU syntax.
    static func posixToICU(_ re: String) -> String {
        var s = re
        let classes = ["[:alpha:]": "\\p{L}", "[:digit:]": "0-9", "[:alnum:]": "\\p{L}0-9", "[:upper:]": "\\p{Lu}",
                       "[:lower:]": "\\p{Ll}", "[:space:]": "\\s", "[:blank:]": " \\t", "[:punct:]": "\\p{P}\\p{S}",
                       "[:xdigit:]": "0-9A-Fa-f", "[:cntrl:]": "\\x00-\\x1f", "[:print:]": "\\x20-\\x7e", "[:graph:]": "\\x21-\\x7e"]
        for (k, v) in classes { s = s.replacingOccurrences(of: k, with: v) }
        // `\<` / `\>` word boundaries
        s = s.replacingOccurrences(of: "\\<", with: "\\b").replacingOccurrences(of: "\\>", with: "\\b")
        return s
    }

    static func makeRegex(_ pattern: String, extended: Bool, fixed: Bool, ignoreCase: Bool, word: Bool = false, line: Bool = false) -> NSRegularExpression? {
        var p = fixed ? NSRegularExpression.escapedPattern(for: pattern) : posixToICU(extended ? pattern : basicToExtended(pattern))
        if word { p = "\\b(?:" + p + ")\\b" }
        if line { p = "^(?:" + p + ")$" }
        return try? NSRegularExpression(pattern: p, options: ignoreCase ? [.caseInsensitive] : [])
    }

    // MARK: grep

    static func grep(_ ctx: CommandContext, extended: Bool = false, fixed: Bool = false) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "ivnrRclLEFowqhHsx", withValues: "eAB")
        if let e = opts.error { ctx.error(e); return 2 }
        var operands = opts.operands
        var patterns: [String] = []
        if let e = opts.value("e") { patterns.append(e) } else {
            guard !operands.isEmpty else { ctx.stderr.writeLine("usage: grep [-ivnrclEFowq] PATTERN [FILE...]"); return 2 }
            patterns.append(operands.removeFirst())
        }
        let ignoreCase = opts.has("i"), invert = opts.has("v"), lineNumbers = opts.has("n")
        let countOnly = opts.has("c"), filesOnly = opts.has("l"), filesWithout = opts.has("L"), quiet = opts.has("q")
        let onlyMatching = opts.has("o"), recursive = opts.has("r") || opts.has("R")
        let regexes = patterns.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }.compactMap {
            makeRegex($0, extended: extended || opts.has("E"), fixed: fixed || opts.has("F"), ignoreCase: ignoreCase,
                      word: opts.has("w"), line: opts.has("x"))
        }
        guard !regexes.isEmpty else { ctx.error("invalid regular expression"); return 2 }
        let color = ctx.stdout.isTerminal && !(ctx.environment["GREP_COLOR"] == "never")

        // Collect files (expanding directories for -r).
        var files: [String] = []
        if recursive && operands.isEmpty { operands = ["."] }
        var status: Int32 = 1
        var hadError = false
        for op in operands {
            let path = ctx.resolve(op)
            if let info = FileInfo(path: path, follow: true), info.isDirectory {
                if !recursive { if !opts.has("s") { ctx.error("\(op): Is a directory") }; continue }
                if let en = FileManager.default.enumerator(atPath: path) {
                    var found: [String] = []
                    while let rel = en.nextObject() as? String {
                        let full = path + "/" + rel
                        if FileInfo(path: full, follow: false)?.isRegular == true {
                            found.append(op == "." && !ctx.args.contains(".") ? rel : (op.hasSuffix("/") ? op + rel : op + "/" + rel))
                        }
                    }
                    files.append(contentsOf: found.sorted())
                }
            } else {
                files.append(op)
            }
        }
        let showNames = opts.has("H") || (!opts.has("h") && (files.count > 1 || recursive))

        func matchRanges(_ line: String) -> [NSRange] {
            let ns = line as NSString
            var ranges: [NSRange] = []
            for re in regexes {
                for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 || regexes.count == 1 {
                    ranges.append(m.range)
                }
            }
            return ranges.sorted { $0.location < $1.location }
        }
        func isMatch(_ line: String) -> Bool {
            let range = NSRange(location: 0, length: (line as NSString).length)
            return regexes.contains { $0.firstMatch(in: line, range: range) != nil }
        }

        func process(_ input: ShellInputStream, _ name: String) -> Bool {
            let reader = LineReader(input)
            var count = 0
            var lineNo = 0
            let display = name == "-" ? "(standard input)" : name
            let prefixName = showNames ? (color ? ANSI.magenta + display + ANSI.reset + ANSI.cyan + ":" + ANSI.reset : display + ":") : ""
            while !ctx.shouldStop, let line = reader.nextLine() {
                lineNo += 1
                let matched = isMatch(line) != invert
                guard matched else { continue }
                count += 1
                if quiet { return true }
                if filesOnly || filesWithout { break }
                if countOnly { continue }
                let numberPrefix = lineNumbers ? (color ? ANSI.green + String(lineNo) + ANSI.reset + ANSI.cyan + ":" + ANSI.reset : "\(lineNo):") : ""
                if onlyMatching && !invert {
                    let ns = line as NSString
                    for r in matchRanges(line) where r.length > 0 {
                        let s = ns.substring(with: r)
                        ctx.print(prefixName + numberPrefix + (color ? ANSI.boldRed + s + ANSI.reset : s))
                    }
                    continue
                }
                var shown = line
                if color && !invert {
                    let ns = line as NSString
                    var out = ""
                    var last = 0
                    for r in matchRanges(line) where r.location >= last && r.length > 0 {
                        out += ns.substring(with: NSRange(location: last, length: r.location - last))
                        out += ANSI.boldRed + ns.substring(with: r) + ANSI.reset
                        last = r.location + r.length
                    }
                    out += ns.substring(from: last)
                    shown = out
                }
                ctx.print(prefixName + numberPrefix + shown)
            }
            if countOnly { ctx.print((showNames ? display + ":" : "") + String(count)) }
            if filesOnly && count > 0 { ctx.print(display) }
            if filesWithout && count == 0 { ctx.print(display) }
            return count > 0
        }

        if files.isEmpty {
            if process(ctx.stdin, "-") { status = 0 }
        } else {
            for f in files {
                if ctx.shouldStop { break }
                guard let input = ctx.openInputQuiet(f, quiet: opts.has("s")) else { hadError = true; continue }
                if process(input, f) { status = 0; if quiet { break } }
                input.close()
            }
        }
        if hadError && status != 0 { return 2 }
        return status
    }

    // MARK: sort / uniq

    static func sort(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "rnufbhVR", withValues: "kto")
        if let e = opts.error { ctx.error(e); return 2 }
        var lines: [String] = []
        let status = ctx.forEachInput(opts.operands) { input, _ in lines.append(contentsOf: LineReader(input).allLines()) }
        let sep = opts.value("t").flatMap { $0.first }
        let keyField = opts.value("k").flatMap { Int($0.split(separator: ",").first.map { String($0.prefix { $0.isNumber }) } ?? "") }
        func key(_ line: String) -> String {
            var k = line
            if let f = keyField {
                let fields: [String] = sep != nil ? line.split(separator: sep!, omittingEmptySubsequences: false).map(String.init)
                                                  : line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                k = f - 1 < fields.count ? fields[(f - 1)...].joined(separator: sep.map(String.init) ?? " ") : ""
            }
            if opts.has("b") { k = k.trimmingCharacters(in: .whitespaces) }
            if opts.has("f") { k = k.lowercased() }
            return k
        }
        func number(_ s: String) -> Double {
            let t = s.trimmingCharacters(in: .whitespaces)
            var prefix = ""
            for c in t { if c.isNumber || c == "." || (c == "-" && prefix.isEmpty) { prefix.append(c) } else { break } }
            var v = Double(prefix) ?? 0
            if opts.has("h"), let unit = t.dropFirst(prefix.count).first, let idx = "KMGTP".firstIndex(of: Character(unit.uppercased())) {
                v *= pow(1024, Double("KMGTP".distance(from: "KMGTP".startIndex, to: idx) + 1))
            }
            return v
        }
        let keyed = lines.map { (key($0), $0) }
        var sorted: [(String, String)]
        if opts.has("R") {
            sorted = keyed.shuffled()
        } else if opts.has("n") || opts.has("h") {
            let numbered: [(Double, String, String)] = keyed.map { (number($0.0), $0.0, $0.1) }
            let order = numbered.indices.sorted { i, j in
                let a = numbered[i], b = numbered[j]
                if a.0 != b.0 { return a.0 < b.0 }
                if a.2 != b.2 { return a.2 < b.2 }
                return i < j
            }
            sorted = order.map { (numbered[$0].1, numbered[$0].2) }
        } else if opts.has("V") {
            sorted = keyed.sorted { $0.0.compare($1.0, options: .numeric) == .orderedAscending }
        } else {
            sorted = keyed.enumerated().sorted { a, b in
                a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset
            }.map { $0.element }
        }
        if opts.has("r") { sorted.reverse() }
        var out = sorted.map { $0.1 }
        if opts.has("u") {
            var seen = Set<String>()
            out = sorted.filter { seen.insert($0.0).inserted }.map { $0.1 }
        }
        let text = out.map { $0 + "\n" }.joined()
        if let o = opts.value("o") {
            guard let f = FileOutputStream(path: ctx.resolve(o), append: false) else { ctx.error("cannot open '\(o)' for writing"); return 2 }
            f.write(text); f.close()
        } else {
            ctx.stdout.write(text)
        }
        return status == 0 ? 0 : 2
    }

    static func uniq(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "cdui")
        if let e = opts.error { ctx.error(e); return 1 }
        let input: ShellInputStream
        if let f = opts.operands.first { guard let i = ctx.openInput(f) else { return 1 }; input = i } else { input = ctx.stdin }
        let reader = LineReader(input)
        var prev: String? = nil
        var count = 0
        func emit() {
            guard let p = prev else { return }
            if opts.has("d") && count < 2 { return }
            if opts.has("u") && count > 1 { return }
            ctx.print(opts.has("c") ? ShellFormat.pad(String(count), 7, right: true) + " " + p : p)
        }
        while !ctx.shouldStop, let line = reader.nextLine() {
            if let p = prev, opts.has("i") ? p.lowercased() == line.lowercased() : p == line { count += 1; continue }
            emit()
            prev = line; count = 1
        }
        emit()
        return 0
    }

    // MARK: cut

    static func parseList(_ s: String) -> [(Int, Int)]? {
        var ranges: [(Int, Int)] = []
        for part in s.split(separator: ",") {
            if part.contains("-") {
                let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                let lo = ends[0].isEmpty ? 1 : Int(ends[0])
                let hi = ends.count > 1 && !ends[1].isEmpty ? Int(ends[1]) : Int.max
                guard let l = lo, let h = hi, l >= 1, h >= l else { return nil }
                ranges.append((l, h))
            } else {
                guard let n = Int(part), n >= 1 else { return nil }
                ranges.append((n, n))
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    static func cut(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "s", withValues: "dfcb")
        if let e = opts.error { ctx.error(e); return 1 }
        let fieldList = opts.value("f"), charList = opts.value("c") ?? opts.value("b")
        guard let listText = fieldList ?? charList, let ranges = parseList(listText) else {
            ctx.error("you must specify a list of bytes, characters, or fields"); return 1
        }
        func selected(_ i: Int) -> Bool { ranges.contains { $0.0 <= i && i <= $0.1 } }
        let delim = opts.value("d").map { $0.isEmpty ? "\t" : String($0.prefix(1)) } ?? "\t"
        return ctx.forEachInput(opts.operands) { input, _ in
            let reader = LineReader(input)
            while !ctx.shouldStop, let line = reader.nextLine() {
                if fieldList != nil {
                    guard line.contains(delim) else { if !opts.has("s") { ctx.print(line) }; continue }
                    let fields = line.components(separatedBy: delim)
                    ctx.print(fields.enumerated().filter { selected($0.offset + 1) }.map { $0.element }.joined(separator: delim))
                } else {
                    ctx.print(String(Array(line).enumerated().filter { selected($0.offset + 1) }.map { $0.element }))
                }
            }
        }
    }

    // MARK: tr

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
                if let cls = classes[name] { out.append(contentsOf: cls); i = end + 1; continue }
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

    static func tr(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "dscC")
        if let e = opts.error { ctx.error(e); return 1 }
        let ops = opts.operands
        guard !ops.isEmpty else { ctx.error("missing operand"); return 1 }
        let set1 = expandSet(ops[0])
        let set2 = ops.count > 1 ? expandSet(ops[1]) : []
        let complement = opts.has("c") || opts.has("C")
        let member = Set(set1)
        func inSet1(_ c: Character) -> Bool { member.contains(c) != complement }
        if !opts.has("d") && !opts.has("s") && set2.isEmpty { ctx.error("missing operand after '\(ops[0])'"); return 1 }
        var map: [Character: Character] = [:]
        if !opts.has("d") && !set2.isEmpty && !complement {
            for (i, c) in set1.enumerated() { map[c] = i < set2.count ? set2[i] : set2.last! }
        }
        let squeezeSet = Set(opts.has("d") ? set2 : (set2.isEmpty ? set1 : set2))
        let reader = ctx.stdin
        var lastOut: Character? = nil
        while !ctx.shouldStop, let chunk = reader.read(maxLength: 65536) {
            var out = ""
            for c in String(decoding: chunk, as: UTF8.self) {
                var ch = c
                if opts.has("d") && inSet1(ch) { continue }
                if !opts.has("d") {
                    if complement && !set2.isEmpty && inSet1(ch) { ch = set2.last! }
                    else if let m = map[ch] { ch = m }
                }
                if opts.has("s") && squeezeSet.contains(ch) && lastOut == ch { continue }
                out.append(ch); lastOut = ch
            }
            ctx.stdout.write(out)
        }
        return 0
    }

    // MARK: sed

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
        case regex(NSRegularExpression)
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
                guard let re = readDelimited("/"), let rx = makeRegex(re, extended: extended, fixed: false, ignoreCase: false) else { return nil }
                address = .regex(rx)
            }
            guard let cmd = chars.first else { return nil }
            chars = chars.dropFirst()
            switch cmd {
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
                guard let re = makeRegex(pattern, extended: extended, fixed: false, ignoreCase: ignoreCase) else { return nil }
                result.append(SedScript(address: address, command: .substitute(re, convertReplacement(replacement), global: global, occurrence: occurrence, print: print)))
            case "d": result.append(SedScript(address: address, command: .delete))
            case "p": result.append(SedScript(address: address, command: .print))
            case "q": result.append(SedScript(address: address, command: .quit))
            default: return nil
            }
        }
        return result
    }

    /// Converts sed replacement syntax (`&`, `\1`) to an NSRegularExpression template.
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

    static func sed(_ ctx: CommandContext) -> Int32 {
        var args = ctx.args
        var scripts: [String] = []
        var quietMode = false, extended = false, inPlace = false
        var files: [String] = []
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "-n", "--quiet", "--silent": quietMode = true
            case "-E", "-r", "--regexp-extended": extended = true
            case "-i": inPlace = true
            case "-e": if !args.isEmpty { scripts.append(args.removeFirst()) }
            default:
                if a.hasPrefix("-") && a.count > 1 && !a.hasPrefix("--") && a.dropFirst().allSatisfy({ "nErie".contains($0) }) {
                    if a.contains("n") { quietMode = true }
                    if a.contains("E") || a.contains("r") { extended = true }
                    if a.contains("i") { inPlace = true }
                    if a.hasSuffix("e"), !args.isEmpty { scripts.append(args.removeFirst()) }
                } else if scripts.isEmpty && !a.hasPrefix("-") {
                    scripts.append(a)
                } else {
                    files.append(a)
                }
            }
        }
        guard !scripts.isEmpty else { ctx.stderr.writeLine("usage: sed [-nE] [-i] 's/regex/replacement/[g]' [FILE...]"); return 1 }
        guard let program = parseSed(scripts.joined(separator: "\n"), extended: extended) else {
            ctx.error("unsupported or invalid script: \(scripts.joined(separator: "; "))"); return 1
        }

        func runSed(_ lines: [String], emit: (String) -> Void) {
            var inRange = Array(repeating: false, count: program.count)
            outer: for (idx, line) in lines.enumerated() {
                if ctx.isCancelled { break }
                var pattern = line
                var deleted = false
                let lineNo = idx + 1
                for (k, s) in program.enumerated() {
                    if let addr = s.address {
                        let applies: Bool
                        switch addr {
                        case .line(let n): applies = lineNo == n
                        case .last: applies = idx == lines.count - 1
                        case .regex(let re): applies = re.firstMatch(in: pattern, range: NSRange(location: 0, length: (pattern as NSString).length)) != nil
                        case .range(let a, let b):
                            if lineNo == a { inRange[k] = true }
                            applies = inRange[k] && lineNo <= b
                            if lineNo >= b { inRange[k] = false }
                        }
                        if !applies { continue }
                    }
                    switch s.command {
                    case .delete: deleted = true; break
                    case .print: emit(pattern)
                    case .quit:
                        if !quietMode { emit(pattern) }
                        break outer
                    case .substitute(let re, let template, let global, let occurrence, let printFlag):
                        let ns = pattern as NSString
                        let matches = re.matches(in: pattern, range: NSRange(location: 0, length: ns.length))
                        guard !matches.isEmpty else { continue }
                        let targets = global ? Array(matches.dropFirst(occurrence - 1)) : (matches.count >= occurrence ? [matches[occurrence - 1]] : [])
                        guard !targets.isEmpty else { continue }
                        var out = ""
                        var last = 0
                        for m in targets {
                            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                            out += re.replacementString(for: m, in: pattern, offset: 0, template: template)
                            last = m.range.location + m.range.length
                        }
                        out += ns.substring(from: last)
                        pattern = out
                        if printFlag { emit(pattern) }
                    }
                    if deleted { break }
                }
                if !deleted && !quietMode { emit(pattern) }
            }
        }

        if inPlace {
            guard !files.isEmpty else { ctx.error("no input files"); return 1 }
            var status: Int32 = 0
            for f in files {
                let path = ctx.resolve(f)
                guard let data = FileManager.default.contents(atPath: path) else { ctx.error("can't read \(f): No such file or directory"); status = 1; continue }
                var text = String(decoding: data, as: UTF8.self)
                let hadTrailingNewline = text.hasSuffix("\n")
                if hadTrailingNewline { text.removeLast() }
                var out = ""
                runSed(text.isEmpty && !hadTrailingNewline ? [] : text.components(separatedBy: "\n")) { out += $0 + "\n" }
                do { try out.write(toFile: path, atomically: true, encoding: .utf8) } catch { ctx.error("couldn't write \(f)"); status = 1 }
            }
            return status
        }
        var lines: [String] = []
        let status = ctx.forEachInput(files) { input, _ in lines.append(contentsOf: LineReader(input).allLines()) }
        runSed(lines) { ctx.print($0) }
        return status
    }

    // MARK: tee / xargs

    static func tee(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "ai")
        var outs: [FileOutputStream] = []
        var status: Int32 = 0
        for f in opts.operands {
            if let o = FileOutputStream(path: ctx.resolve(f), append: opts.has("a")) { outs.append(o) }
            else { ctx.error("\(f): No such file or directory"); status = 1 }
        }
        while !ctx.isCancelled, let chunk = ctx.stdin.read(maxLength: 65536) {
            ctx.stdout.write(chunk)
            outs.forEach { $0.write(chunk) }
        }
        outs.forEach { $0.close() }
        return status
    }

    static func xargs(_ ctx: CommandContext) -> Int32 {
        var args = ctx.args
        var maxArgs = Int.max
        var replace: String? = nil
        while let a = args.first, a.hasPrefix("-") {
            args.removeFirst()
            if a == "-n", let n = args.first.flatMap({ Int($0) }) { maxArgs = max(1, n); args.removeFirst() }
            else if a.hasPrefix("-n"), let n = Int(a.dropFirst(2)) { maxArgs = max(1, n) }
            else if a == "-I", let r = args.first { replace = r; args.removeFirst(); maxArgs = 1 }
            else if a == "-0" || a == "-r" || a == "-t" { continue }
        }
        if args.isEmpty { args = ["echo"] }
        let input = String(decoding: ctx.stdin.readAll(), as: UTF8.self)
        let items: [String] = replace != nil
            ? input.split(separator: "\n").map(String.init)
            : input.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        if items.isEmpty { return 0 }
        var status: Int32 = 0
        let io = ShellIO(stdin: EmptyInputStream(), stdout: ctx.stdout, stderr: ctx.stderr)
        var i = 0
        while i < items.count && !ctx.isCancelled {
            let batch = Array(items[i..<min(items.count, i + maxArgs)])
            i += batch.count
            let argv: [String]
            if let r = replace { argv = args.map { $0.replacingOccurrences(of: r, with: batch[0]) } } else { argv = args + batch }
            let s = ctx.shell.runCommand(argv, io: io, cancellation: ctx.cancellation, environment: ctx.environment)
            if s != 0 { status = 123 }
            if s == 127 { return 127 }
        }
        return status
    }

    // MARK: base64 / checksums / hex

    static func base64(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "di", withValues: "w", longFlags: ["decode", "ignore-garbage"])
        if let e = opts.error { ctx.error(e); return 1 }
        let decode = opts.has("d") || opts.longFlags.contains("decode")
        let input: ShellInputStream
        if let f = opts.operands.first { guard let i = ctx.openInput(f) else { return 1 }; input = i } else { input = ctx.stdin }
        let data = Data(input.readAll())
        if decode {
            let text = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            var padded = text
            while padded.count % 4 != 0 { padded += "=" }
            guard let d = Data(base64Encoded: padded) else { ctx.error("invalid input"); return 1 }
            ctx.stdout.write([UInt8](d))
            return 0
        }
        let width = Int(opts.value("w") ?? "76") ?? 76
        let encoded = data.base64EncodedString()
        if width <= 0 { ctx.print(encoded); return 0 }
        var idx = encoded.startIndex
        var out = ""
        while idx < encoded.endIndex {
            let end = encoded.index(idx, offsetBy: width, limitedBy: encoded.endIndex) ?? encoded.endIndex
            out += encoded[idx..<end] + "\n"
            idx = end
        }
        ctx.stdout.write(out)
        return 0
    }

    static func checksum(_ ctx: CommandContext, _ hash: ([UInt8]) -> [UInt8]) -> Int32 {
        let files = ctx.args.filter { !$0.hasPrefix("-") || $0 == "-" }
        return ctx.forEachInput(files) { input, name in
            let digest = hash(input.readAll())
            ctx.print(Hashing.hex(digest) + "  " + name)
        }
    }

    static func printable(_ b: UInt8) -> Character { (0x20..<0x7F).contains(b) ? Character(Unicode.Scalar(b)) : "." }

    static func xxd(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "pur", withValues: "lsc")
        if let e = opts.error { ctx.error(e); return 1 }
        let input: ShellInputStream
        if let f = opts.operands.first { guard let i = ctx.openInput(f) else { return 1 }; input = i } else { input = ctx.stdin }
        var data = input.readAll()
        if opts.has("r") {
            // Reverse a plain (-p) or canonical dump.
            let text = String(decoding: data, as: UTF8.self)
            var bytes: [UInt8] = []
            for line in text.split(separator: "\n") {
                var hexPart = Substring(line)
                if !opts.has("p"), let colon = line.firstIndex(of: ":") {
                    hexPart = line[line.index(after: colon)...]
                    if let dbl = hexPart.range(of: "  ") { hexPart = hexPart[..<dbl.lowerBound] }
                }
                let digits = hexPart.filter { $0.isHexDigit }
                var it = digits.startIndex
                while it < digits.endIndex, let next = digits.index(it, offsetBy: 2, limitedBy: digits.endIndex) {
                    if let b = UInt8(digits[it..<next], radix: 16) { bytes.append(b) }
                    it = next
                }
            }
            ctx.stdout.write(bytes)
            return 0
        }
        if let s = opts.value("s").flatMap({ Int($0) }) { data = Array(data.dropFirst(s)) }
        if let l = opts.value("l").flatMap({ Int($0) }) { data = Array(data.prefix(l)) }
        let upper = opts.has("u")
        func hex(_ b: UInt8) -> String { String(format: upper ? "%02X" : "%02x", b) }
        if opts.has("p") {
            let cols = Int(opts.value("c") ?? "30") ?? 30
            var line = ""
            for (i, b) in data.enumerated() {
                line += hex(b)
                if (i + 1) % cols == 0 { ctx.print(line); line = "" }
            }
            if !line.isEmpty { ctx.print(line) }
            return 0
        }
        let cols = max(1, Int(opts.value("c") ?? "16") ?? 16)
        let start = opts.value("s").flatMap { Int($0) } ?? 0
        var offset = 0
        while offset < data.count && !ctx.shouldStop {
            let chunk = data[offset..<min(data.count, offset + cols)]
            var hexs = ""
            for (k, b) in chunk.enumerated() { hexs += hex(b); if k % 2 == 1 { hexs += " " } }
            let fullWidth = cols * 2 + (cols + 1) / 2
            ctx.print(String(format: "%08x", start + offset) + ": " + ShellFormat.pad(hexs, fullWidth) + " " + String(chunk.map(printable)))
            offset += cols
        }
        return 0
    }

    static func hexdump(_ ctx: CommandContext) -> Int32 {
        let files = ctx.args.filter { !$0.hasPrefix("-") }
        var data: [UInt8] = []
        let status = ctx.forEachInput(files) { input, _ in data.append(contentsOf: input.readAll()) }
        var offset = 0
        var lastLine: ArraySlice<UInt8>? = nil
        var starred = false
        while offset < data.count && !ctx.shouldStop {
            let chunk = data[offset..<min(data.count, offset + 16)]
            if let l = lastLine, l == chunk, chunk.count == 16 {
                if !starred { ctx.print("*"); starred = true }
                offset += 16; continue
            }
            starred = false
            lastLine = chunk
            var hexs = ""
            for (k, b) in chunk.enumerated() { hexs += String(format: "%02x ", b); if k == 7 { hexs += " " } }
            ctx.print(String(format: "%08x", offset) + "  " + ShellFormat.pad(hexs, 49) + " |" + String(chunk.map(printable)) + "|")
            offset += 16
        }
        if !data.isEmpty { ctx.print(String(format: "%08x", data.count)) }
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

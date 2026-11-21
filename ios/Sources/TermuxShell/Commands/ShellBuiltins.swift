import Foundation

/// Commands that operate on shell state or are otherwise shell-level (cd, export, echo, test, ...).
enum ShellBuiltins {
    static func registerShellCommands(_ r: CommandRegistry) {
        r.register("cd", "change the working directory") { ctx in
            var target: String
            let args = ctx.args.filter { $0 != "-P" && $0 != "-L" }
            var printDir = false
            if let a = args.first {
                if a == "-" {
                    guard let old = ctx.shell.variable("OLDPWD") else { ctx.error("OLDPWD not set"); return 1 }
                    target = old; printDir = true
                } else {
                    target = a
                }
            } else {
                target = ctx.shell.variable("HOME") ?? ctx.homeDirectory
            }
            let full = ctx.resolve(target)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else {
                ctx.error("\(target): No such file or directory"); return 1
            }
            guard isDir.boolValue else { ctx.error("\(target): Not a directory"); return 1 }
            guard FileManager.default.isExecutableFile(atPath: full) else { ctx.error("\(target): Permission denied"); return 1 }
            ctx.shell.currentDirectory = full
            if printDir { ctx.print(full) }
            return 0
        }

        r.register("pwd", "print the working directory") { ctx in
            if ctx.has("-P") {
                ctx.print(URL(fileURLWithPath: ctx.currentDirectory).resolvingSymlinksInPath().path)
            } else {
                ctx.print(ctx.currentDirectory)
            }
            return 0
        }

        r.register("echo", "print arguments (-n no newline, -e interpret escapes)") { ctx in
            var args = ctx.args
            var newline = true, escapes = false
            while let f = args.first, f.hasPrefix("-"), f.count > 1, f.dropFirst().allSatisfy({ "neE".contains($0) }) {
                if f.contains("n") { newline = false }
                if f.contains("e") { escapes = true }
                if f.contains("E") { escapes = false }
                args.removeFirst()
            }
            var text = args.joined(separator: " ")
            if escapes {
                let (t, stop) = ShellFormat.unescape(text)
                text = t
                if stop { newline = false }
            }
            ctx.stdout.write(text + (newline ? "\n" : ""))
            return 0
        }

        r.register("printf", "formatted output") { ctx in
            guard let format = ctx.args.first else { ctx.error("usage: printf format [arguments]"); return 2 }
            ctx.stdout.write(Printf.format(format, Array(ctx.args.dropFirst())))
            return 0
        }

        r.register("export", "set environment variables") { ctx in
            if ctx.args.isEmpty || ctx.args == ["-p"] {
                for (k, v) in ctx.shell.environment.sorted(by: { $0.key < $1.key }) {
                    ctx.print("export \(k)=\(quote(v))")
                }
                return 0
            }
            for a in ctx.args where a != "-n" {
                if let eq = a.firstIndex(of: "=") {
                    ctx.shell.setVariable(String(a[..<eq]), String(a[a.index(after: eq)...]))
                } else if ctx.shell.variable(a) == nil {
                    ctx.shell.setVariable(a, "")
                }
            }
            return 0
        }

        r.register("unset", "remove variables") { ctx in
            for a in ctx.args where !a.hasPrefix("-") { ctx.shell.setVariable(a, nil) }
            return 0
        }

        r.register("set", "show shell variables or set positional parameters") { ctx in
            if ctx.args.isEmpty {
                for (k, v) in ctx.shell.environment.sorted(by: { $0.key < $1.key }) { ctx.print("\(k)=\(quote(v))") }
                return 0
            }
            var args = ctx.args
            if args.first == "--" { args.removeFirst(); ctx.shell.positionalParameters = [ctx.shell.positionalParameters.first ?? "sh"] + args }
            return 0
        }

        r.register("shift", "shift positional parameters") { ctx in
            let n = Int(ctx.args.first ?? "1") ?? 1
            var p = ctx.shell.positionalParameters
            guard p.count - 1 >= n else { return 1 }
            p.removeSubrange(1..<(1 + n))
            ctx.shell.positionalParameters = p
            return 0
        }

        r.register("alias", "define or list aliases") { ctx in
            if ctx.args.isEmpty {
                for (k, v) in ctx.shell.aliases.sorted(by: { $0.key < $1.key }) { ctx.print("alias \(k)=\(quote(v))") }
                return 0
            }
            var status: Int32 = 0
            for a in ctx.args {
                if let eq = a.firstIndex(of: "=") {
                    ctx.shell.setAlias(String(a[..<eq]), String(a[a.index(after: eq)...]))
                } else if let v = ctx.shell.aliases[a] {
                    ctx.print("alias \(a)=\(quote(v))")
                } else {
                    ctx.error("\(a): not found"); status = 1
                }
            }
            return status
        }

        r.register("unalias", "remove aliases") { ctx in
            if ctx.args.contains("-a") { for k in ctx.shell.aliases.keys { ctx.shell.setAlias(k, nil) }; return 0 }
            var status: Int32 = 0
            for a in ctx.args {
                if ctx.shell.aliases[a] == nil { ctx.error("\(a): not found"); status = 1 } else { ctx.shell.setAlias(a, nil) }
            }
            return status
        }

        r.register("history", "show command history (-c clears)") { ctx in
            if ctx.has("-c") { ctx.shell.history.clear(); return 0 }
            let all = ctx.shell.history.all
            var entries = Array(all.enumerated())
            if let n = ctx.args.first.flatMap({ Int($0) }) { entries = Array(entries.suffix(n)) }
            for (i, e) in entries { ctx.print(ShellFormat.pad(String(i + 1), 5, right: true) + "  " + e) }
            return 0
        }

        r.register("clear", "clear the terminal screen") { ctx in
            ctx.stdout.write(ANSI.clearScreen)
            return 0
        }

        r.register("reset", "reset the terminal") { ctx in
            ctx.stdout.write("\u{1B}c")
            return 0
        }

        r.register("true", "do nothing, successfully") { _ in 0 }
        r.register(":", "do nothing, successfully") { _ in 0 }
        r.register("false", "do nothing, unsuccessfully") { _ in 1 }

        r.register("exit", "exit the shell") { ctx in
            let code = ctx.args.first.flatMap { Int32($0) } ?? ctx.shell.lastStatus
            ctx.shell.exitRequested = code
            return code
        }

        r.register("source", "run commands from a file in the current shell") { ctx in
            guard let file = ctx.args.first else { ctx.error("filename argument required"); return 2 }
            var path = ctx.resolve(file)
            if !file.contains("/"), !FileManager.default.fileExists(atPath: path), let s = ctx.shell.findScript(file) { path = s }
            let io = ShellIO(stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr)
            return ctx.shell.source(file: path, arguments: ctx.args.count > 1 ? ctx.args : [], io: io, cancellation: ctx.cancellation)
        }
        r.alias(".", to: "source")

        r.register("eval", "evaluate arguments as a command") { ctx in
            let io = ShellIO(stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr)
            return ctx.shell.run(ctx.args.joined(separator: " "), io: io, cancellation: ctx.cancellation)
        }

        r.register("command", "run a command bypassing aliases") { ctx in
            var args = ctx.args
            if args.first == "-v" {
                args.removeFirst()
                guard let n = args.first else { return 1 }
                if ctx.shell.registry.command(named: n) != nil { ctx.print(n); return 0 }
                if let s = ctx.shell.findScript(n) { ctx.print(s); return 0 }
                return 1
            }
            let io = ShellIO(stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr)
            return ctx.shell.runCommand(args, io: io, cancellation: ctx.cancellation, environment: ctx.environment)
        }

        r.register("read", "read a line from stdin into variables") { ctx in
            let opts = ParsedOptions(ctx.args, flags: "rs", withValues: "p")
            if let p = opts.value("p") { ctx.stderr.write(p); ctx.stderr.flush() }
            guard let line = LineReader(ctx.stdin).nextLine() else { return 1 }
            var names = opts.operands
            if names.isEmpty { names = ["REPLY"] }
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (i, n) in names.enumerated() {
                if i == names.count - 1 {
                    ctx.shell.setVariable(n, fields.joined(separator: " "))
                } else {
                    ctx.shell.setVariable(n, fields.isEmpty ? "" : fields.removeFirst())
                }
            }
            return 0
        }

        r.register("type", "describe how a name would be interpreted") { ctx in
            var status: Int32 = 0
            for n in ctx.args {
                if let a = ctx.shell.aliases[n] { ctx.print("\(n) is aliased to `\(a)'") }
                else if ctx.shell.registry.command(named: n) != nil { ctx.print("\(n) is a shell builtin") }
                else if let s = ctx.shell.findScript(n) { ctx.print("\(n) is \(s)") }
                else { ctx.error("\(n): not found"); status = 1 }
            }
            return status
        }

        r.register("which", "locate a command") { ctx in
            var status: Int32 = 0
            for n in ctx.args where !n.hasPrefix("-") {
                if ctx.shell.registry.command(named: n) != nil { ctx.print("\(n): shell built-in command") }
                else if let s = ctx.shell.findScript(n) { ctx.print(s) }
                else { status = 1 }
            }
            return status
        }

        r.register("env", "print environment or run a command with a modified environment") { ctx in
            var env = ctx.environment
            var args = ctx.args
            if args.first == "-i" { env = [:]; args.removeFirst() }
            while let a = args.first, let eq = a.firstIndex(of: "="), a.first != "=" {
                env[String(a[..<eq])] = String(a[a.index(after: eq)...])
                args.removeFirst()
            }
            if args.isEmpty {
                for (k, v) in env.sorted(by: { $0.key < $1.key }) { ctx.print("\(k)=\(v)") }
                return 0
            }
            let io = ShellIO(stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr)
            return ctx.shell.runCommand(args, io: io, cancellation: ctx.cancellation, environment: env)
        }
        r.register("printenv", "print environment variables") { ctx in
            if ctx.args.isEmpty {
                for (k, v) in ctx.environment.sorted(by: { $0.key < $1.key }) { ctx.print("\(k)=\(v)") }
                return 0
            }
            var status: Int32 = 0
            for a in ctx.args { if let v = ctx.environment[a] { ctx.print(v) } else { status = 1 } }
            return status
        }

        r.register("test", "evaluate a conditional expression") { ctx in TestCommand.evaluate(ctx.args, ctx) }
        r.register("[", "evaluate a conditional expression") { ctx in
            var args = ctx.args
            guard args.last == "]" else { ctx.error("missing `]'"); return 2 }
            args.removeLast()
            return TestCommand.evaluate(args, ctx)
        }

        r.register("sleep", "pause for a number of seconds (suffixes s, m, h, d)") { ctx in
            guard !ctx.args.isEmpty else { ctx.error("missing operand"); return 1 }
            var total = 0.0
            for a in ctx.args {
                var s = a
                var mult = 1.0
                if let last = s.last, "smhd".contains(last) {
                    mult = ["s": 1, "m": 60, "h": 3600, "d": 86400][String(last)]!
                    s.removeLast()
                }
                guard let v = Double(s) else { ctx.error("invalid time interval '\(a)'"); return 1 }
                total += v * mult
            }
            ctx.stdout.flush()
            return ctx.cancellation.sleep(total) ? 0 : 130
        }

        r.register("yes", "repeatedly print a line (default 'y') until interrupted") { ctx in
            let line = (ctx.args.isEmpty ? "y" : ctx.args.joined(separator: " ")) + "\n"
            var chunk = ""
            while chunk.utf8.count < 4096 { chunk += line }
            let bytes = Array(chunk.utf8)
            while !ctx.shouldStop {
                ctx.stdout.write(bytes)
                if ctx.stdout.isTerminal { ctx.cancellation.sleep(0.002) }
            }
            return ctx.isCancelled ? 130 : 0
        }

        r.register("seq", "print a sequence of numbers") { ctx in
            let opts = ParsedOptions(ctx.args.map { $0.hasPrefix("-") && Double($0) != nil ? "\u{0}" + $0 : $0 }, flags: "w", withValues: "sf")
            let nums = opts.operands.map { $0.hasPrefix("\u{0}") ? String($0.dropFirst()) : $0 }
            let values = nums.compactMap { Double($0) }
            guard values.count == nums.count, (1...3).contains(values.count) else { ctx.error("invalid arguments"); return 1 }
            var first = 1.0, inc = 1.0, last = values[0]
            if values.count == 2 { first = values[0]; last = values[1] }
            if values.count == 3 { first = values[0]; inc = values[1]; last = values[2] }
            guard inc != 0 else { ctx.error("invalid zero increment"); return 1 }
            let sep = opts.value("s").map { ShellFormat.unescape($0).0 } ?? "\n"
            let isInt = nums.allSatisfy { !$0.contains(".") && !$0.contains("e") }
            let decimals = nums.map { $0.split(separator: ".").dropFirst().first?.count ?? 0 }.max() ?? 0
            var out: [String] = []
            var v = first
            var buffer = ""
            var count = 0
            while inc > 0 ? v <= last + 1e-9 : v >= last - 1e-9 {
                if ctx.shouldStop { break }
                out.append(isInt ? String(Int64(v)) : String(format: "%.\(decimals)f", v))
                count += 1
                v = first + Double(count) * inc
                if out.count >= 1024 { buffer = out.joined(separator: sep) + sep; ctx.stdout.write(buffer); out.removeAll() }
            }
            if opts.has("w"), let width = out.map({ $0.count }).max() {
                out = out.map { String(repeating: "0", count: width - $0.count) + $0 }
            }
            if !out.isEmpty { ctx.stdout.write(out.joined(separator: sep) + "\n") } else if count > 0 && sep != "\n" { ctx.stdout.write("\n") }
            return 0
        }

        r.register("help", "list available commands") { ctx in
            let cmds = ctx.shell.registry.allCommands.filter { !$0.summary.isEmpty }
            if let name = ctx.args.first {
                guard let c = ctx.shell.registry.command(named: name) else { ctx.error("no help topics match '\(name)'"); return 1 }
                ctx.print("\(c.name): \(c.summary)")
                return 0
            }
            ctx.print("Termux for iOS built-in shell. iOS does not allow running native programs,")
            ctx.print("so these commands are implemented inside the app:")
            ctx.print()
            let width = (cmds.map { $0.name.count }.max() ?? 8) + 2
            for c in cmds { ctx.print("  " + ShellFormat.pad(c.name, width) + c.summary) }
            ctx.print()
            ctx.print("Shell features: pipes |, && ||, ;, redirections > >> < 2>&1, $VAR, $(cmd), $((math)), globs * ?")
            return 0
        }

        let pkgMessage = { (ctx: CommandContext) -> Int32 in
            ctx.stderr.writeLine("""
            \(ctx.name): package management is not available on iOS.

            iOS does not allow apps to download and run native binaries, so Termux
            packages (apt/pkg) cannot be installed. The commands in this shell are
            built into the app - run 'help' to see what is available.
            """)
            return 1
        }
        r.register("pkg", "explains why packages cannot be installed on iOS", pkgMessage)
        r.register("apt", "explains why packages cannot be installed on iOS", pkgMessage)
        r.register("apt-get", "", pkgMessage)
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty && s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-:@%+,=".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension CommandContext {
    /// True if `flag` (e.g. "-P") appears among the arguments.
    func has(_ flag: String) -> Bool { args.contains(flag) }
}

// MARK: - test / [

enum TestCommand {
    static func evaluate(_ args: [String], _ ctx: CommandContext) -> Int32 {
        var p = TestParser(args: args, ctx: ctx)
        guard let r = p.parseOr(), p.pos == args.count else {
            if args.isEmpty { return 1 }
            ctx.error("syntax error"); return 2
        }
        return r ? 0 : 1
    }

    struct TestParser {
        let args: [String]
        let ctx: CommandContext
        var pos = 0

        mutating func parseOr() -> Bool? {
            guard var v = parseAnd() else { return nil }
            while pos < args.count && args[pos] == "-o" { pos += 1; guard let r = parseAnd() else { return nil }; v = v || r }
            return v
        }
        mutating func parseAnd() -> Bool? {
            guard var v = parseNot() else { return nil }
            while pos < args.count && args[pos] == "-a" { pos += 1; guard let r = parseNot() else { return nil }; v = v && r }
            return v
        }
        mutating func parseNot() -> Bool? {
            if pos < args.count && args[pos] == "!" && pos + 1 < args.count { pos += 1; return parseNot().map { !$0 } }
            return parsePrimary()
        }
        mutating func parsePrimary() -> Bool? {
            guard pos < args.count else { return nil }
            let a = args[pos]
            if a == "(" {
                pos += 1
                let v = parseOr()
                guard pos < args.count, args[pos] == ")" else { return nil }
                pos += 1
                return v
            }
            // Binary operators
            if pos + 2 < args.count {
                let op = args[pos + 1], rhs = args[pos + 2]
                if let r = binary(a, op, rhs) { pos += 3; return r }
            }
            // Unary operators
            if a.hasPrefix("-") && a.count == 2 && pos + 1 < args.count {
                if let r = unary(a, args[pos + 1]) { pos += 2; return r }
            }
            pos += 1
            return !a.isEmpty
        }

        func binary(_ l: String, _ op: String, _ r: String) -> Bool? {
            switch op {
            case "=", "==": return l == r
            case "!=": return l != r
            case "<": return l < r
            case ">": return l > r
            case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
                guard let a = Int64(l.trimmingCharacters(in: .whitespaces)), let b = Int64(r.trimmingCharacters(in: .whitespaces)) else {
                    ctx.error("integer expression expected"); return false
                }
                switch op {
                case "-eq": return a == b
                case "-ne": return a != b
                case "-lt": return a < b
                case "-le": return a <= b
                case "-gt": return a > b
                default: return a >= b
                }
            case "-nt", "-ot":
                let a = FileInfo(path: ctx.resolve(l), follow: true)?.modificationDate
                let b = FileInfo(path: ctx.resolve(r), follow: true)?.modificationDate
                guard let x = a, let y = b else { return false }
                return op == "-nt" ? x > y : x < y
            default: return nil
            }
        }

        func unary(_ op: String, _ v: String) -> Bool? {
            let path = ctx.resolve(v)
            let fm = FileManager.default
            switch op {
            case "-z": return v.isEmpty
            case "-n": return !v.isEmpty
            case "-e": return FileInfo(path: path, follow: true) != nil
            case "-f": return FileInfo(path: path, follow: true)?.isRegular ?? false
            case "-d": return FileInfo(path: path, follow: true)?.isDirectory ?? false
            case "-L", "-h": return FileInfo(path: path)?.isSymlink ?? false
            case "-s": return (FileInfo(path: path, follow: true)?.size ?? 0) > 0
            case "-r": return fm.isReadableFile(atPath: path)
            case "-w": return fm.isWritableFile(atPath: path)
            case "-x": return fm.isExecutableFile(atPath: path)
            case "-t": return v == "1" ? ctx.stdout.isTerminal : (v == "0" ? ctx.stdin.isTerminal : false)
            default: return nil
            }
        }
    }
}

// MARK: - printf

enum Printf {
    static func format(_ format: String, _ arguments: [String]) -> String {
        var out = ""
        var args = arguments[...]
        let fmt = Array(format)
        var consumedAny = false
        repeat {
            consumedAny = false
            var i = 0
            while i < fmt.count {
                let c = fmt[i]
                if c == "\\" {
                    // Collect the escape and decode with the shared helper.
                    var j = i + 1
                    if j < fmt.count {
                        j += 1
                        if fmt[i + 1] == "x" || ("0"..."7").contains(fmt[i + 1]) {
                            while j < fmt.count && j < i + 5 && fmt[j].isHexDigit { j += 1 }
                        }
                    }
                    let (s, stop) = ShellFormat.unescape(String(fmt[i..<j]))
                    out += s
                    if stop { return out }
                    i = j; continue
                }
                guard c == "%" else { out.append(c); i += 1; continue }
                i += 1
                guard i < fmt.count else { out.append("%"); break }
                if fmt[i] == "%" { out.append("%"); i += 1; continue }
                var spec = "%"
                while i < fmt.count && "-+ #0".contains(fmt[i]) { spec.append(fmt[i]); i += 1 }
                while i < fmt.count && (fmt[i].isNumber || fmt[i] == "." || fmt[i] == "*") {
                    if fmt[i] == "*" { spec += args.isEmpty ? "0" : args.removeFirst(); consumedAny = true } else { spec.append(fmt[i]) }
                    i += 1
                }
                guard i < fmt.count else { break }
                let conv = fmt[i]
                i += 1
                let arg: String? = args.isEmpty ? nil : args.removeFirst()
                if arg != nil { consumedAny = true }
                switch conv {
                case "d", "i":
                    out += String(format: spec + "lld", parseInt(arg))
                case "u":
                    out += String(format: spec + "llu", UInt64(bitPattern: parseInt(arg)))
                case "x", "X", "o":
                    out += String(format: spec + "ll" + String(conv), parseInt(arg))
                case "f", "F", "e", "E", "g", "G":
                    out += String(format: spec + String(conv), Double(arg ?? "0") ?? 0)
                case "c":
                    out += arg.flatMap { $0.first.map(String.init) } ?? ""
                case "b":
                    let (s, _) = ShellFormat.unescape(arg ?? ""); out += pad(s, spec)
                case "q":
                    out += ShellBuiltins.quote(arg ?? "")
                default: // s
                    out += pad(arg ?? "", spec)
                }
            }
        } while consumedAny && !args.isEmpty
        return out
    }

    private static func parseInt(_ s: String?) -> Int64 {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        if s.hasPrefix("'") || s.hasPrefix("\""), let u = s.dropFirst().unicodeScalars.first { return Int64(u.value) }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int64(s.dropFirst(2), radix: 16) ?? 0 }
        return Int64(s) ?? Int64(Double(s) ?? 0)
    }

    private static func pad(_ s: String, _ spec: String) -> String {
        let body = spec.dropFirst()
        let left = body.contains("-")
        let numbers = body.filter { $0.isNumber || $0 == "." }
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        var value = s
        if parts.count > 1, let prec = Int(parts[1]) { value = String(value.prefix(prec)) }
        guard let w = parts.first.flatMap({ Int($0) }), w > value.count else { return value }
        let padding = String(repeating: " ", count: w - value.count)
        return left ? value + padding : padding + value
    }
}

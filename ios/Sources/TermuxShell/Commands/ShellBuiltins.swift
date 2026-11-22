import Foundation

enum ShellBuiltins {
    static func registerShellCommands(_ r: CommandRegistry) {
        r.register("cd", "change the working directory") { context in
            var target: String
            let arguments = context.arguments.filter { $0 != "-P" && $0 != "-L" }
            var printDir = false
            if let a = arguments.first {
                if a == "-" {
                    guard let old = context.shell.variable("OLDPWD") else { context.error("OLDPWD not set"); return 1 }
                    target = old; printDir = true
                } else {
                    target = a
                }
            } else {
                target = context.shell.variable("HOME") ?? context.homeDirectory
            }
            let full = context.resolve(target)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) else {
                context.error("\(target): No such file or directory"); return 1
            }
            guard isDirectory.boolValue else { context.error("\(target): Not a directory"); return 1 }
            guard FileManager.default.isExecutableFile(atPath: full) else { context.error("\(target): Permission denied"); return 1 }
            context.shell.currentDirectory = full
            if printDir { context.print(full) }
            return 0
        }

        r.register("pwd", "print the working directory") { context in
            if context.has("-P") {
                context.print(URL(fileURLWithPath: context.currentDirectory).resolvingSymlinksInPath().path)
            } else {
                context.print(context.currentDirectory)
            }
            return 0
        }

        r.register("echo", "print arguments (-n no newline, -e interpret escapes)") { context in
            var arguments = context.arguments
            var newline = true, escapes = false
            while let f = arguments.first, f.hasPrefix("-"), f.count > 1, f.dropFirst().allSatisfy({ "neE".contains($0) }) {
                if f.contains("n") { newline = false }
                if f.contains("e") { escapes = true }
                if f.contains("E") { escapes = false }
                arguments.removeFirst()
            }
            var text = arguments.joined(separator: " ")
            if escapes {
                let (t, stop) = ShellFormat.unescape(text)
                text = t
                if stop { newline = false }
            }
            context.stdout.write(text + (newline ? "\n" : ""))
            return 0
        }

        r.register("printf", "formatted output") { context in
            guard let format = context.arguments.first else { context.error("usage: printf format [arguments]"); return 2 }
            context.stdout.write(Printf.format(format, Array(context.arguments.dropFirst())))
            return 0
        }

        r.register("export", "set environment variables") { context in
            if context.arguments.isEmpty || context.arguments == ["-p"] {
                for (k, v) in context.shell.environment.sorted(by: { $0.key < $1.key }) {
                    context.print("export \(k)=\(quote(v))")
                }
                return 0
            }
            for a in context.arguments where a != "-n" {
                if let eq = a.firstIndex(of: "=") {
                    context.shell.setVariable(String(a[..<eq]), String(a[a.index(after: eq)...]))
                } else if context.shell.variable(a) == nil {
                    context.shell.setVariable(a, "")
                }
            }
            return 0
        }

        r.register("unset", "remove variables") { context in
            for a in context.arguments where !a.hasPrefix("-") { context.shell.setVariable(a, nil) }
            return 0
        }

        r.register("set", "show shell variables or set positional parameters") { context in
            if context.arguments.isEmpty {
                for (k, v) in context.shell.environment.sorted(by: { $0.key < $1.key }) { context.print("\(k)=\(quote(v))") }
                return 0
            }
            var arguments = context.arguments
            if arguments.first == "--" { arguments.removeFirst(); context.shell.positionalParameters = [context.shell.positionalParameters.first ?? "sh"] + arguments }
            return 0
        }

        r.register("shift", "shift positional parameters") { context in
            let n = Int(context.arguments.first ?? "1") ?? 1
            var p = context.shell.positionalParameters
            guard p.count - 1 >= n else { return 1 }
            p.removeSubrange(1..<(1 + n))
            context.shell.positionalParameters = p
            return 0
        }

        r.register("alias", "define or list aliases") { context in
            if context.arguments.isEmpty {
                for (k, v) in context.shell.aliases.sorted(by: { $0.key < $1.key }) { context.print("alias \(k)=\(quote(v))") }
                return 0
            }
            var status: Int32 = 0
            for a in context.arguments {
                if let eq = a.firstIndex(of: "=") {
                    context.shell.setAlias(String(a[..<eq]), String(a[a.index(after: eq)...]))
                } else if let v = context.shell.aliases[a] {
                    context.print("alias \(a)=\(quote(v))")
                } else {
                    context.error("\(a): not found"); status = 1
                }
            }
            return status
        }

        r.register("unalias", "remove aliases") { context in
            if context.arguments.contains("-a") { for k in context.shell.aliases.keys { context.shell.setAlias(k, nil) }; return 0 }
            var status: Int32 = 0
            for a in context.arguments {
                if context.shell.aliases[a] == nil { context.error("\(a): not found"); status = 1 } else { context.shell.setAlias(a, nil) }
            }
            return status
        }

        r.register("history", "show command history (-c clears)") { context in
            if context.has("-c") { context.shell.history.clear(); return 0 }
            let all = context.shell.history.all
            var entries = Array(all.enumerated())
            if let n = context.arguments.first.flatMap({ Int($0) }) { entries = Array(entries.suffix(n)) }
            for (i, e) in entries { context.print(ShellFormat.pad(String(i + 1), 5, right: true) + "  " + e) }
            return 0
        }

        r.register("clear", "clear the terminal screen") { context in
            context.stdout.write(ANSI.clearScreen)
            return 0
        }

        r.register("reset", "reset the terminal") { context in
            context.stdout.write("\u{1B}c")
            return 0
        }

        r.register("true", "do nothing, successfully") { _ in 0 }
        r.register(":", "do nothing, successfully") { _ in 0 }
        r.register("false", "do nothing, unsuccessfully") { _ in 1 }

        r.register("exit", "exit the shell") { context in
            let code = context.arguments.first.flatMap { Int32($0) } ?? context.shell.lastStatus
            context.shell.exitRequested = code
            return code
        }

        r.register("source", "run commands from a file in the current shell") { context in
            guard let file = context.arguments.first else { context.error("filename argument required"); return 2 }
            var path = context.resolve(file)
            if !file.contains("/"), !FileManager.default.fileExists(atPath: path), let s = context.shell.findScript(file) { path = s }
            let streams = StandardStreams(stdin: context.stdin, stdout: context.stdout, stderr: context.stderr)
            return context.shell.source(file: path, arguments: context.arguments.count > 1 ? context.arguments : [], streams: streams, cancellation: context.cancellation)
        }
        r.alias(".", to: "source")

        r.register("eval", "evaluate arguments as a command") { context in
            let streams = StandardStreams(stdin: context.stdin, stdout: context.stdout, stderr: context.stderr)
            return context.shell.run(context.arguments.joined(separator: " "), streams: streams, cancellation: context.cancellation)
        }

        r.register("command", "run a command bypassing aliases") { context in
            var arguments = context.arguments
            if arguments.first == "-v" {
                arguments.removeFirst()
                guard let n = arguments.first else { return 1 }
                if context.shell.registry.command(named: n) != nil { context.print(n); return 0 }
                if let s = context.shell.findScript(n) { context.print(s); return 0 }
                return 1
            }
            let streams = StandardStreams(stdin: context.stdin, stdout: context.stdout, stderr: context.stderr)
            return context.shell.runCommand(arguments, streams: streams, cancellation: context.cancellation, environment: context.environment)
        }

        r.register("read", "read a line from stdin into variables") { context in
            let options = ParsedOptions(context.arguments, flags: "rs", withValues: "p")
            if let p = options.value("p") { context.stderr.write(p); context.stderr.flush() }
            guard let line = LineReader(context.stdin).nextLine() else { return 1 }
            var names = options.operands
            if names.isEmpty { names = ["REPLY"] }
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (i, n) in names.enumerated() {
                if i == names.count - 1 {
                    context.shell.setVariable(n, fields.joined(separator: " "))
                } else {
                    context.shell.setVariable(n, fields.isEmpty ? "" : fields.removeFirst())
                }
            }
            return 0
        }

        r.register("type", "describe how a name would be interpreted") { context in
            var status: Int32 = 0
            for n in context.arguments {
                if let a = context.shell.aliases[n] { context.print("\(n) is aliased to `\(a)'") }
                else if context.shell.registry.command(named: n) != nil { context.print("\(n) is a shell builtin") }
                else if let s = context.shell.findScript(n) { context.print("\(n) is \(s)") }
                else { context.error("\(n): not found"); status = 1 }
            }
            return status
        }

        r.register("which", "locate a command") { context in
            var status: Int32 = 0
            for n in context.arguments where !n.hasPrefix("-") {
                if context.shell.registry.command(named: n) != nil { context.print("\(n): shell built-in command") }
                else if let s = context.shell.findScript(n) { context.print(s) }
                else { status = 1 }
            }
            return status
        }

        r.register("env", "print environment or run a command with a modified environment") { context in
            var commandEnvironment = context.environment
            var arguments = context.arguments
            if arguments.first == "-i" { commandEnvironment = [:]; arguments.removeFirst() }
            while let a = arguments.first, let eq = a.firstIndex(of: "="), a.first != "=" {
                commandEnvironment[String(a[..<eq])] = String(a[a.index(after: eq)...])
                arguments.removeFirst()
            }
            if arguments.isEmpty {
                for (k, v) in commandEnvironment.sorted(by: { $0.key < $1.key }) { context.print("\(k)=\(v)") }
                return 0
            }
            let streams = StandardStreams(stdin: context.stdin, stdout: context.stdout, stderr: context.stderr)
            return context.shell.runCommand(arguments, streams: streams, cancellation: context.cancellation, environment: commandEnvironment)
        }
        r.register("printenv", "print environment variables") { context in
            if context.arguments.isEmpty {
                for (k, v) in context.environment.sorted(by: { $0.key < $1.key }) { context.print("\(k)=\(v)") }
                return 0
            }
            var status: Int32 = 0
            for a in context.arguments { if let v = context.environment[a] { context.print(v) } else { status = 1 } }
            return status
        }

        r.register("test", "evaluate a conditional expression") { context in TestCommand.evaluate(context.arguments, context) }
        r.register("[", "evaluate a conditional expression") { context in
            var arguments = context.arguments
            guard arguments.last == "]" else { context.error("missing `]'"); return 2 }
            arguments.removeLast()
            return TestCommand.evaluate(arguments, context)
        }

        r.register("sleep", "pause for a number of seconds (suffixes s, m, h, d)") { context in
            guard !context.arguments.isEmpty else { context.error("missing operand"); return 1 }
            var total = 0.0
            for a in context.arguments {
                var s = a
                var multiplier = 1.0
                if let last = s.last, "smhd".contains(last) {
                    multiplier = ["s": 1, "m": 60, "h": 3600, "d": 86400][String(last)]!
                    s.removeLast()
                }
                guard let v = Double(s) else { context.error("invalid time interval '\(a)'"); return 1 }
                total += v * multiplier
            }
            context.stdout.flush()
            return context.cancellation.sleep(total) ? 0 : 130
        }

        r.register("yes", "repeatedly print a line (default 'y') until interrupted") { context in
            let line = (context.arguments.isEmpty ? "y" : context.arguments.joined(separator: " ")) + "\n"
            var chunk = ""
            while chunk.utf8.count < 4096 { chunk += line }
            let bytes = Array(chunk.utf8)
            while !context.shouldStop {
                context.stdout.write(bytes)
                if context.stdout.isTerminal { context.cancellation.sleep(0.002) }
            }
            return context.isCancelled ? 130 : 0
        }

        r.register("seq", "print a sequence of numbers") { context in
            let options = ParsedOptions(context.arguments.map { $0.hasPrefix("-") && Double($0) != nil ? "\u{0}" + $0 : $0 }, flags: "w", withValues: "sf")
            let numberTexts = options.operands.map { $0.hasPrefix("\u{0}") ? String($0.dropFirst()) : $0 }
            let values = numberTexts.compactMap { Double($0) }
            guard values.count == numberTexts.count, (1...3).contains(values.count) else { context.error("invalid arguments"); return 1 }
            var first = 1.0, increment = 1.0, last = values[0]
            if values.count == 2 { first = values[0]; last = values[1] }
            if values.count == 3 { first = values[0]; increment = values[1]; last = values[2] }
            guard increment != 0 else { context.error("invalid zero increment"); return 1 }
            let separator = options.value("s").map { ShellFormat.unescape($0).0 } ?? "\n"
            let isInteger = numberTexts.allSatisfy { !$0.contains(".") && !$0.contains("e") }
            let decimals = numberTexts.map { $0.split(separator: ".").dropFirst().first?.count ?? 0 }.max() ?? 0
            var out: [String] = []
            var v = first
            var buffer = ""
            var count = 0
            while increment > 0 ? v <= last + 1e-9 : v >= last - 1e-9 {
                if context.shouldStop { break }
                out.append(isInteger ? String(Int64(v)) : String(format: "%.\(decimals)f", v))
                count += 1
                v = first + Double(count) * increment
                if out.count >= 1024 { buffer = out.joined(separator: separator) + separator; context.stdout.write(buffer); out.removeAll() }
            }
            if options.has("w"), let width = out.map({ $0.count }).max() {
                out = out.map { String(repeating: "0", count: width - $0.count) + $0 }
            }
            if !out.isEmpty { context.stdout.write(out.joined(separator: separator) + "\n") } else if count > 0 && separator != "\n" { context.stdout.write("\n") }
            return 0
        }

        r.register("help", "list available commands") { context in
            let commands = context.shell.registry.allCommands.filter { !$0.summary.isEmpty }
            if let name = context.arguments.first {
                guard let c = context.shell.registry.command(named: name) else { context.error("no help topics match '\(name)'"); return 1 }
                context.print("\(c.name): \(c.summary)")
                return 0
            }
            context.print("Termux for iOS built-in shell. iOS does not allow running native programs,")
            context.print("so these commands are implemented inside the app:")
            context.print()
            let width = (commands.map { $0.name.count }.max() ?? 8) + 2
            for c in commands { context.print("  " + ShellFormat.pad(c.name, width) + c.summary) }
            context.print()
            context.print("Shell features: pipes |, && ||, ;, redirections > >> < 2>&1, $VAR, $(command), $((math)), globs * ?")
            return 0
        }

        let packageMessage = { (context: CommandContext) -> Int32 in
            context.stderr.writeLine("""
            \(context.name): package management is not available on iOS.

            iOS does not allow apps to download and run native binaries, so Termux
            packages (apt/pkg) cannot be installed. The commands in this shell are
            built into the app - run 'help' to see what is available.
            """)
            return 1
        }
        r.register("pkg", "explains why packages cannot be installed on iOS", packageMessage)
        r.register("apt", "explains why packages cannot be installed on iOS", packageMessage)
        r.register("apt-get", "", packageMessage)
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty && s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-:@%+,=".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension CommandContext {
    func has(_ flag: String) -> Bool { arguments.contains(flag) }
}

enum TestCommand {
    static func evaluate(_ arguments: [String], _ context: CommandContext) -> Int32 {
        var p = TestParser(arguments: arguments, context: context)
        guard let r = p.parseOr(), p.position == arguments.count else {
            if arguments.isEmpty { return 1 }
            context.error("syntax error"); return 2
        }
        return r ? 0 : 1
    }

    struct TestParser {
        let arguments: [String]
        let context: CommandContext
        var position = 0

        mutating func parseOr() -> Bool? {
            guard var v = parseAnd() else { return nil }
            while position < arguments.count && arguments[position] == "-o" { position += 1; guard let r = parseAnd() else { return nil }; v = v || r }
            return v
        }
        mutating func parseAnd() -> Bool? {
            guard var v = parseNot() else { return nil }
            while position < arguments.count && arguments[position] == "-a" { position += 1; guard let r = parseNot() else { return nil }; v = v && r }
            return v
        }
        mutating func parseNot() -> Bool? {
            if position < arguments.count && arguments[position] == "!" && position + 1 < arguments.count { position += 1; return parseNot().map { !$0 } }
            return parsePrimary()
        }
        mutating func parsePrimary() -> Bool? {
            guard position < arguments.count else { return nil }
            let a = arguments[position]
            if a == "(" {
                position += 1
                let v = parseOr()
                guard position < arguments.count, arguments[position] == ")" else { return nil }
                position += 1
                return v
            }
            if position + 2 < arguments.count {
                let operation = arguments[position + 1], rightValue = arguments[position + 2]
                if let r = binary(a, operation, rightValue) { position += 3; return r }
            }
            if a.hasPrefix("-") && a.count == 2 && position + 1 < arguments.count {
                if let r = unary(a, arguments[position + 1]) { position += 2; return r }
            }
            position += 1
            return !a.isEmpty
        }

        func binary(_ l: String, _ operation: String, _ r: String) -> Bool? {
            switch operation {
            case "=", "==": return l == r
            case "!=": return l != r
            case "<": return l < r
            case ">": return l > r
            case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
                guard let a = Int64(l.trimmingCharacters(in: .whitespaces)), let b = Int64(r.trimmingCharacters(in: .whitespaces)) else {
                    context.error("integer expression expected"); return false
                }
                switch operation {
                case "-eq": return a == b
                case "-ne": return a != b
                case "-lt": return a < b
                case "-le": return a <= b
                case "-gt": return a > b
                default: return a >= b
                }
            case "-nt", "-ot":
                let a = FileInfo(path: context.resolve(l), follow: true)?.modificationDate
                let b = FileInfo(path: context.resolve(r), follow: true)?.modificationDate
                guard let x = a, let y = b else { return false }
                return operation == "-nt" ? x > y : x < y
            default: return nil
            }
        }

        func unary(_ operation: String, _ v: String) -> Bool? {
            let path = context.resolve(v)
            let fileManager = FileManager.default
            switch operation {
            case "-z": return v.isEmpty
            case "-n": return !v.isEmpty
            case "-e": return FileInfo(path: path, follow: true) != nil
            case "-f": return FileInfo(path: path, follow: true)?.isRegular ?? false
            case "-d": return FileInfo(path: path, follow: true)?.isDirectory ?? false
            case "-L", "-h": return FileInfo(path: path)?.isSymlink ?? false
            case "-s": return (FileInfo(path: path, follow: true)?.size ?? 0) > 0
            case "-r": return fileManager.isReadableFile(atPath: path)
            case "-w": return fileManager.isWritableFile(atPath: path)
            case "-x": return fileManager.isExecutableFile(atPath: path)
            case "-t": return v == "1" ? context.stdout.isTerminal : (v == "0" ? context.stdin.isTerminal : false)
            default: return nil
            }
        }
    }
}

enum Printf {
    static func format(_ format: String, _ arguments: [String]) -> String {
        var out = ""
        var remaining = arguments[...]
        let formatCharacters = Array(format)
        var consumedAny = false
        repeat {
            consumedAny = false
            var i = 0
            while i < formatCharacters.count {
                let c = formatCharacters[i]
                if c == "\\" {
                    var j = i + 1
                    if j < formatCharacters.count {
                        j += 1
                        if formatCharacters[i + 1] == "x" || ("0"..."7").contains(formatCharacters[i + 1]) {
                            while j < formatCharacters.count && j < i + 5 && formatCharacters[j].isHexDigit { j += 1 }
                        }
                    }
                    let (s, stop) = ShellFormat.unescape(String(formatCharacters[i..<j]))
                    out += s
                    if stop { return out }
                    i = j; continue
                }
                guard c == "%" else { out.append(c); i += 1; continue }
                i += 1
                guard i < formatCharacters.count else { out.append("%"); break }
                if formatCharacters[i] == "%" { out.append("%"); i += 1; continue }
                var specification = "%"
                while i < formatCharacters.count && "-+ #0".contains(formatCharacters[i]) { specification.append(formatCharacters[i]); i += 1 }
                while i < formatCharacters.count && (formatCharacters[i].isNumber || formatCharacters[i] == "." || formatCharacters[i] == "*") {
                    if formatCharacters[i] == "*" { specification += remaining.isEmpty ? "0" : remaining.removeFirst(); consumedAny = true } else { specification.append(formatCharacters[i]) }
                    i += 1
                }
                guard i < formatCharacters.count else { break }
                let conversion = formatCharacters[i]
                i += 1
                let argumentText: String? = remaining.isEmpty ? nil : remaining.removeFirst()
                if argumentText != nil { consumedAny = true }
                switch conversion {
                case "d", "i":
                    out += String(format: specification + "lld", parseInt(argumentText))
                case "u":
                    out += String(format: specification + "llu", UInt64(bitPattern: parseInt(argumentText)))
                case "x", "X", "o":
                    out += String(format: specification + "ll" + String(conversion), parseInt(argumentText))
                case "f", "F", "e", "E", "g", "G":
                    out += String(format: specification + String(conversion), Double(argumentText ?? "0") ?? 0)
                case "c":
                    out += argumentText.flatMap { $0.first.map(String.init) } ?? ""
                case "b":
                    let (s, _) = ShellFormat.unescape(argumentText ?? ""); out += pad(s, specification)
                case "q":
                    out += ShellBuiltins.quote(argumentText ?? "")
                default:
                    out += pad(argumentText ?? "", specification)
                }
            }
        } while consumedAny && !remaining.isEmpty
        return out
    }

    private static func parseInt(_ s: String?) -> Int64 {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        if s.hasPrefix("'") || s.hasPrefix("\""), let u = s.dropFirst().unicodeScalars.first { return Int64(u.value) }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int64(s.dropFirst(2), radix: 16) ?? 0 }
        return Int64(s) ?? Int64(Double(s) ?? 0)
    }

    private static func pad(_ s: String, _ specification: String) -> String {
        let body = specification.dropFirst()
        let left = body.contains("-")
        let numbers = body.filter { $0.isNumber || $0 == "." }
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        var value = s
        if parts.count > 1, let precision = Int(parts[1]) { value = String(value.prefix(precision)) }
        guard let w = parts.first.flatMap({ Int($0) }), w > value.count else { return value }
        let padding = String(repeating: " ", count: w - value.count)
        return left ? value + padding : padding + value
    }
}

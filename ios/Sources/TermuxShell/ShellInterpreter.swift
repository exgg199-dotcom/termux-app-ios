import Foundation

public struct StandardStreams {
    public var stdin: ShellInputStream
    public var stdout: ShellOutputStream
    public var stderr: ShellOutputStream
    public init(stdin: ShellInputStream, stdout: ShellOutputStream, stderr: ShellOutputStream) {
        self.stdin = stdin; self.stdout = stdout; self.stderr = stderr
    }
}

public final class ShellInterpreter {
    private let lock = NSRecursiveLock()

    public let homeDirectory: String
    public let registry: CommandRegistry
    public let history: ShellHistory
    public var shellName = "sh"

    private var _environment: [String: String]
    private var _currentDirectory: String
    private var _aliases: [String: String] = [:]
    private var _lastStatus: Int32 = 0
    private var _positional: [String] = []
    private var _exitRequested: Int32?
    private var _columns = 80
    private var _rows = 24
    private var _programRunner: ProgramRunner?
    public let startDate = Date()

    static let webAssemblyMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]

    public init(homeDirectory: String, environment: [String: String] = [:], registry: CommandRegistry = .standard(),
                history: ShellHistory? = nil) {
        let home = ShellPath.normalize(homeDirectory)
        self.homeDirectory = home
        self.registry = registry
        self.history = history ?? ShellHistory(file: nil)
        var initialEnvironment: [String: String] = [
            "HOME": home,
            "PWD": home,
            "PATH": home + "/bin",
            "SHELL": "sh",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8",
            "USER": SystemInfo.userName,
            "LOGNAME": SystemInfo.userName,
            "TMPDIR": ShellPath.normalize(NSTemporaryDirectory()),
            "HOSTNAME": SystemInfo.hostName,
        ]
        for (k, v) in environment { initialEnvironment[k] = v }
        _environment = initialEnvironment
        let workingDirectory = environment["PWD"].map { ShellPath.normalize($0) } ?? home
        _currentDirectory = workingDirectory
        _environment["PWD"] = workingDirectory
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public var environment: [String: String] { locked { _environment } }
    public func variable(_ name: String) -> String? { locked { _environment[name] } }
    public func setVariable(_ name: String, _ value: String?) { locked { _environment[name] = value } }

    public var currentDirectory: String {
        get { locked { _currentDirectory } }
        set {
            let n = ShellPath.normalize(newValue)
            locked {
                if _currentDirectory != n { _environment["OLDPWD"] = _currentDirectory }
                _currentDirectory = n
                _environment["PWD"] = n
            }
        }
    }

    public var aliases: [String: String] { locked { _aliases } }
    public func setAlias(_ name: String, _ value: String?) { locked { _aliases[name] = value } }

    public var lastStatus: Int32 { get { locked { _lastStatus } } set { locked { _lastStatus = newValue } } }
    public var positionalParameters: [String] { get { locked { _positional } } set { locked { _positional = newValue } } }

    public var exitRequested: Int32? { get { locked { _exitRequested } } set { locked { _exitRequested = newValue } } }

    public var terminalColumns: Int { get { locked { _columns } } set { locked { _columns = max(1, newValue) } } }
    public var terminalRows: Int { get { locked { _rows } } set { locked { _rows = max(1, newValue) } } }

    public var programRunner: ProgramRunner? { get { locked { _programRunner } } set { locked { _programRunner = newValue } } }

    public func subshell() -> ShellInterpreter {
        let child = ShellInterpreter(homeDirectory: homeDirectory, environment: environment, registry: registry, history: history)
        lock.lock()
        child._currentDirectory = _currentDirectory
        child._aliases = _aliases
        child._lastStatus = _lastStatus
        child._positional = _positional
        child._columns = _columns
        child._rows = _rows
        child._programRunner = _programRunner
        child.shellName = shellName
        lock.unlock()
        return child
    }

    public func parse(_ source: String) throws -> CommandList {
        try ShellParser.parse(source, aliases: aliases)
    }

    @discardableResult
    public func run(_ source: String, streams: StandardStreams, cancellation: CancellationToken = CancellationToken()) -> Int32 {
        do {
            let list = try parse(source)
            return execute(list, streams: streams, cancellation: cancellation)
        } catch let e as ShellSyntaxError {
            streams.stderr.writeLine("\(shellName): \(e.description)")
            lastStatus = 2
            return 2
        } catch {
            streams.stderr.writeLine("\(shellName): \(error)")
            lastStatus = 2
            return 2
        }
    }

    public func runCapturing(_ source: String, stdin: String = "") -> (status: Int32, stdout: String, stderr: String) {
        let output = BufferOutputStream(), errors = BufferOutputStream()
        let status = run(source, streams: StandardStreams(stdin: DataInputStream(stdin), stdout: output, stderr: errors))
        return (status, output.string, errors.string)
    }

    public func source(file path: String, arguments: [String], streams: StandardStreams, cancellation: CancellationToken) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            streams.stderr.writeLine("\(shellName): \(path): No such file or directory")
            return 1
        }
        let text = String(decoding: data, as: UTF8.self)
        let saved = positionalParameters
        if !arguments.isEmpty { positionalParameters = arguments }
        defer { if !arguments.isEmpty { positionalParameters = saved } }
        return run(text, streams: streams, cancellation: cancellation)
    }

    public func execute(_ list: CommandList, streams: StandardStreams, cancellation: CancellationToken) -> Int32 {
        var status = lastStatus
        for item in list.items {
            if exitRequested != nil || cancellation.isCancelled { break }
            status = execute(item, streams: streams, cancellation: cancellation)
        }
        if cancellation.isCancelled { status = 130; lastStatus = 130 }
        return status
    }

    private func execute(_ andOr: AndOrList, streams: StandardStreams, cancellation: CancellationToken) -> Int32 {
        var status = execute(andOr.first, streams: streams, cancellation: cancellation)
        for (operation, pipeline) in andOr.rest {
            if exitRequested != nil || cancellation.isCancelled { break }
            switch operation {
            case .and: if status != 0 { continue }
            case .or: if status == 0 { continue }
            }
            status = execute(pipeline, streams: streams, cancellation: cancellation)
        }
        return status
    }

    private func execute(_ pipeline: Pipeline, streams: StandardStreams, cancellation: CancellationToken) -> Int32 {
        var status: Int32
        if pipeline.commands.count == 1 {
            status = execute(pipeline.commands[0], streams: streams, cancellation: cancellation)
        } else {
            let n = pipeline.commands.count
            let pipes = (0..<(n - 1)).map { _ in PipeChannel(cancellation: cancellation) }
            let readers = pipes.map { $0.reader }
            let writers = pipes.map { $0.writer }
            let statuses = LockedBox([Int32](repeating: 0, count: n))
            let group = DispatchGroup()
            for (index, command) in pipeline.commands.enumerated() {
                let stageStreams = StandardStreams(stdin: index == 0 ? streams.stdin : readers[index - 1],
                                      stdout: index == n - 1 ? streams.stdout : writers[index],
                                      stderr: streams.stderr)
                group.enter()
                let thread = Thread { [self] in
                    let s = self.execute(command, streams: stageStreams, cancellation: cancellation)
                    if index < n - 1 { writers[index].close() }
                    if index > 0 { readers[index - 1].close() }
                    statuses.mutate { $0[index] = s }
                    group.leave()
                }
                thread.stackSize = 4 << 20
                thread.start()
            }
            withExtendedLifetime(pipes) { group.wait() }
            status = statuses.value[n - 1]
        }
        if pipeline.negated { status = status == 0 ? 1 : 0 }
        lastStatus = status
        return status
    }

    private func execute(_ node: CommandNode, streams: StandardStreams, cancellation: CancellationToken) -> Int32 {
        switch node {
        case .simple(let command):
            return executeSimple(command, streams: streams, cancellation: cancellation)
        case .subshell(let list, let redirs):
            var opened: [FileOutputStream] = []
            defer { opened.forEach { $0.close() } }
            guard let redirectedStreams = applyRedirections(redirs, streams: streams, cancellation: cancellation, opened: &opened) else { return 1 }
            let child = subshell()
            let s = child.execute(list, streams: redirectedStreams, cancellation: cancellation)
            return child.exitRequested ?? s
        }
    }

    private func executeSimple(_ command: SimpleCommand, streams: StandardStreams, cancellation: CancellationToken) -> Int32 {
        var assignments: [(String, String)] = []
        for a in command.assignments {
            assignments.append((a.name, expandNoSplit(a.value, streams: streams, cancellation: cancellation)))
        }
        let argumentVector = expand(command.words, streams: streams, cancellation: cancellation)
        if cancellation.isCancelled { return 130 }

        var opened: [FileOutputStream] = []
        defer { opened.forEach { $0.close() } }
        guard let redirectedStreams = applyRedirections(command.redirections, streams: streams, cancellation: cancellation, opened: &opened) else {
            lastStatus = 1
            return 1
        }

        if argumentVector.isEmpty {
            for (k, v) in assignments { setVariable(k, v) }
            return lastStatus
        }
        var commandEnvironment = environment
        for (k, v) in assignments { commandEnvironment[k] = v }
        let status = runCommand(argumentVector, streams: redirectedStreams, cancellation: cancellation, environment: commandEnvironment)
        redirectedStreams.stdout.flush()
        lastStatus = status
        return status
    }

    public func runCommand(_ argumentVector: [String], streams: StandardStreams, cancellation: CancellationToken, environment overrides: [String: String]? = nil) -> Int32 {
        guard let name = argumentVector.first else { return 0 }
        let commandEnvironment = overrides ?? environment
        if let command = registry.command(named: name) {
            let context = CommandContext(argumentVector: argumentVector, stdin: streams.stdin, stdout: streams.stdout, stderr: streams.stderr, shell: self,
                                     cancellation: cancellation, environment: commandEnvironment, currentDirectory: currentDirectory)
            return command.run(context)
        }
        if let script = findScript(name, environment: commandEnvironment) {
            return runScript(script, argumentVector: argumentVector, streams: streams, cancellation: cancellation, environment: commandEnvironment)
        }
        if name.contains("/") {
            let full = ShellPath.resolve(name, relativeTo: currentDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) {
                streams.stderr.writeLine("\(shellName): \(name): \(isDirectory.boolValue ? "Is a directory" : "Permission denied")")
                return 126
            }
            streams.stderr.writeLine("\(shellName): \(name): No such file or directory")
            return 127
        }
        streams.stderr.writeLine("\(shellName): \(name): command not found")
        return 127
    }

    public func findScript(_ name: String, environment overrides: [String: String]? = nil) -> String? {
        let fileManager = FileManager.default
        func isUsable(_ p: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: p, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        if name.contains("/") {
            let full = ShellPath.resolve(name, relativeTo: currentDirectory)
            guard isUsable(full), let info = FileInfo(path: full, follow: true),
                  info.isExecutable || name.hasSuffix(".sh") || name.hasSuffix(".wasm") else { return nil }
            return full
        }
        let path = (overrides ?? environment)["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let directoryPath = ShellPath.resolve(String(directory), relativeTo: currentDirectory)
            let full = ShellPath.resolve(name, relativeTo: directoryPath)
            if isUsable(full) { return full }
            let webAssemblyPath = ShellPath.resolve(name + ".wasm", relativeTo: directoryPath)
            if isUsable(webAssemblyPath) { return webAssemblyPath }
        }
        return nil
    }

    private func runScript(_ path: String, argumentVector: [String], streams: StandardStreams, cancellation: CancellationToken,
                           environment commandEnvironment: [String: String]) -> Int32 {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            streams.stderr.writeLine("\(shellName): \(argumentVector[0]): Permission denied"); return 126
        }
        let header = [UInt8](handle.readData(ofLength: 4096))
        handle.closeFile()
        if header.starts(with: ShellInterpreter.webAssemblyMagic) {
            guard let runner = programRunner else {
                streams.stderr.writeLine("\(shellName): \(argumentVector[0]): cannot execute WebAssembly program: no WebAssembly runtime in this build")
                return 126
            }
            let context = CommandContext(argumentVector: argumentVector, stdin: streams.stdin, stdout: streams.stdout, stderr: streams.stderr, shell: self,
                                         cancellation: cancellation, environment: commandEnvironment, currentDirectory: currentDirectory)
            return runner.run(programAt: path, context: context)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            streams.stderr.writeLine("\(shellName): \(argumentVector[0]): Permission denied"); return 126
        }
        let bytes = [UInt8](data.prefix(4096))
        let isText = !bytes.contains(0) && String(validatingUTF8: bytes.map { CChar(bitPattern: $0) } + [0]) != nil
        if bytes.starts(with: [0x7F, 0x45, 0x4C, 0x46]) {
            streams.stderr.writeLine("\(shellName): \(argumentVector[0]): cannot execute binary file: native Linux/Android programs cannot run on iOS (install WebAssembly packages with 'pkg install')")
            return 126
        }
        if bytes.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || !isText {
            streams.stderr.writeLine("\(shellName): \(argumentVector[0]): cannot execute binary file (iOS does not allow running native executables)")
            return 126
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("#!") {
            let first = text.prefix { $0 != "\n" }
            let interpreterLine = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let known = ["sh", "bash", "ash", "dash", "zsh"]
            let parts = interpreterLine.split(separator: " ").map(String.init)
            let programName = parts.first.map { ShellPath.basename($0) } ?? ""
            let target = programName == "env" ? (parts.dropFirst().first ?? "") : programName
            if !known.contains(target) {
                streams.stderr.writeLine("\(shellName): \(argumentVector[0]): interpreter '\(target)' is not available on iOS")
                return 126
            }
        }
        let child = subshell()
        for (name, value) in commandEnvironment where child.variable(name) != value { child.setVariable(name, value) }
        child.positionalParameters = argumentVector
        let s = child.run(text, streams: streams, cancellation: cancellation)
        return child.exitRequested ?? s
    }

    private func applyRedirections(_ redirs: [Redirection], streams: StandardStreams, cancellation: CancellationToken,
                                   opened: inout [FileOutputStream]) -> StandardStreams? {
        guard !redirs.isEmpty else { return streams }
        var stdin = streams.stdin
        var outs: [Int: ShellOutputStream] = [1: streams.stdout, 2: streams.stderr]
        for r in redirs {
            let target = expandNoSplit(r.target, streams: streams, cancellation: cancellation)
            let path = ShellPath.resolve(target, relativeTo: currentDirectory)
            switch r.operation {
            case .output, .append, .outputBoth, .appendBoth:
                if target == "/dev/null" {
                    outs[r.fileDescriptor] = NullOutputStream()
                    if r.operation == .outputBoth || r.operation == .appendBoth { outs[1] = NullOutputStream(); outs[2] = outs[1] }
                    continue
                }
                guard let f = FileOutputStream(path: path, append: r.operation == .append || r.operation == .appendBoth) else {
                    streams.stderr.writeLine("\(shellName): \(target): \(redirectionError(path))")
                    return nil
                }
                opened.append(f)
                if r.operation == .outputBoth || r.operation == .appendBoth { outs[1] = f; outs[2] = f } else { outs[r.fileDescriptor] = f }
            case .input:
                if target == "/dev/null" { stdin = EmptyInputStream(); continue }
                guard let f = FileInputStream(path: path) else {
                    streams.stderr.writeLine("\(shellName): \(target): \(redirectionError(path))")
                    return nil
                }
                stdin = f
            case .hereString:
                stdin = DataInputStream(target + "\n")
            case .duplicateOutput:
                if target == "-" { outs[r.fileDescriptor] = NullOutputStream(); continue }
                guard let source = Int(target), let s = outs[source] else {
                    if r.fileDescriptor == 1, !target.isEmpty, Int(target) == nil {
                        guard let f = FileOutputStream(path: path, append: false) else {
                            streams.stderr.writeLine("\(shellName): \(target): \(redirectionError(path))"); return nil
                        }
                        opened.append(f); outs[1] = f; outs[2] = f; continue
                    }
                    streams.stderr.writeLine("\(shellName): \(target): bad file descriptor"); return nil
                }
                outs[r.fileDescriptor] = s
            case .duplicateInput:
                if target == "0" { continue }
                if target == "-" { stdin = EmptyInputStream(); continue }
                streams.stderr.writeLine("\(shellName): \(target): bad file descriptor"); return nil
            }
        }
        return StandardStreams(stdin: stdin, stdout: outs[1] ?? streams.stdout, stderr: outs[2] ?? streams.stderr)
    }

    private func redirectionError(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return "Is a directory" }
        if !FileManager.default.fileExists(atPath: ShellPath.dirname(path)) { return "No such file or directory" }
        return "Permission denied"
    }

    private struct Field {
        var text = ""
        var pattern = ""
        var hasGlob = false
    }

    private static func escapeGlob(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "*" || c == "?" || c == "[" || c == "]" || c == "\\" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    public func expand(_ words: [ShellWord], streams: StandardStreams, cancellation: CancellationToken) -> [String] {
        var result: [String] = []
        for w in words {
            for f in expandFields(w, streams: streams, cancellation: cancellation) {
                if f.hasGlob {
                    let matches = Glob.expand(f.pattern, workingDirectory: currentDirectory)
                    if !matches.isEmpty { result.append(contentsOf: matches); continue }
                }
                result.append(f.text)
            }
        }
        return result
    }

    public func expandNoSplit(_ word: ShellWord, streams: StandardStreams, cancellation: CancellationToken) -> String {
        var out = ""
        for (index, part) in word.parts.enumerated() {
            switch part {
            case .literal(let s): out += index == 0 ? expandTilde(s) : s
            case .quoted(let s): out += s
            case .parameter(let p, _): out += expandParameter(p, streams: streams, cancellation: cancellation).joined(separator: " ")
            case .command(let source, _): out += commandSubstitution(source, streams: streams, cancellation: cancellation)
            case .arithmetic(let expression, _): out += arithmetic(expression, streams: streams, cancellation: cancellation)
            }
        }
        return out
    }

    private func expandTilde(_ s: String) -> String {
        guard s.hasPrefix("~") else { return s }
        let rest = s.dropFirst()
        if rest.isEmpty || rest.hasPrefix("/") { return homeDirectory + rest }
        if rest == "+" || rest.hasPrefix("+/") { return currentDirectory + rest.dropFirst() }
        if rest == "-" || rest.hasPrefix("-/"), let old = variable("OLDPWD") { return old + rest.dropFirst() }
        return s
    }

    private func expandFields(_ word: ShellWord, streams: StandardStreams, cancellation: CancellationToken) -> [Field] {
        var fields: [Field] = []
        var current: Field? = nil

        func appendQuoted(_ s: String) {
            if current == nil { current = Field() }
            current!.text += s
            current!.pattern += ShellInterpreter.escapeGlob(s)
        }
        func appendUnquoted(_ s: String, split: Bool) {
            for c in s {
                if split && (c == " " || c == "\t" || c == "\n") {
                    if let f = current { fields.append(f); current = nil }
                    continue
                }
                if current == nil { current = Field() }
                current!.text.append(c)
                current!.pattern.append(c)
                if c == "*" || c == "?" || c == "[" { current!.hasGlob = true }
            }
        }

        for (index, part) in word.parts.enumerated() {
            switch part {
            case .literal(let s):
                if index == 0 && s.hasPrefix("~") {
                    let expanded = expandTilde(s)
                    if expanded != s {
                        let slash = s.firstIndex(of: "/") ?? s.endIndex
                        let tildePart = String(s[..<slash])
                        let restPart = String(s[slash...])
                        appendQuoted(expandTilde(tildePart))
                        appendUnquoted(restPart, split: false)
                        continue
                    }
                }
                appendUnquoted(s, split: false)
            case .quoted(let s):
                appendQuoted(s)
            case .parameter(let p, let quoted):
                let values = expandParameter(p, streams: streams, cancellation: cancellation)
                if quoted {
                    if p.name == "@" && p.operation == nil && !p.length {
                        for (k, v) in values.enumerated() {
                            if k > 0 { if let f = current { fields.append(f) }; current = nil }
                            appendQuoted(v)
                        }
                    } else {
                        appendQuoted(values.joined(separator: " "))
                    }
                } else {
                    appendUnquoted(values.joined(separator: " "), split: true)
                }
            case .command(let source, let quoted):
                let v = commandSubstitution(source, streams: streams, cancellation: cancellation)
                if quoted { appendQuoted(v) } else { appendUnquoted(v, split: true) }
            case .arithmetic(let expression, let quoted):
                let v = arithmetic(expression, streams: streams, cancellation: cancellation)
                if quoted { appendQuoted(v) } else { appendUnquoted(v, split: true) }
            }
        }
        if let f = current { fields.append(f) }
        return fields
    }

    private func parameterValue(_ name: String) -> [String]? {
        switch name {
        case "?": return [String(lastStatus)]
        case "$": return [String(getpid())]
        case "#": return [String(max(0, positionalParameters.count - 1))]
        case "0": return [positionalParameters.first ?? shellName]
        case "@", "*": return Array(positionalParameters.dropFirst())
        case "!": return [""]
        case "-": return ["i"]
        case "RANDOM": return [String(Int.random(in: 0...32767))]
        case "SECONDS": return [String(Int(Date().timeIntervalSince(startDate)))]
        case "COLUMNS": return [String(terminalColumns)]
        case "LINES": return [String(terminalRows)]
        default:
            if let n = Int(name) {
                let p = positionalParameters
                return n < p.count ? [p[n]] : nil
            }
            return variable(name).map { [$0] }
        }
    }

    private func expandParameter(_ p: ParameterExpansion, streams: StandardStreams, cancellation: CancellationToken) -> [String] {
        let raw = parameterValue(p.name)
        if p.length { return [String((raw ?? []).joined(separator: " ").count)] }
        let value = raw?.joined(separator: " ")
        guard let operation = p.operation else { return raw ?? [] }
        func argumentText() -> String {
            guard let a = p.argument, !a.isEmpty else { return "" }
            if let tokens = try? ShellLexer.tokenize("\"" + a.replacingOccurrences(of: "\"", with: "\\\"") + "\""),
               case .word(let w)? = tokens.first {
                return expandNoSplit(w, streams: streams, cancellation: cancellation)
            }
            return a
        }
        let isSet = value != nil
        let isNonEmpty = !(value ?? "").isEmpty
        switch operation {
        case ":-": return [isNonEmpty ? value! : argumentText()]
        case "-": return [isSet ? value! : argumentText()]
        case ":=", "=":
            if operation == ":=" ? isNonEmpty : isSet { return [value!] }
            let v = argumentText(); setVariable(p.name, v); return [v]
        case ":+": return [isNonEmpty ? argumentText() : ""]
        case "+": return [isSet ? argumentText() : ""]
        case ":?", "?":
            if operation == ":?" ? isNonEmpty : isSet { return [value!] }
            let message = argumentText()
            streams.stderr.writeLine("\(shellName): \(p.name): \(message.isEmpty ? "parameter null or not set" : message)")
            return [""]
        case "#", "##", "%", "%%":
            let v = value ?? ""
            let pattern = argumentText()
            return [ShellInterpreter.removePattern(v, pattern: pattern, operation: operation)]
        default:
            return raw ?? []
        }
    }

    static func removePattern(_ value: String, pattern: String, operation: String) -> String {
        let chars = Array(value)
        let n = chars.count
        switch operation {
        case "#", "##":
            let range: [Int] = operation == "#" ? Array(0...n) : Array((0...n).reversed())
            for k in range where Glob.match(pattern, String(chars[0..<k])) { return String(chars[k...]) }
        default:
            let range: [Int] = operation == "%" ? Array((0...n).reversed()) : Array(0...n)
            for k in range where Glob.match(pattern, String(chars[k...])) { return String(chars[0..<k]) }
        }
        return value
    }

    private func commandSubstitution(_ source: String, streams: StandardStreams, cancellation: CancellationToken) -> String {
        let child = subshell()
        let out = BufferOutputStream()
        let s = child.run(source, streams: StandardStreams(stdin: streams.stdin, stdout: out, stderr: streams.stderr), cancellation: cancellation)
        lastStatus = child.exitRequested ?? s
        var text = out.string
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    private func arithmetic(_ expression: String, streams: StandardStreams, cancellation: CancellationToken) -> String {
        var expanded = expression
        if expression.contains("$") || expression.contains("`"),
           let tokens = try? ShellLexer.tokenize("\"" + expression.replacingOccurrences(of: "\"", with: "\\\"") + "\""),
           case .word(let w)? = tokens.first {
            expanded = expandNoSplit(w, streams: streams, cancellation: cancellation)
        }
        do {
            var evaluator = ArithmeticEvaluator(expanded) { [self] name in self.variable(name) }
            let v = try evaluator.evaluate { [self] name, value in self.setVariable(name, String(value)) }
            return String(v)
        } catch {
            streams.stderr.writeLine("\(shellName): \(expression): arithmetic syntax error")
            return "0"
        }
    }

    public func prompt() -> String {
        let workingDirectory = ShellPath.abbreviate(currentDirectory, home: homeDirectory)
        guard let promptTemplate = variable("PS1"), !promptTemplate.isEmpty else {
            return "\u{1B}[0;32m\(workingDirectory)\u{1B}[0m \u{1B}[0;97m$\u{1B}[0m "
        }
        var out = ""
        var it = promptTemplate.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "w": out += workingDirectory
            case "W": out += workingDirectory == "~" ? "~" : ShellPath.basename(currentDirectory)
            case "u": out += variable("USER") ?? SystemInfo.userName
            case "h": out += SystemInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
            case "H": out += SystemInfo.hostName
            case "$": out += getuid() == 0 ? "#" : "$"
            case "n": out += "\n"
            case "e": out += "\u{1B}"
            case "[", "]": break
            case "\\": out += "\\"
            case "t":
                let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; out += f.string(from: Date())
            case "d":
                let f = DateFormatter(); f.dateFormat = "EEE MMM dd"; out += f.string(from: Date())
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    public struct Completion: Equatable {
        public var wordStart: Int
        public var candidates: [String]
        public var displays: [String]
        public init(wordStart: Int, candidates: [String], displays: [String]) {
            self.wordStart = wordStart; self.candidates = candidates; self.displays = displays
        }
    }

    private static let wordBreakers: Set<Character> = [" ", "\t", ";", "|", "&", "<", ">", "(", ")"]

    public func complete(_ lineBeforeCursor: String) -> Completion {
        let chars = Array(lineBeforeCursor)
        var start = chars.count
        while start > 0 {
            let c = chars[start - 1]
            if ShellInterpreter.wordBreakers.contains(c) && !(start >= 2 && chars[start - 2] == "\\") { break }
            start -= 1
        }
        let rawWord = String(chars[start...])
        var word = ""
        var escaped = false
        for c in rawWord {
            if escaped { word.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "'" || c == "\"" { continue }
            word.append(c)
        }
        let before = String(chars[..<start]).trimmingCharacters(in: .whitespaces)
        let commandPosition = before.isEmpty || ["|", ";", "&", "(", "!"].contains(where: { before.hasSuffix($0) })
            || before == "sudo" || before.hasSuffix(" sudo") || before == "which" || before == "type" || before == "help"

        var candidates: [String] = []
        var displays: [String] = []
        if word.hasPrefix("$") && !word.contains("/") {
            let prefix = String(word.dropFirst())
            for k in environment.keys.sorted() where k.hasPrefix(prefix) {
                candidates.append("$" + k); displays.append(k)
            }
            return Completion(wordStart: start, candidates: candidates, displays: displays)
        }
        if commandPosition && !word.contains("/") {
            var names = Set(registry.names)
            names.formUnion(aliases.keys)
            for directory in (variable("PATH") ?? "").split(separator: ":") {
                let d = ShellPath.resolve(String(directory), relativeTo: currentDirectory)
                for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] { names.insert(f) }
            }
            for n in names.sorted() where n.hasPrefix(word) {
                candidates.append(ShellInterpreter.escapeForCompletion(n)); displays.append(n)
            }
            return Completion(wordStart: start, candidates: candidates, displays: displays)
        }
        let directoryPart: String
        let filePrefix: String
        if let slash = word.lastIndex(of: "/") {
            directoryPart = String(word[...slash])
            filePrefix = String(word[word.index(after: slash)...])
        } else {
            directoryPart = ""
            filePrefix = word
        }
        let listedDirectory = directoryPart.isEmpty ? currentDirectory : ShellPath.resolve(expandTilde(directoryPart), relativeTo: currentDirectory)
        let fileManager = FileManager.default
        let entries = ((try? fileManager.contentsOfDirectory(atPath: listedDirectory)) ?? []).sorted()
        for e in entries where e.hasPrefix(filePrefix) {
            if e.hasPrefix(".") && !filePrefix.hasPrefix(".") { continue }
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: listedDirectory + "/" + e, isDirectory: &isDirectory)
            let suffix = isDirectory.boolValue ? "/" : ""
            candidates.append(ShellInterpreter.escapeForCompletion(directoryPart + e) + suffix)
            displays.append(e + suffix)
        }
        if word == "~" { return Completion(wordStart: start, candidates: ["~/"], displays: ["~/"]) }
        return Completion(wordStart: start, candidates: candidates, displays: displays)
    }

    static func escapeForCompletion(_ s: String) -> String {
        var out = ""
        for c in s {
            if " \t'\"\\$&;|<>()*?[]!#`".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

public final class ShellHistory {
    private let lock = NSLock()
    private var entries: [String] = []
    public let file: String?
    public var maxEntries = 1000

    public init(file: String?) {
        self.file = file
        if let f = file, let data = FileManager.default.contents(atPath: f) {
            entries = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            if entries.count > maxEntries { entries = Array(entries.suffix(maxEntries)) }
        }
    }

    public var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }

    public func add(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !line.hasPrefix(" ") else { return }
        let entry = trimmed.replacingOccurrences(of: "\n", with: "; ")
        lock.lock(); defer { lock.unlock() }
        if entries.last == entry { return }
        entries.append(entry)
        var rewrite = false
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries); rewrite = true }
        guard let f = file else { return }
        if rewrite {
            try? (entries.joined(separator: "\n") + "\n").write(toFile: f, atomically: true, encoding: .utf8)
        } else if let out = FileOutputStream(path: f, append: true) {
            out.write(entry + "\n"); out.close()
        }
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
        if let f = file { try? "".write(toFile: f, atomically: true, encoding: .utf8) }
    }
}

public enum Glob {
    public static func match(_ pattern: String, _ string: String, ignoreCase: Bool = false) -> Bool {
        let p = Array(ignoreCase ? pattern.lowercased() : pattern)
        let s = Array(ignoreCase ? string.lowercased() : string)
        return match(p, 0, s, 0)
    }

    private static func match(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        var pi = pi, si = si
        var starP = -1, starS = -1
        while si < s.count {
            if pi < p.count {
                let c = p[pi]
                if c == "*" { starP = pi; starS = si; pi += 1; continue }
                if c == "?" { pi += 1; si += 1; continue }
                if c == "[", let (matched, next) = matchClass(p, pi, s[si]) {
                    if matched { pi = next; si += 1; continue }
                } else if c == "\\" && pi + 1 < p.count {
                    if p[pi + 1] == s[si] { pi += 2; si += 1; continue }
                } else if c == s[si] {
                    pi += 1; si += 1; continue
                }
            }
            if starP >= 0 { pi = starP + 1; starS += 1; si = starS; continue }
            return false
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func matchClass(_ p: [Character], _ start: Int, _ character: Character) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count && (p[i] == "!" || p[i] == "^") { negate = true; i += 1 }
        var matched = false
        var first = true
        while i < p.count {
            if p[i] == "]" && !first { return (matched != negate, i + 1) }
            first = false
            if p[i] == "[" && i + 1 < p.count && p[i + 1] == ":" {
                if let end = (i + 2..<p.count).first(where: { p[$0] == ":" && $0 + 1 < p.count && p[$0 + 1] == "]" }) {
                    let name = String(p[(i + 2)..<end])
                    if charClass(name, character) { matched = true }
                    i = end + 2; continue
                }
            }
            var lower = p[i]
            if lower == "\\" && i + 1 < p.count { i += 1; lower = p[i] }
            if i + 2 < p.count && p[i + 1] == "-" && p[i + 2] != "]" {
                let upper = p[i + 2]
                if lower <= character && character <= upper { matched = true }
                i += 3
            } else {
                if lower == character { matched = true }
                i += 1
            }
        }
        return nil
    }

    static func charClass(_ name: String, _ c: Character) -> Bool {
        switch name {
        case "alpha": return c.isLetter
        case "digit": return c.isASCII && c.isNumber
        case "alnum": return c.isLetter || c.isNumber
        case "upper": return c.isUppercase
        case "lower": return c.isLowercase
        case "space": return c.isWhitespace
        case "punct": return c.isPunctuation || c.isSymbol
        case "xdigit": return c.isHexDigit
        default: return false
        }
    }

    public static func hasMeta(_ s: String) -> Bool {
        var escaped = false
        for c in s {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "*" || c == "?" || c == "[" { return true }
        }
        return false
    }

    static func unescape(_ s: String) -> String {
        var out = ""; var escaped = false
        for c in s {
            if escaped { out.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            out.append(c)
        }
        return out
    }

    public static func expand(_ pattern: String, workingDirectory: String) -> [String] {
        let absolute = pattern.hasPrefix("/")
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let trailingSlash = pattern.hasSuffix("/")
        var results: [(display: String, full: String)] = [(absolute ? "/" : "", absolute ? "/" : workingDirectory)]
        let fileManager = FileManager.default
        for (index, comp) in components.enumerated() {
            let isLast = index == components.count - 1
            var next: [(String, String)] = []
            for (display, full) in results {
                let joinDisplay: (String) -> String = { name in
                    display.isEmpty ? name : (display.hasSuffix("/") ? display + name : display + "/" + name)
                }
                let joinFull: (String) -> String = { name in full.hasSuffix("/") ? full + name : full + "/" + name }
                if !hasMeta(comp) {
                    let name = unescape(comp)
                    let f = joinFull(name)
                    if isLast && !trailingSlash {
                        if FileInfo(path: f) != nil { next.append((joinDisplay(name), f)) }
                    } else {
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: f, isDirectory: &isDirectory), isDirectory.boolValue || name == ".." || name == "." {
                            next.append((joinDisplay(name), f))
                        }
                    }
                    continue
                }
                guard let entries = try? fileManager.contentsOfDirectory(atPath: full) else { continue }
                for e in entries.sorted() {
                    if e.hasPrefix(".") && !comp.hasPrefix(".") && !comp.hasPrefix("\\.") { continue }
                    guard match(comp, e) else { continue }
                    let f = joinFull(e)
                    if !isLast || trailingSlash {
                        var isDirectory: ObjCBool = false
                        guard fileManager.fileExists(atPath: f, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                    }
                    next.append((joinDisplay(e), f))
                }
            }
            results = next
            if results.isEmpty { return [] }
        }
        return results.map { trailingSlash ? $0.display + "/" : $0.display }
    }
}

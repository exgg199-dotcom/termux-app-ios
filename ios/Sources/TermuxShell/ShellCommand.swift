import Foundation

public protocol ShellCommand {
    var name: String { get }
    var summary: String { get }
    func run(_ context: CommandContext) -> Int32
}

public extension ShellCommand {
    var summary: String { "" }
}

public struct ClosureCommand: ShellCommand {
    public let name: String
    public let summary: String
    private let body: (CommandContext) -> Int32
    public init(_ name: String, _ summary: String = "", _ body: @escaping (CommandContext) -> Int32) {
        self.name = name; self.summary = summary; self.body = body
    }
    public func run(_ context: CommandContext) -> Int32 { body(context) }
}

public final class CommandRegistry {
    private let lock = NSLock()
    private var commands: [String: ShellCommand] = [:]

    public init() {}

    public func register(_ command: ShellCommand) {
        lock.lock(); commands[command.name] = command; lock.unlock()
    }

    public func register(_ name: String, _ summary: String = "", _ body: @escaping (CommandContext) -> Int32) {
        register(ClosureCommand(name, summary, body))
    }

    public func alias(_ alias: String, to name: String) {
        guard let command = command(named: name) else { return }
        register(ClosureCommand(alias, command.summary) { command.run($0) })
    }

    public func unregister(_ name: String) { lock.lock(); commands[name] = nil; lock.unlock() }

    public func command(named name: String) -> ShellCommand? {
        lock.lock(); defer { lock.unlock() }
        return commands[name]
    }

    public var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands.keys.sorted()
    }

    public var allCommands: [ShellCommand] {
        lock.lock(); defer { lock.unlock() }
        return commands.keys.sorted().compactMap { commands[$0] }
    }

    public static func standard() -> CommandRegistry {
        let r = CommandRegistry()
        ShellBuiltins.registerShellCommands(r)
        FileCommands.register(r)
        TextCommands.register(r)
        SystemCommands.register(r)
        NetworkCommands.register(r)
        PackageCommands.register(r)
        return r
    }
}

public final class CommandContext {
    public let argumentVector: [String]
    public let stdin: ShellInputStream
    public let stdout: ShellOutputStream
    public let stderr: ShellOutputStream
    public let shell: ShellInterpreter
    public let cancellation: CancellationToken
    public let environment: [String: String]
    public let currentDirectory: String

    public init(argumentVector: [String], stdin: ShellInputStream, stdout: ShellOutputStream, stderr: ShellOutputStream,
                shell: ShellInterpreter, cancellation: CancellationToken, environment: [String: String], currentDirectory: String) {
        self.argumentVector = argumentVector; self.stdin = stdin; self.stdout = stdout; self.stderr = stderr
        self.shell = shell; self.cancellation = cancellation; self.environment = environment
        self.currentDirectory = currentDirectory
    }

    public var name: String { argumentVector.first ?? "" }
    public var arguments: [String] { Array(argumentVector.dropFirst()) }
    public var isCancelled: Bool { cancellation.isCancelled }
    public var shouldStop: Bool { cancellation.isCancelled || stdout.isClosed }
    public var terminalColumns: Int { shell.terminalColumns }
    public var homeDirectory: String { shell.homeDirectory }

    public func resolve(_ path: String) -> String {
        ShellPath.resolve(path, relativeTo: currentDirectory)
    }

    public func error(_ message: String) {
        stderr.writeLine("\(name): \(message)")
    }

    public func print(_ s: String = "") { stdout.writeLine(s) }

    public func openInput(_ path: String) -> ShellInputStream? {
        if path == "-" { return stdin }
        let full = resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) else {
            error("\(path): No such file or directory"); return nil
        }
        if isDirectory.boolValue { error("\(path): Is a directory"); return nil }
        guard let s = FileInputStream(path: full) else { error("\(path): Permission denied"); return nil }
        return s
    }

    public func forEachInput(_ files: [String], _ body: (ShellInputStream, String) -> Void) -> Int32 {
        if files.isEmpty { body(stdin, "-"); return 0 }
        var status: Int32 = 0
        for f in files {
            if shouldStop { break }
            guard let input = openInput(f) else { status = 1; continue }
            body(input, f)
            if input !== stdin { input.close() }
        }
        return status
    }
}

final class LockedBox<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

public struct ParsedOptions {
    public var flags: Set<Character> = []
    public var values: [Character: String] = [:]
    public var longFlags: Set<String> = []
    public var longValues: [String: String] = [:]
    public var operands: [String] = []
    public var error: String?

    public func has(_ c: Character) -> Bool { flags.contains(c) }
    public func value(_ c: Character) -> String? { values[c] }

    public init(_ arguments: [String], flags allowed: String, withValues: String = "", longFlags allowedLong: Set<String> = []) {
        var i = 0
        var onlyOperands = false
        while i < arguments.count {
            let a = arguments[i]
            i += 1
            if onlyOperands || a == "-" || !a.hasPrefix("-") { operands.append(a); continue }
            if a == "--" { onlyOperands = true; continue }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    longValues[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if allowedLong.contains(body) || allowedLong.isEmpty {
                    longFlags.insert(body)
                } else {
                    error = "unrecognized option '\(a)'"
                }
                continue
            }
            let chars = Array(a.dropFirst())
            var k = 0
            while k < chars.count {
                let c = chars[k]
                if withValues.contains(c) {
                    let rest = String(chars[(k + 1)...])
                    if !rest.isEmpty { values[c] = rest }
                    else if i < arguments.count { values[c] = arguments[i]; i += 1 }
                    else { error = "option requires an argument -- '\(c)'" }
                    break
                } else if allowed.contains(c) {
                    flags.insert(c)
                } else {
                    error = "invalid option -- '\(c)'"
                }
                k += 1
            }
        }
    }
}

public enum ShellPath {
    public static func resolve(_ path: String, relativeTo base: String) -> String {
        let full = path.hasPrefix("/") ? path : (base.hasSuffix("/") ? base + path : base + "/" + path)
        return normalize(full)
    }

    public static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(c)
        }
        return "/" + components.joined(separator: "/")
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        let h = normalize(home)
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    public static func basename(_ path: String) -> String {
        if path == "/" { return "/" }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if let index = p.lastIndex(of: "/") { return String(p[p.index(after: index)...]) }
        return p
    }

    public static func dirname(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let index = p.lastIndex(of: "/") else { return "." }
        if index == p.startIndex { return "/" }
        var d = String(p[..<index])
        while d.count > 1 && d.hasSuffix("/") { d.removeLast() }
        return d
    }
}

public struct FileInfo {
    public let path: String
    public let mode: UInt32
    public let size: Int64
    public let linkCount: Int
    public let userIdentifier: UInt32
    public let groupIdentifier: UInt32
    public let modificationDate: Date

    public var isDirectory: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) }
    public var isSymlink: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFLNK) }
    public var isRegular: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFREG) }
    public var isExecutable: Bool { !isDirectory && (mode & 0o111) != 0 }
    public var permissions: UInt32 { mode & 0o7777 }

    public init?(path: String, follow: Bool = false) {
        var fileStatus = stat()
        let result = follow ? stat(path, &fileStatus) : lstat(path, &fileStatus)
        guard result == 0 else { return nil }
        self.path = path
        mode = UInt32(fileStatus.st_mode)
        size = Int64(fileStatus.st_size)
        linkCount = Int(fileStatus.st_nlink)
        userIdentifier = UInt32(fileStatus.st_uid)
        groupIdentifier = UInt32(fileStatus.st_gid)
        #if os(Linux)
        modificationDate = Date(timeIntervalSince1970: Double(fileStatus.st_mtim.tv_sec) + Double(fileStatus.st_mtim.tv_nsec) / 1e9)
        #else
        modificationDate = Date(timeIntervalSince1970: Double(fileStatus.st_mtimespec.tv_sec) + Double(fileStatus.st_mtimespec.tv_nsec) / 1e9)
        #endif
    }

    public var typeChar: Character {
        switch mode & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): return "d"
        case UInt32(S_IFLNK): return "l"
        case UInt32(S_IFCHR): return "c"
        case UInt32(S_IFBLK): return "b"
        case UInt32(S_IFIFO): return "p"
        case UInt32(S_IFSOCK): return "s"
        default: return "-"
        }
    }

    public var permissionString: String {
        var s = String(typeChar)
        let bits: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (b, c) in bits { s.append((mode & b) != 0 ? c : "-") }
        return s
    }

    public var userName: String { FileInfo.userName(userIdentifier) }
    public var groupName: String { FileInfo.groupName(groupIdentifier) }

    public static func userName(_ userIdentifier: UInt32) -> String {
        if let passwordEntry = getpwuid(uid_t(userIdentifier)), let n = passwordEntry.pointee.pw_name { return String(cString: n) }
        return String(userIdentifier)
    }
    public static func groupName(_ groupIdentifier: UInt32) -> String {
        if let groupEntry = getgrgid(gid_t(groupIdentifier)), let n = groupEntry.pointee.gr_name { return String(cString: n) }
        return String(groupIdentifier)
    }
}

public enum ShellFormat {
    public static func humanSize(_ bytes: Int64) -> String {
        let units = ["", "K", "M", "G", "T", "P"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        if index == 0 { return String(bytes) }
        if value < 10 { return String(format: "%.1f%@", (value * 10).rounded(.up) / 10, units[index]) }
        return String(format: "%.0f%@", value.rounded(.up), units[index])
    }

    public static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let w = DisplayWidth.of(s)
        if w >= width { return s }
        let padding = String(repeating: " ", count: width - w)
        return right ? padding + s : s + padding
    }

    public static func columns(_ items: [String], display: [String]? = nil, width: Int) -> String {
        guard !items.isEmpty else { return "" }
        let shown = display ?? items
        let widths = items.map { DisplayWidth.of($0) }
        let maxWidth = widths.max() ?? 0
        let colWidth = maxWidth + 2
        let columnCount = max(1, min(items.count, (width + 2) / max(1, colWidth)))
        var best: (rows: Int, colWidths: [Int])? = nil
        var c = min(items.count, max(1, width / 3))
        while c >= 1 {
            let rows = (items.count + c - 1) / c
            var columnWidths: [Int] = []
            for column in 0..<c {
                var m = 0
                for row in 0..<rows { let i = column * rows + row; if i < items.count { m = max(m, widths[i]) } }
                columnWidths.append(m)
            }
            let total = columnWidths.reduce(0, +) + 2 * (c - 1)
            if total <= width { best = (rows, columnWidths); break }
            c -= 1
        }
        let layout = best ?? ((items.count + columnCount - 1) / columnCount, Array(repeating: maxWidth, count: columnCount))
        var out = ""
        for row in 0..<layout.rows {
            var line = ""
            for column in 0..<layout.colWidths.count {
                let i = column * layout.rows + row
                guard i < items.count else { continue }
                let isLast = (column + 1) * layout.rows + row >= items.count
                line += shown[i]
                if !isLast { line += String(repeating: " ", count: layout.colWidths[column] - widths[i] + 2) }
            }
            out += line + "\n"
        }
        return out
    }

    public static func unescape(_ s: String) -> (String, Bool) {
        var out = ""
        let chars = Array(s.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else { out.unicodeScalars.append(c); i += 1; continue }
            let n = chars[i + 1]
            i += 2
            switch n {
            case "n": out += "\n"
            case "t": out += "\t"
            case "r": out += "\r"
            case "a": out += "\u{07}"
            case "b": out += "\u{08}"
            case "f": out += "\u{0C}"
            case "v": out += "\u{0B}"
            case "e", "E": out += "\u{1B}"
            case "\\": out += "\\"
            case "c": return (out, true)
            case "0", "1", "2", "3", "4", "5", "6", "7":
                var v = 0; var digits = 0
                var j = i - 1
                if n == "0" { j = i }
                while j < chars.count, digits < 3, let d = Int(String(chars[j])), d < 8 { v = v * 8 + d; j += 1; digits += 1 }
                i = j
                if let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            case "x":
                var v = 0; var digits = 0
                while i < chars.count, digits < 2, let d = Int(String(chars[i]), radix: 16) { v = v * 16 + d; i += 1; digits += 1 }
                if digits == 0 { out += "\\x" } else if let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            case "u", "U":
                var v = 0; var digits = 0
                let maxD = n == "u" ? 4 : 8
                while i < chars.count, digits < maxD, let d = Int(String(chars[i]), radix: 16) { v = v * 16 + d; i += 1; digits += 1 }
                if digits == 0 { out += "\\" + String(n) } else if let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            default:
                out += "\\"; out.unicodeScalars.append(n)
            }
        }
        return (out, false)
    }
}

public enum ANSI {
    public static let reset = "\u{1B}[0m"
    public static let bold = "\u{1B}[1m"
    public static let red = "\u{1B}[31m"
    public static let boldRed = "\u{1B}[1;31m"
    public static let green = "\u{1B}[32m"
    public static let boldGreen = "\u{1B}[1;32m"
    public static let yellow = "\u{1B}[33m"
    public static let boldBlue = "\u{1B}[1;34m"
    public static let magenta = "\u{1B}[35m"
    public static let boldMagenta = "\u{1B}[1;35m"
    public static let cyan = "\u{1B}[36m"
    public static let boldCyan = "\u{1B}[1;36m"
    public static let clearScreen = "\u{1B}[H\u{1B}[2J\u{1B}[3J"

    public static func strip(_ s: String) -> String {
        var out = ""
        var it = Array(s.unicodeScalars)
        var i = 0
        while i < it.count {
            let c = it[i]
            if c == "\u{1B}" && i + 1 < it.count {
                if it[i + 1] == "[" {
                    i += 2
                    while i < it.count && !(0x40...0x7E).contains(it[i].value) { i += 1 }
                    i += 1; continue
                } else if it[i + 1] == "]" {
                    i += 2
                    while i < it.count && it[i] != "\u{07}" && !(it[i] == "\u{1B}" && i + 1 < it.count && it[i + 1] == "\\") { i += 1 }
                    i += (i < it.count && it[i] == "\u{07}") ? 1 : 2; continue
                } else { i += 2; continue }
            }
            out.unicodeScalars.append(c); i += 1
        }
        it.removeAll()
        return out
    }
}

public enum DisplayWidth {
    public static func of(scalar u: Unicode.Scalar) -> Int {
        let v = u.value
        if v == 0 { return 0 }
        if v < 32 || (v >= 0x7F && v < 0xA0) { return 0 }
        switch u.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if v == 0x200B || (0x1160...0x11FF).contains(v) { return 0 }
        if isWide(v) { return 2 }
        return 1
    }

    static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB,
             0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD,
             0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF,
             0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF, 0x1B000...0x1B2FF,
             0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251, 0x1F300...0x1F320, 0x1F32D...0x1F335,
             0x1F337...0x1F37C, 0x1F37E...0x1F393, 0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3, 0x1F3E0...0x1F3F0,
             0x1F3F4, 0x1F3F8...0x1F43E, 0x1F440, 0x1F442...0x1F4FC, 0x1F4FF...0x1F53D, 0x1F54B...0x1F54E,
             0x1F550...0x1F567, 0x1F57A, 0x1F595...0x1F596, 0x1F5A4, 0x1F5FB...0x1F64F, 0x1F680...0x1F6C5,
             0x1F6CC, 0x1F6D0...0x1F6D2, 0x1F6D5...0x1F6D7, 0x1F6EB...0x1F6EC, 0x1F6F4...0x1F6FC, 0x1F7E0...0x1F7EB,
             0x1F90C...0x1F93A, 0x1F93C...0x1F945, 0x1F947...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    public static func of(_ c: Character) -> Int {
        var w = 0
        for (i, u) in c.unicodeScalars.enumerated() {
            if i == 0 { w = of(scalar: u) } else if u.value == 0xFE0F { w = max(w, 2) }
        }
        return w
    }

    public static func of(_ s: String) -> Int {
        let plain = s.contains("\u{1B}") ? ANSI.strip(s) : s
        return plain.reduce(0) { $0 + of($1) }
    }
}

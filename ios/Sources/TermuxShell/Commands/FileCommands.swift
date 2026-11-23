import Foundation

enum FileCommands {
    static let fileManager = FileManager.default

    static func register(_ r: CommandRegistry) {
        r.register("ls", "list directory contents (-l -a -A -h -1 -d -t -S -r -R -F)") { ls($0) }
        r.register("cat", "concatenate files (-n number lines)") { cat($0) }
        r.register("mkdir", "create directories (-p parents)") { mkdir($0) }
        r.register("rmdir", "remove empty directories") { rmdir($0) }
        r.register("rm", "remove files (-r recursive, -f force)") { rm($0) }
        r.register("cp", "copy files (-r recursive)") { cp($0) }
        r.register("mv", "move/rename files") { mv($0) }
        r.register("touch", "create files or update timestamps") { touch($0) }
        r.register("ln", "create links (-s symbolic)") { ln($0) }
        r.register("find", "search for files (-name -iname -type -maxdepth)") { find($0) }
        r.register("du", "estimate file space usage (-h -s)") { du($0) }
        r.register("df", "report file system space usage") { df($0) }
        r.register("stat", "display file status") { stat($0) }
        r.register("chmod", "change file mode bits") { chmod($0) }
        r.register("tree", "list directories as a tree (-a -L depth -d)") { tree($0) }
        r.register("realpath", "print the resolved absolute path") { context in
            var status: Int32 = 0
            for a in context.arguments where !a.hasPrefix("-") {
                let p = context.resolve(a)
                if !fileManager.fileExists(atPath: p) && !context.arguments.contains("-m") { context.error("\(a): No such file or directory"); status = 1; continue }
                context.print(URL(fileURLWithPath: p).resolvingSymlinksInPath().path)
            }
            return status
        }
        r.register("basename", "strip directory and suffix from a file name") { context in
            guard let name = context.arguments.first else { context.error("missing operand"); return 1 }
            var b = ShellPath.basename(name)
            if context.arguments.count > 1, b.hasSuffix(context.arguments[1]), b != context.arguments[1] { b = String(b.dropLast(context.arguments[1].count)) }
            context.print(b)
            return 0
        }
        r.register("dirname", "strip the last component from a file name") { context in
            guard !context.arguments.isEmpty else { context.error("missing operand"); return 1 }
            for a in context.arguments { context.print(ShellPath.dirname(a)) }
            return 0
        }
    }

    static func errorDescription(_ error: Error) -> String {
        let nativeString = error as NSError
        if let underlying = nativeString.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        switch nativeString.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "No such file or directory"
        case NSFileWriteFileExistsError: return "File exists"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "Permission denied"
        case NSFileWriteOutOfSpaceError: return "No space left on device"
        default: return nativeString.localizedDescription
        }
    }

    struct Entry {
        let name: String
        let path: String
        let info: FileInfo?
    }

    static func colorize(_ name: String, _ info: FileInfo?, path: String) -> String {
        guard let info = info else { return name }
        if info.isSymlink {
            let broken = !fileManager.fileExists(atPath: path)
            return (broken ? ANSI.boldRed : ANSI.boldCyan) + name + ANSI.reset
        }
        if info.isDirectory { return ANSI.boldBlue + name + ANSI.reset }
        if info.isExecutable { return ANSI.boldGreen + name + ANSI.reset }
        switch info.typeChar {
        case "p": return ANSI.yellow + name + ANSI.reset
        case "s": return ANSI.boldMagenta + name + ANSI.reset
        case "c", "b": return "\u{1B}[1;33m" + name + ANSI.reset
        default: return name
        }
    }

    static func classify(_ info: FileInfo?) -> String {
        guard let i = info else { return "" }
        if i.isDirectory { return "/" }
        if i.isSymlink { return "@" }
        if i.isExecutable { return "*" }
        if i.typeChar == "p" { return "|" }
        return ""
    }

    static let recentFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM dd HH:mm"; return f
    }()
    static let oldFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM dd  yyyy"; return f
    }()

    static func ls(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "laAh1dtSrRFG", longFlags: [])
        if let e = options.error { context.error(e); return 2 }
        let all = options.has("a"), almostAll = options.has("A")
        let long = options.has("l")
        let human = options.has("h")
        let color: Bool = {
            switch options.longValues["color"] ?? (options.longFlags.contains("color") ? "always" : "auto") {
            case "always", "yes", "force": return true
            case "never", "no", "none": return false
            default: return context.stdout.isTerminal
            }
        }()
        let onePerLine = options.has("1") || !context.stdout.isTerminal
        var operands = options.operands
        if operands.isEmpty { operands = ["."] }
        var status: Int32 = 0

        func sortEntries(_ e: [Entry]) -> [Entry] {
            var s: [Entry]
            if options.has("t") {
                s = e.sorted { ($0.info?.modificationDate ?? .distantPast) > ($1.info?.modificationDate ?? .distantPast) }
            } else if options.has("S") {
                s = e.sorted { ($0.info?.size ?? 0) > ($1.info?.size ?? 0) }
            } else {
                func key(_ n: String) -> String { String(n.drop(while: { $0 == "." })).lowercased() }
                s = e.sorted { (key($0.name), $0.name) < (key($1.name), $1.name) }
            }
            return options.has("r") ? s.reversed() : s
        }

        func display(_ e: Entry) -> String {
            var name = color ? colorize(e.name, e.info, path: e.path) : e.name
            if options.has("F") { name += classify(e.info) }
            return name
        }

        func printEntries(_ entries: [Entry], showTotal: Bool) {
            if entries.isEmpty { return }
            if long {
                if showTotal {
                    let blocks = entries.reduce(Int64(0)) { $0 + (($1.info?.size ?? 0) + 4095) / 4096 * 4 }
                    context.print("total \(human ? ShellFormat.humanSize(blocks * 1024) : String(blocks))")
                }
                let sixMonthsAgo = Date(timeIntervalSinceNow: -182 * 86400)
                var rows: [[String]] = []
                for e in entries {
                    guard let i = e.info else { continue }
                    let size = human ? ShellFormat.humanSize(i.size) : String(i.size)
                    let date = i.modificationDate > sixMonthsAgo && i.modificationDate < Date(timeIntervalSinceNow: 3600)
                        ? recentFormatter.string(from: i.modificationDate) : oldFormatter.string(from: i.modificationDate)
                    var name = display(e)
                    if i.isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: e.path) { name += " -> " + target }
                    rows.append([i.permissionString, String(i.linkCount), i.userName, i.groupName, size, date, name])
                }
                let w = (0..<6).map { c in rows.map { $0[c].count }.max() ?? 0 }
                for row in rows {
                    let line = [row[0], ShellFormat.pad(row[1], w[1], right: true), ShellFormat.pad(row[2], w[2]),
                                ShellFormat.pad(row[3], w[3]), ShellFormat.pad(row[4], w[4], right: true), row[5], row[6]]
                    context.print(line.joined(separator: " "))
                }
            } else if onePerLine {
                for e in entries { context.print(display(e)) }
            } else {
                let plain = entries.map { $0.name + (options.has("F") ? classify($0.info) : "") }
                context.stdout.write(ShellFormat.columns(plain, display: entries.map(display), width: context.terminalColumns))
            }
        }

        var files: [Entry] = []
        var directories: [(String, String)] = []
        for operation in operands {
            let path = context.resolve(operation)
            guard let info = FileInfo(path: path) else {
                context.error("cannot access '\(operation)': No such file or directory"); status = 2; continue
            }
            let followed = info.isSymlink ? FileInfo(path: path, follow: true) : info
            if (followed?.isDirectory ?? false) && !options.has("d") && !(info.isSymlink && long) {
                directories.append((operation, path))
            } else {
                files.append(Entry(name: operation, path: path, info: info))
            }
        }
        printEntries(sortEntries(files), showTotal: false)
        let showHeaders = operands.count > 1 || options.has("R")
        var first = files.isEmpty
        var queue = directories
        while !queue.isEmpty {
            if context.shouldStop { break }
            let (label, path) = queue.removeFirst()
            if !first { context.print() }
            first = false
            if showHeaders { context.print("\(label):") }
            guard var names = try? fileManager.contentsOfDirectory(atPath: path) else {
                context.error("cannot open directory '\(label)': Permission denied"); status = 2; continue
            }
            if !all && !almostAll { names = names.filter { !$0.hasPrefix(".") } }
            if all { names += [".", ".."] }
            let entries = sortEntries(names.map { n in
                let p = path == "/" ? "/" + n : path + "/" + n
                return Entry(name: n, path: p, info: FileInfo(path: p))
            })
            printEntries(entries, showTotal: true)
            if options.has("R") {
                let subcontext = entries.filter { $0.info?.isDirectory == true && $0.name != "." && $0.name != ".." }
                    .map { (label == "." ? "./" + $0.name : (label.hasSuffix("/") ? label + $0.name : label + "/" + $0.name), $0.path) }
                queue.insert(contentsOf: subcontext, at: 0)
            }
        }
        return status
    }

    static func cat(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "nbuvAeEtT")
        if let e = options.error { context.error(e); return 1 }
        let number = options.has("n") || options.has("b")
        var lineNumber = 0
        return context.forEachInput(options.operands) { input, _ in
            if number {
                let reader = LineReader(input)
                while let line = reader.nextLineBytes() {
                    if context.shouldStop { break }
                    if options.has("b") && line.isEmpty { context.stdout.write("\n"); continue }
                    lineNumber += 1
                    context.stdout.write(ShellFormat.pad(String(lineNumber), 6, right: true) + "\t")
                    context.stdout.write(line + [0x0A])
                }
            } else {
                while !context.shouldStop, let chunk = input.read(maxLength: 65536) { context.stdout.write(chunk) }
            }
        }
    }

    static func mkdir(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "pv", withValues: "m")
        if let e = options.error { context.error(e); return 1 }
        guard !options.operands.isEmpty else { context.error("missing operand"); return 1 }
        var status: Int32 = 0
        for d in options.operands {
            let path = context.resolve(d)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                if options.has("p") && isDirectory.boolValue { continue }
                context.error("cannot create directory '\(d)': File exists"); status = 1; continue
            }
            if !options.has("p") && !fileManager.fileExists(atPath: ShellPath.dirname(path)) {
                context.error("cannot create directory '\(d)': No such file or directory"); status = 1; continue
            }
            do {
                var attributes: [FileAttributeKey: Any]? = nil
                if let m = options.value("m"), let mode = Int(m, radix: 8) { attributes = [.posixPermissions: mode] }
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: options.has("p"), attributes: attributes)
                if options.has("v") { context.print("mkdir: created directory '\(d)'") }
            } catch {
                context.error("cannot create directory '\(d)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    static func rmdir(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "pv")
        guard !options.operands.isEmpty else { context.error("missing operand"); return 1 }
        var status: Int32 = 0
        for d in options.operands {
            let path = context.resolve(d)
            guard let info = FileInfo(path: path) else { context.error("failed to remove '\(d)': No such file or directory"); status = 1; continue }
            guard info.isDirectory else { context.error("failed to remove '\(d)': Not a directory"); status = 1; continue }
            if let c = try? fileManager.contentsOfDirectory(atPath: path), !c.isEmpty {
                context.error("failed to remove '\(d)': Directory not empty"); status = 1; continue
            }
            do { try fileManager.removeItem(atPath: path) } catch { context.error("failed to remove '\(d)': \(errorDescription(error))"); status = 1 }
        }
        return status
    }

    static func rm(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "rRfvid")
        if let e = options.error { context.error(e); return 1 }
        let force = options.has("f"), recursive = options.has("r") || options.has("R")
        if options.operands.isEmpty { if force { return 0 }; context.error("missing operand"); return 1 }
        var status: Int32 = 0
        for f in options.operands {
            let path = context.resolve(f)
            if path == "/" || path == context.homeDirectory && f != "." && recursive && !force {
                context.error("refusing to remove '\(f)'"); status = 1; continue
            }
            if ShellPath.basename(f) == "." || ShellPath.basename(f) == ".." {
                context.error("refusing to remove '.' or '..' directory: skipping '\(f)'"); status = 1; continue
            }
            guard let info = FileInfo(path: path) else {
                if !force { context.error("cannot remove '\(f)': No such file or directory"); status = 1 }
                continue
            }
            if info.isDirectory && !recursive {
                if options.has("d"), (try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty == true {
                    try? fileManager.removeItem(atPath: path); continue
                }
                context.error("cannot remove '\(f)': Is a directory"); status = 1; continue
            }
            do {
                try fileManager.removeItem(atPath: path)
                if options.has("v") { context.print("removed '\(f)'") }
            } catch {
                context.error("cannot remove '\(f)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    static func cp(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "rRafvnpi")
        if let e = options.error { context.error(e); return 1 }
        let recursive = options.has("r") || options.has("R") || options.has("a")
        var operandList = options.operands
        guard operandList.count >= 2 else { context.error(operandList.isEmpty ? "missing file operand" : "missing destination file operand after '\(operandList[0])'"); return 1 }
        let destination = operandList.removeLast()
        let destinationPath = context.resolve(destination)
        let destinationIsDirectory = FileInfo(path: destinationPath, follow: true)?.isDirectory ?? false
        if operandList.count > 1 && !destinationIsDirectory { context.error("target '\(destination)' is not a directory"); return 1 }
        var status: Int32 = 0
        for source in operandList {
            let sourcePath = context.resolve(source)
            guard let info = FileInfo(path: sourcePath, follow: true) else {
                context.error("cannot stat '\(source)': No such file or directory"); status = 1; continue
            }
            if info.isDirectory && !recursive { context.error("-r not specified; omitting directory '\(source)'"); status = 1; continue }
            let target = destinationIsDirectory ? destinationPath + "/" + ShellPath.basename(sourcePath) : destinationPath
            if target == sourcePath { context.error("'\(source)' and '\(destination)' are the same file"); status = 1; continue }
            if info.isDirectory && (target + "/").hasPrefix(sourcePath + "/") {
                context.error("cannot copy a directory, '\(source)', into itself"); status = 1; continue
            }
            do {
                if let existing = FileInfo(path: target) {
                    if options.has("n") { continue }
                    if existing.isDirectory && info.isDirectory {
                        for child in try fileManager.contentsOfDirectory(atPath: sourcePath) {
                            let subcontext = CommandContext(argumentVector: ["cp", "-r", sourcePath + "/" + child, target], stdin: context.stdin, stdout: context.stdout,
                                                     stderr: context.stderr, shell: context.shell, cancellation: context.cancellation,
                                                     environment: context.environment, currentDirectory: context.currentDirectory)
                            if cp(subcontext) != 0 { status = 1 }
                        }
                        continue
                    }
                    if existing.isDirectory { context.error("cannot overwrite directory '\(target)' with non-directory"); status = 1; continue }
                    try fileManager.removeItem(atPath: target)
                }
                try fileManager.copyItem(atPath: sourcePath, toPath: target)
                if options.has("v") { context.print("'\(source)' -> '\(target)'") }
            } catch {
                context.error("cannot copy '\(source)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    static func mv(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "fvni")
        if let e = options.error { context.error(e); return 1 }
        var operandList = options.operands
        guard operandList.count >= 2 else { context.error(operandList.isEmpty ? "missing file operand" : "missing destination file operand after '\(operandList[0])'"); return 1 }
        let destination = operandList.removeLast()
        let destinationPath = context.resolve(destination)
        let destinationIsDirectory = FileInfo(path: destinationPath, follow: true)?.isDirectory ?? false
        if operandList.count > 1 && !destinationIsDirectory { context.error("target '\(destination)' is not a directory"); return 1 }
        var status: Int32 = 0
        for source in operandList {
            let sourcePath = context.resolve(source)
            guard FileInfo(path: sourcePath) != nil else { context.error("cannot stat '\(source)': No such file or directory"); status = 1; continue }
            let target = destinationIsDirectory ? destinationPath + "/" + ShellPath.basename(sourcePath) : destinationPath
            if target == sourcePath { continue }
            if (target + "/").hasPrefix(sourcePath + "/") { context.error("cannot move '\(source)' to a subdirectory of itself"); status = 1; continue }
            do {
                if let existing = FileInfo(path: target) {
                    if options.has("n") { continue }
                    if existing.isDirectory, let c = try? fileManager.contentsOfDirectory(atPath: target), !c.isEmpty {
                        context.error("cannot move '\(source)' to '\(target)': Directory not empty"); status = 1; continue
                    }
                    try fileManager.removeItem(atPath: target)
                }
                try fileManager.moveItem(atPath: sourcePath, toPath: target)
                if options.has("v") { context.print("renamed '\(source)' -> '\(target)'") }
            } catch {
                context.error("cannot move '\(source)' to '\(destination)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    static func touch(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "cam")
        guard !options.operands.isEmpty else { context.error("missing file operand"); return 1 }
        var status: Int32 = 0
        for f in options.operands {
            let path = context.resolve(f)
            if fileManager.fileExists(atPath: path) {
                do { try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path) }
                catch { context.error("setting times of '\(f)': \(errorDescription(error))"); status = 1 }
            } else if !options.has("c") {
                if !fileManager.createFile(atPath: path, contents: nil) {
                    let reason = fileManager.fileExists(atPath: ShellPath.dirname(path)) ? "Permission denied" : "No such file or directory"
                    context.error("cannot touch '\(f)': \(reason)"); status = 1
                }
            }
        }
        return status
    }

    static func ln(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "sfnv")
        if let e = options.error { context.error(e); return 1 }
        var operandList = options.operands
        guard !operandList.isEmpty else { context.error("missing file operand"); return 1 }
        if operandList.count == 1 { operandList.append(ShellPath.basename(operandList[0])) }
        let destination = operandList.removeLast()
        var destinationPath = context.resolve(destination)
        let destinationIsDirectory = !options.has("n") && (FileInfo(path: destinationPath, follow: true)?.isDirectory ?? false)
        var status: Int32 = 0
        for target in operandList {
            let linkPath = destinationIsDirectory ? destinationPath + "/" + ShellPath.basename(target) : destinationPath
            if FileInfo(path: linkPath) != nil {
                if options.has("f") { try? fileManager.removeItem(atPath: linkPath) }
                else { context.error("failed to create link '\(destination)': File exists"); status = 1; continue }
            }
            do {
                if options.has("s") {
                    try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                } else {
                    try fileManager.linkItem(atPath: context.resolve(target), toPath: linkPath)
                }
                if options.has("v") { context.print("'\(linkPath)' -> '\(target)'") }
            } catch {
                context.error("failed to create link '\(destination)' -> '\(target)': \(errorDescription(error))"); status = 1
            }
            destinationPath = context.resolve(destination)
        }
        return status
    }

    static func find(_ context: CommandContext) -> Int32 {
        var arguments = context.arguments
        var roots: [String] = []
        while let a = arguments.first, !a.hasPrefix("-"), a != "!", a != "(" { roots.append(a); arguments.removeFirst() }
        if roots.isEmpty { roots = ["."] }
        var namePatterns: [(String, Bool, Bool)] = []
        var type: Character?
        var maxDepth = Int.max, minDepth = 0
        var pathPatterns: [String] = []
        var negateNext = false
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            func value() -> String? { i += 1; return i < arguments.count ? arguments[i] : nil }
            switch a {
            case "!", "-not": negateNext = true; i += 1; continue
            case "-name", "-iname":
                guard let v = value() else { context.error("missing argument to `\(a)'"); return 1 }
                namePatterns.append((v, a == "-iname", negateNext))
            case "-path", "-wholename":
                guard let v = value() else { context.error("missing argument to `\(a)'"); return 1 }
                pathPatterns.append(v)
            case "-type":
                guard let v = value(), let c = v.first else { context.error("missing argument to `-type'"); return 1 }
                type = c
            case "-maxdepth":
                guard let v = value(), let n = Int(v) else { context.error("invalid argument to -maxdepth"); return 1 }
                maxDepth = n
            case "-mindepth":
                guard let v = value(), let n = Int(v) else { context.error("invalid argument to -mindepth"); return 1 }
                minDepth = n
            case "-print", "-a", "-and": break
            default:
                context.error("unknown predicate `\(a)'"); return 1
            }
            negateNext = false
            i += 1
        }
        var status: Int32 = 0
        func matches(_ display: String, _ name: String, _ info: FileInfo, _ depth: Int) -> Bool {
            if depth < minDepth { return false }
            if let t = type {
                switch t {
                case "f": if !info.isRegular { return false }
                case "d": if !info.isDirectory { return false }
                case "l": if !info.isSymlink { return false }
                default: if info.typeChar != t { return false }
                }
            }
            for (p, ignoringCase, negated) in namePatterns where Glob.match(p, name, ignoreCase: ignoringCase) == negated { return false }
            for p in pathPatterns where !Glob.match(p, display) { return false }
            return true
        }
        func walk(_ display: String, _ path: String, _ depth: Int) {
            if context.shouldStop { return }
            guard let info = FileInfo(path: path) else { return }
            if matches(display, ShellPath.basename(display), info, depth) { context.print(display) }
            guard info.isDirectory, depth < maxDepth else { return }
            guard let children = try? fileManager.contentsOfDirectory(atPath: path) else {
                context.error("'\(display)': Permission denied"); status = 1; return
            }
            for c in children.sorted() {
                walk(display.hasSuffix("/") ? display + c : display + "/" + c, path == "/" ? "/" + c : path + "/" + c, depth + 1)
            }
        }
        for r in roots {
            let p = context.resolve(r)
            guard FileInfo(path: p) != nil else { context.error("'\(r)': No such file or directory"); status = 1; continue }
            walk(r, p, 0)
        }
        return status
    }

    static func diskUsage(_ path: String, _ context: CommandContext, visit: ((String, Int64) -> Void)?, display: String) -> Int64 {
        guard !context.shouldStop, let info = FileInfo(path: path) else { return 0 }
        var total = (info.size + 4095) / 4096 * 4096
        if info.isDirectory, let children = try? fileManager.contentsOfDirectory(atPath: path) {
            for c in children.sorted() {
                total += diskUsage(path + "/" + c, context, visit: visit, display: display.hasSuffix("/") ? display + c : display + "/" + c)
            }
            visit?(display, total)
        }
        return total
    }

    static func du(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "hsacSkm", withValues: "d")
        if let e = options.error { context.error(e); return 1 }
        let roots = options.operands.isEmpty ? ["."] : options.operands
        func formatCharacters(_ bytes: Int64) -> String {
            if options.has("h") { return ShellFormat.humanSize(bytes) }
            if options.has("m") { return String((bytes + 1048575) / 1048576) }
            return String((bytes + 1023) / 1024)
        }
        var grand: Int64 = 0
        var status: Int32 = 0
        let maxDepth = options.value("d").flatMap { Int($0) }
        for r in roots {
            let p = context.resolve(r)
            guard let info = FileInfo(path: p) else { context.error("cannot access '\(r)': No such file or directory"); status = 1; continue }
            let rootDepth = r.split(separator: "/").count
            let total = diskUsage(p, context, visit: options.has("s") ? nil : { display, size in
                if display == r { return }
                if let depthLimit = maxDepth, display.split(separator: "/").count - rootDepth > depthLimit { return }
                context.print(formatCharacters(size) + "\t" + display)
            }, display: r)
            _ = info
            context.print(formatCharacters(total) + "\t" + r)
            grand += total
        }
        if options.has("c") { context.print(formatCharacters(grand) + "\ttotal") }
        return status
    }

    static func df(_ context: CommandContext) -> Int32 {
        let human = context.arguments.contains("-h")
        let paths = context.arguments.filter { !$0.hasPrefix("-") }
        func formatCharacters(_ b: Int64) -> String { human ? ShellFormat.humanSize(b) : String(b / 1024) }
        var rows: [[String]] = [["Filesystem", human ? "Size" : "1K-blocks", "Used", "Available", "Use%", "Mounted on"]]
        for p in paths.isEmpty ? [context.homeDirectory] : paths.map({ context.resolve($0) }) {
            guard let attributes = try? fileManager.attributesOfFileSystem(forPath: p) else { context.error("\(p): No such file or directory"); continue }
            let size = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let used = size - free
            let percentage = size > 0 ? Int((Double(used) / Double(size) * 100).rounded(.up)) : 0
            rows.append([paths.isEmpty ? "app-sandbox" : "-", formatCharacters(size), formatCharacters(used), formatCharacters(free), "\(percentage)%", ShellPath.abbreviate(p, home: context.homeDirectory)])
        }
        let w = (0..<6).map { c in rows.map { $0[c].count }.max() ?? 0 }
        for row in rows {
            context.print((0..<6).map { c in c == 5 ? row[c] : ShellFormat.pad(row[c], w[c], right: c > 0) }.joined(separator: " "))
        }
        return 0
    }

    static func stat(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "L", withValues: "c")
        guard !options.operands.isEmpty else { context.error("missing operand"); return 1 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSSSS Z"
        var status: Int32 = 0
        for a in options.operands {
            let path = context.resolve(a)
            guard let i = FileInfo(path: path, follow: options.has("L")) else {
                context.error("cannot stat '\(a)': No such file or directory"); status = 1; continue
            }
            let type: String
            switch i.typeChar {
            case "d": type = "directory"
            case "l": type = "symbolic link"
            case "p": type = "fifo"
            case "s": type = "socket"
            case "c": type = "character special file"
            case "b": type = "block special file"
            default: type = i.size == 0 ? "regular empty file" : "regular file"
            }
            if let format = options.value("c") {
                var out = ""
                var it = format.makeIterator()
                while let c = it.next() {
                    guard c == "%", let n = it.next() else { out.append(c); continue }
                    switch n {
                    case "n": out += a
                    case "s": out += String(i.size)
                    case "a": out += String(i.permissions, radix: 8)
                    case "A": out += i.permissionString
                    case "F": out += type
                    case "U": out += i.userName
                    case "G": out += i.groupName
                    case "u": out += String(i.userIdentifier)
                    case "g": out += String(i.groupIdentifier)
                    case "h": out += String(i.linkCount)
                    case "Y": out += String(Int(i.modificationDate.timeIntervalSince1970))
                    case "y": out += f.string(from: i.modificationDate)
                    case "%": out += "%"
                    default: out.append("%"); out.append(n)
                    }
                }
                context.print(out)
                continue
            }
            var name = "'\(a)'"
            if i.isSymlink, let t = try? fileManager.destinationOfSymbolicLink(atPath: path) { name += " -> '\(t)'" }
            context.print("  File: \(name)")
            context.print("  Size: \(ShellFormat.pad(String(i.size), 15))Type: \(type)")
            context.print(" Links: \(i.linkCount)")
            context.print("Access: (\(String(format: "%04o", i.permissions))/\(i.permissionString))  Uid: (\(i.userIdentifier)/\(i.userName))   Gid: (\(i.groupIdentifier)/\(i.groupName))")
            context.print("Modify: \(f.string(from: i.modificationDate))")
        }
        return status
    }

    static func parseMode(_ specification: String, current: UInt32, isDirectory: Bool) -> UInt32? {
        if let v = UInt32(specification, radix: 8), specification.allSatisfy({ ("0"..."7").contains($0) }) { return v }
        var mode = current
        for clause in specification.split(separator: ",") {
            var who = ""
            var rest = Substring(clause)
            while let c = rest.first, "ugoa".contains(c) { who.append(c); rest.removeFirst() }
            if who.isEmpty || who.contains("a") { who = "ugo" }
            while let operation = rest.first, "+-=".contains(operation) {
                rest.removeFirst()
                var permissions = ""
                while let c = rest.first, "rwxXst".contains(c) { permissions.append(c); rest.removeFirst() }
                var bits: UInt32 = 0
                for w in who {
                    let shift: UInt32 = w == "u" ? 6 : (w == "g" ? 3 : 0)
                    for p in permissions {
                        switch p {
                        case "r": bits |= 4 << shift
                        case "w": bits |= 2 << shift
                        case "x": bits |= 1 << shift
                        case "X": if isDirectory || (current & 0o111) != 0 { bits |= 1 << shift }
                        case "s": if w == "u" { bits |= 0o4000 } else if w == "g" { bits |= 0o2000 }
                        case "t": bits |= 0o1000
                        default: break
                        }
                    }
                }
                switch operation {
                case "+": mode |= bits
                case "-": mode &= ~bits
                default:
                    var mask: UInt32 = 0
                    for w in who { mask |= 7 << (w == "u" ? 6 : (w == "g" ? 3 : 0)) }
                    mode = (mode & ~mask) | bits
                }
            }
            if !rest.isEmpty { return nil }
        }
        return mode
    }

    static func chmod(_ context: CommandContext) -> Int32 {
        var arguments = context.arguments
        let recursive = arguments.first == "-R"
        if recursive { arguments.removeFirst() }
        guard arguments.count >= 2 else { context.error("missing operand"); return 1 }
        let specification = arguments.removeFirst()
        var status: Int32 = 0
        func apply(_ path: String, _ label: String) {
            guard let info = FileInfo(path: path, follow: true) else { context.error("cannot access '\(label)': No such file or directory"); status = 1; return }
            guard let mode = parseMode(specification, current: info.permissions, isDirectory: info.isDirectory) else {
                context.error("invalid mode: '\(specification)'"); status = 1; return
            }
            do { try fileManager.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: path) }
            catch { context.error("changing permissions of '\(label)': \(errorDescription(error))"); status = 1 }
            if recursive && info.isDirectory, let children = try? fileManager.contentsOfDirectory(atPath: path) {
                for c in children { apply(path + "/" + c, label + "/" + c) }
            }
        }
        for a in arguments { apply(context.resolve(a), a) }
        return status
    }

    static func tree(_ context: CommandContext) -> Int32 {
        let options = ParsedOptions(context.arguments, flags: "adf", withValues: "L")
        if let e = options.error { context.error(e); return 1 }
        let maxDepth = options.value("L").flatMap { Int($0) } ?? Int.max
        let color = context.stdout.isTerminal
        var directories = 0, files = 0
        func walk(_ path: String, _ prefix: String, _ depth: Int) {
            guard depth < maxDepth, !context.shouldStop, var names = try? fileManager.contentsOfDirectory(atPath: path) else { return }
            if !options.has("a") { names = names.filter { !$0.hasPrefix(".") } }
            names.sort { $0.lowercased() < $1.lowercased() }
            var entries = names.map { ($0, path + "/" + $0, FileInfo(path: path + "/" + $0)) }
            if options.has("d") { entries = entries.filter { $0.2?.isDirectory == true } }
            for (index, (name, p, info)) in entries.enumerated() {
                let last = index == entries.count - 1
                var shown = color ? colorize(name, info, path: p) : name
                if info?.isSymlink == true, let t = try? fileManager.destinationOfSymbolicLink(atPath: p) { shown += " -> " + t }
                context.print(prefix + (last ? "└── " : "├── ") + shown)
                if info?.isDirectory == true {
                    directories += 1
                    walk(p, prefix + (last ? "    " : "│   "), depth + 1)
                } else {
                    files += 1
                }
            }
        }
        let roots = options.operands.isEmpty ? ["."] : options.operands
        for r in roots {
            let p = context.resolve(r)
            guard FileInfo(path: p, follow: true)?.isDirectory == true else { context.print("\(r) [error opening dir]"); continue }
            context.print(color ? ANSI.boldBlue + r + ANSI.reset : r)
            walk(p, "", 0)
        }
        context.print()
        context.print("\(directories) director\(directories == 1 ? "y" : "ies")" + (options.has("d") ? "" : ", \(files) file\(files == 1 ? "" : "s")"))
        return 0
    }
}

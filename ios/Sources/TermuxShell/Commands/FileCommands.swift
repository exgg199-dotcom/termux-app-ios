import Foundation

/// File system commands operating on real files via FileManager.
enum FileCommands {
    static let fm = FileManager.default

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
        r.register("realpath", "print the resolved absolute path") { ctx in
            var status: Int32 = 0
            for a in ctx.args where !a.hasPrefix("-") {
                let p = ctx.resolve(a)
                if !fm.fileExists(atPath: p) && !ctx.args.contains("-m") { ctx.error("\(a): No such file or directory"); status = 1; continue }
                ctx.print(URL(fileURLWithPath: p).resolvingSymlinksInPath().path)
            }
            return status
        }
        r.register("basename", "strip directory and suffix from a file name") { ctx in
            guard let name = ctx.args.first else { ctx.error("missing operand"); return 1 }
            var b = ShellPath.basename(name)
            if ctx.args.count > 1, b.hasSuffix(ctx.args[1]), b != ctx.args[1] { b = String(b.dropLast(ctx.args[1].count)) }
            ctx.print(b)
            return 0
        }
        r.register("dirname", "strip the last component from a file name") { ctx in
            guard !ctx.args.isEmpty else { ctx.error("missing operand"); return 1 }
            for a in ctx.args { ctx.print(ShellPath.dirname(a)) }
            return 0
        }
    }

    static func errorDescription(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "No such file or directory"
        case NSFileWriteFileExistsError: return "File exists"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "Permission denied"
        case NSFileWriteOutOfSpaceError: return "No space left on device"
        default: return ns.localizedDescription
        }
    }

    // MARK: ls

    struct Entry {
        let name: String
        let path: String
        let info: FileInfo?
    }

    static func colorize(_ name: String, _ info: FileInfo?, path: String) -> String {
        guard let info = info else { return name }
        if info.isSymlink {
            let broken = !fm.fileExists(atPath: path)
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

    static func ls(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "laAh1dtSrRFG", longFlags: [])
        if let e = opts.error { ctx.error(e); return 2 }
        let all = opts.has("a"), almostAll = opts.has("A")
        let long = opts.has("l")
        let human = opts.has("h")
        let color: Bool = {
            switch opts.longValues["color"] ?? (opts.longFlags.contains("color") ? "always" : "auto") {
            case "always", "yes", "force": return true
            case "never", "no", "none": return false
            default: return ctx.stdout.isTerminal
            }
        }()
        let onePerLine = opts.has("1") || !ctx.stdout.isTerminal
        var operands = opts.operands
        if operands.isEmpty { operands = ["."] }
        var status: Int32 = 0

        func sortEntries(_ e: [Entry]) -> [Entry] {
            var s: [Entry]
            if opts.has("t") {
                s = e.sorted { ($0.info?.modificationDate ?? .distantPast) > ($1.info?.modificationDate ?? .distantPast) }
            } else if opts.has("S") {
                s = e.sorted { ($0.info?.size ?? 0) > ($1.info?.size ?? 0) }
            } else {
                func key(_ n: String) -> String { String(n.drop(while: { $0 == "." })).lowercased() }
                s = e.sorted { (key($0.name), $0.name) < (key($1.name), $1.name) }
            }
            return opts.has("r") ? s.reversed() : s
        }

        func display(_ e: Entry) -> String {
            var name = color ? colorize(e.name, e.info, path: e.path) : e.name
            if opts.has("F") { name += classify(e.info) }
            return name
        }

        func printEntries(_ entries: [Entry], showTotal: Bool) {
            if entries.isEmpty { return }
            if long {
                if showTotal {
                    let blocks = entries.reduce(Int64(0)) { $0 + (($1.info?.size ?? 0) + 4095) / 4096 * 4 }
                    ctx.print("total \(human ? ShellFormat.humanSize(blocks * 1024) : String(blocks))")
                }
                let sixMonthsAgo = Date(timeIntervalSinceNow: -182 * 86400)
                var rows: [[String]] = []
                for e in entries {
                    guard let i = e.info else { continue }
                    let size = human ? ShellFormat.humanSize(i.size) : String(i.size)
                    let date = i.modificationDate > sixMonthsAgo && i.modificationDate < Date(timeIntervalSinceNow: 3600)
                        ? recentFormatter.string(from: i.modificationDate) : oldFormatter.string(from: i.modificationDate)
                    var name = display(e)
                    if i.isSymlink, let target = try? fm.destinationOfSymbolicLink(atPath: e.path) { name += " -> " + target }
                    rows.append([i.permissionString, String(i.linkCount), i.userName, i.groupName, size, date, name])
                }
                let w = (0..<6).map { c in rows.map { $0[c].count }.max() ?? 0 }
                for row in rows {
                    let line = [row[0], ShellFormat.pad(row[1], w[1], right: true), ShellFormat.pad(row[2], w[2]),
                                ShellFormat.pad(row[3], w[3]), ShellFormat.pad(row[4], w[4], right: true), row[5], row[6]]
                    ctx.print(line.joined(separator: " "))
                }
            } else if onePerLine {
                for e in entries { ctx.print(display(e)) }
            } else {
                let plain = entries.map { $0.name + (opts.has("F") ? classify($0.info) : "") }
                ctx.stdout.write(ShellFormat.columns(plain, display: entries.map(display), width: ctx.terminalColumns))
            }
        }

        var files: [Entry] = []
        var dirs: [(String, String)] = []
        for op in operands {
            let path = ctx.resolve(op)
            guard let info = FileInfo(path: path) else {
                ctx.error("cannot access '\(op)': No such file or directory"); status = 2; continue
            }
            let followed = info.isSymlink ? FileInfo(path: path, follow: true) : info
            if (followed?.isDirectory ?? false) && !opts.has("d") && !(info.isSymlink && long) {
                dirs.append((op, path))
            } else {
                files.append(Entry(name: op, path: path, info: info))
            }
        }
        printEntries(sortEntries(files), showTotal: false)
        let showHeaders = operands.count > 1 || opts.has("R")
        var first = files.isEmpty
        var queue = dirs
        while !queue.isEmpty {
            if ctx.shouldStop { break }
            let (label, path) = queue.removeFirst()
            if !first { ctx.print() }
            first = false
            if showHeaders { ctx.print("\(label):") }
            guard var names = try? fm.contentsOfDirectory(atPath: path) else {
                ctx.error("cannot open directory '\(label)': Permission denied"); status = 2; continue
            }
            if !all && !almostAll { names = names.filter { !$0.hasPrefix(".") } }
            if all { names += [".", ".."] }
            let entries = sortEntries(names.map { n in
                let p = path == "/" ? "/" + n : path + "/" + n
                return Entry(name: n, path: p, info: FileInfo(path: p))
            })
            printEntries(entries, showTotal: true)
            if opts.has("R") {
                let sub = entries.filter { $0.info?.isDirectory == true && $0.name != "." && $0.name != ".." }
                    .map { (label == "." ? "./" + $0.name : (label.hasSuffix("/") ? label + $0.name : label + "/" + $0.name), $0.path) }
                queue.insert(contentsOf: sub, at: 0)
            }
        }
        return status
    }

    // MARK: cat

    static func cat(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "nbuvAeEtT")
        if let e = opts.error { ctx.error(e); return 1 }
        let number = opts.has("n") || opts.has("b")
        var lineNo = 0
        return ctx.forEachInput(opts.operands) { input, _ in
            if number {
                let reader = LineReader(input)
                while let line = reader.nextLineBytes() {
                    if ctx.shouldStop { break }
                    if opts.has("b") && line.isEmpty { ctx.stdout.write("\n"); continue }
                    lineNo += 1
                    ctx.stdout.write(ShellFormat.pad(String(lineNo), 6, right: true) + "\t")
                    ctx.stdout.write(line + [0x0A])
                }
            } else {
                while !ctx.shouldStop, let chunk = input.read(maxLength: 65536) { ctx.stdout.write(chunk) }
            }
        }
    }

    // MARK: mkdir / rmdir

    static func mkdir(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "pv", withValues: "m")
        if let e = opts.error { ctx.error(e); return 1 }
        guard !opts.operands.isEmpty else { ctx.error("missing operand"); return 1 }
        var status: Int32 = 0
        for d in opts.operands {
            let path = ctx.resolve(d)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if opts.has("p") && isDir.boolValue { continue }
                ctx.error("cannot create directory '\(d)': File exists"); status = 1; continue
            }
            if !opts.has("p") && !fm.fileExists(atPath: ShellPath.dirname(path)) {
                ctx.error("cannot create directory '\(d)': No such file or directory"); status = 1; continue
            }
            do {
                var attrs: [FileAttributeKey: Any]? = nil
                if let m = opts.value("m"), let mode = Int(m, radix: 8) { attrs = [.posixPermissions: mode] }
                try fm.createDirectory(atPath: path, withIntermediateDirectories: opts.has("p"), attributes: attrs)
                if opts.has("v") { ctx.print("mkdir: created directory '\(d)'") }
            } catch {
                ctx.error("cannot create directory '\(d)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    static func rmdir(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "pv")
        guard !opts.operands.isEmpty else { ctx.error("missing operand"); return 1 }
        var status: Int32 = 0
        for d in opts.operands {
            let path = ctx.resolve(d)
            guard let info = FileInfo(path: path) else { ctx.error("failed to remove '\(d)': No such file or directory"); status = 1; continue }
            guard info.isDirectory else { ctx.error("failed to remove '\(d)': Not a directory"); status = 1; continue }
            if let c = try? fm.contentsOfDirectory(atPath: path), !c.isEmpty {
                ctx.error("failed to remove '\(d)': Directory not empty"); status = 1; continue
            }
            do { try fm.removeItem(atPath: path) } catch { ctx.error("failed to remove '\(d)': \(errorDescription(error))"); status = 1 }
        }
        return status
    }

    // MARK: rm

    static func rm(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "rRfvid")
        if let e = opts.error { ctx.error(e); return 1 }
        let force = opts.has("f"), recursive = opts.has("r") || opts.has("R")
        if opts.operands.isEmpty { if force { return 0 }; ctx.error("missing operand"); return 1 }
        var status: Int32 = 0
        for f in opts.operands {
            let path = ctx.resolve(f)
            if path == "/" || path == ctx.homeDirectory && f != "." && recursive && !force {
                ctx.error("refusing to remove '\(f)'"); status = 1; continue
            }
            if ShellPath.basename(f) == "." || ShellPath.basename(f) == ".." {
                ctx.error("refusing to remove '.' or '..' directory: skipping '\(f)'"); status = 1; continue
            }
            guard let info = FileInfo(path: path) else {
                if !force { ctx.error("cannot remove '\(f)': No such file or directory"); status = 1 }
                continue
            }
            if info.isDirectory && !recursive {
                if opts.has("d"), (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true {
                    try? fm.removeItem(atPath: path); continue
                }
                ctx.error("cannot remove '\(f)': Is a directory"); status = 1; continue
            }
            do {
                try fm.removeItem(atPath: path)
                if opts.has("v") { ctx.print("removed '\(f)'") }
            } catch {
                ctx.error("cannot remove '\(f)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    // MARK: cp / mv

    static func cp(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "rRafvnpi")
        if let e = opts.error { ctx.error(e); return 1 }
        let recursive = opts.has("r") || opts.has("R") || opts.has("a")
        var ops = opts.operands
        guard ops.count >= 2 else { ctx.error(ops.isEmpty ? "missing file operand" : "missing destination file operand after '\(ops[0])'"); return 1 }
        let dest = ops.removeLast()
        let destPath = ctx.resolve(dest)
        let destIsDir = FileInfo(path: destPath, follow: true)?.isDirectory ?? false
        if ops.count > 1 && !destIsDir { ctx.error("target '\(dest)' is not a directory"); return 1 }
        var status: Int32 = 0
        for src in ops {
            let srcPath = ctx.resolve(src)
            guard let info = FileInfo(path: srcPath, follow: true) else {
                ctx.error("cannot stat '\(src)': No such file or directory"); status = 1; continue
            }
            if info.isDirectory && !recursive { ctx.error("-r not specified; omitting directory '\(src)'"); status = 1; continue }
            let target = destIsDir ? destPath + "/" + ShellPath.basename(srcPath) : destPath
            if target == srcPath { ctx.error("'\(src)' and '\(dest)' are the same file"); status = 1; continue }
            if info.isDirectory && (target + "/").hasPrefix(srcPath + "/") {
                ctx.error("cannot copy a directory, '\(src)', into itself"); status = 1; continue
            }
            do {
                if let existing = FileInfo(path: target) {
                    if opts.has("n") { continue }
                    if existing.isDirectory && info.isDirectory {
                        // Merge: copy children into the existing directory.
                        for child in try fm.contentsOfDirectory(atPath: srcPath) {
                            let sub = CommandContext(argumentVector: ["cp", "-r", srcPath + "/" + child, target], stdin: ctx.stdin, stdout: ctx.stdout,
                                                     stderr: ctx.stderr, shell: ctx.shell, cancellation: ctx.cancellation,
                                                     environment: ctx.environment, currentDirectory: ctx.currentDirectory)
                            if cp(sub) != 0 { status = 1 }
                        }
                        continue
                    }
                    if existing.isDirectory { ctx.error("cannot overwrite directory '\(target)' with non-directory"); status = 1; continue }
                    try fm.removeItem(atPath: target)
                }
                try fm.copyItem(atPath: srcPath, toPath: target)
                if opts.has("v") { ctx.print("'\(src)' -> '\(target)'") }
            } catch {
                ctx.error("cannot copy '\(src)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    static func mv(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "fvni")
        if let e = opts.error { ctx.error(e); return 1 }
        var ops = opts.operands
        guard ops.count >= 2 else { ctx.error(ops.isEmpty ? "missing file operand" : "missing destination file operand after '\(ops[0])'"); return 1 }
        let dest = ops.removeLast()
        let destPath = ctx.resolve(dest)
        let destIsDir = FileInfo(path: destPath, follow: true)?.isDirectory ?? false
        if ops.count > 1 && !destIsDir { ctx.error("target '\(dest)' is not a directory"); return 1 }
        var status: Int32 = 0
        for src in ops {
            let srcPath = ctx.resolve(src)
            guard FileInfo(path: srcPath) != nil else { ctx.error("cannot stat '\(src)': No such file or directory"); status = 1; continue }
            let target = destIsDir ? destPath + "/" + ShellPath.basename(srcPath) : destPath
            if target == srcPath { continue }
            if (target + "/").hasPrefix(srcPath + "/") { ctx.error("cannot move '\(src)' to a subdirectory of itself"); status = 1; continue }
            do {
                if let existing = FileInfo(path: target) {
                    if opts.has("n") { continue }
                    if existing.isDirectory, let c = try? fm.contentsOfDirectory(atPath: target), !c.isEmpty {
                        ctx.error("cannot move '\(src)' to '\(target)': Directory not empty"); status = 1; continue
                    }
                    try fm.removeItem(atPath: target)
                }
                try fm.moveItem(atPath: srcPath, toPath: target)
                if opts.has("v") { ctx.print("renamed '\(src)' -> '\(target)'") }
            } catch {
                ctx.error("cannot move '\(src)' to '\(dest)': \(errorDescription(error))"); status = 1
            }
        }
        return status
    }

    // MARK: touch / ln

    static func touch(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "cam")
        guard !opts.operands.isEmpty else { ctx.error("missing file operand"); return 1 }
        var status: Int32 = 0
        for f in opts.operands {
            let path = ctx.resolve(f)
            if fm.fileExists(atPath: path) {
                do { try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path) }
                catch { ctx.error("setting times of '\(f)': \(errorDescription(error))"); status = 1 }
            } else if !opts.has("c") {
                if !fm.createFile(atPath: path, contents: nil) {
                    let reason = fm.fileExists(atPath: ShellPath.dirname(path)) ? "Permission denied" : "No such file or directory"
                    ctx.error("cannot touch '\(f)': \(reason)"); status = 1
                }
            }
        }
        return status
    }

    static func ln(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "sfnv")
        if let e = opts.error { ctx.error(e); return 1 }
        var ops = opts.operands
        guard !ops.isEmpty else { ctx.error("missing file operand"); return 1 }
        if ops.count == 1 { ops.append(ShellPath.basename(ops[0])) }
        let dest = ops.removeLast()
        var destPath = ctx.resolve(dest)
        let destIsDir = !opts.has("n") && (FileInfo(path: destPath, follow: true)?.isDirectory ?? false)
        var status: Int32 = 0
        for target in ops {
            let linkPath = destIsDir ? destPath + "/" + ShellPath.basename(target) : destPath
            if FileInfo(path: linkPath) != nil {
                if opts.has("f") { try? fm.removeItem(atPath: linkPath) }
                else { ctx.error("failed to create link '\(dest)': File exists"); status = 1; continue }
            }
            do {
                if opts.has("s") {
                    try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                } else {
                    try fm.linkItem(atPath: ctx.resolve(target), toPath: linkPath)
                }
                if opts.has("v") { ctx.print("'\(linkPath)' -> '\(target)'") }
            } catch {
                ctx.error("failed to create link '\(dest)' -> '\(target)': \(errorDescription(error))"); status = 1
            }
            destPath = ctx.resolve(dest)
        }
        return status
    }

    // MARK: find

    static func find(_ ctx: CommandContext) -> Int32 {
        var args = ctx.args
        var roots: [String] = []
        while let a = args.first, !a.hasPrefix("-"), a != "!", a != "(" { roots.append(a); args.removeFirst() }
        if roots.isEmpty { roots = ["."] }
        var namePatterns: [(String, Bool, Bool)] = [] // (pattern, ignoreCase, negate)
        var type: Character?
        var maxDepth = Int.max, minDepth = 0
        var pathPatterns: [String] = []
        var negateNext = false
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "!", "-not": negateNext = true; i += 1; continue
            case "-name", "-iname":
                guard let v = value() else { ctx.error("missing argument to `\(a)'"); return 1 }
                namePatterns.append((v, a == "-iname", negateNext))
            case "-path", "-wholename":
                guard let v = value() else { ctx.error("missing argument to `\(a)'"); return 1 }
                pathPatterns.append(v)
            case "-type":
                guard let v = value(), let c = v.first else { ctx.error("missing argument to `-type'"); return 1 }
                type = c
            case "-maxdepth":
                guard let v = value(), let n = Int(v) else { ctx.error("invalid argument to -maxdepth"); return 1 }
                maxDepth = n
            case "-mindepth":
                guard let v = value(), let n = Int(v) else { ctx.error("invalid argument to -mindepth"); return 1 }
                minDepth = n
            case "-print", "-a", "-and": break
            default:
                ctx.error("unknown predicate `\(a)'"); return 1
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
            for (p, ic, neg) in namePatterns where Glob.match(p, name, ignoreCase: ic) == neg { return false }
            for p in pathPatterns where !Glob.match(p, display) { return false }
            return true
        }
        func walk(_ display: String, _ path: String, _ depth: Int) {
            if ctx.shouldStop { return }
            guard let info = FileInfo(path: path) else { return }
            if matches(display, ShellPath.basename(display), info, depth) { ctx.print(display) }
            guard info.isDirectory, depth < maxDepth else { return }
            guard let children = try? fm.contentsOfDirectory(atPath: path) else {
                ctx.error("'\(display)': Permission denied"); status = 1; return
            }
            for c in children.sorted() {
                walk(display.hasSuffix("/") ? display + c : display + "/" + c, path == "/" ? "/" + c : path + "/" + c, depth + 1)
            }
        }
        for r in roots {
            let p = ctx.resolve(r)
            guard FileInfo(path: p) != nil else { ctx.error("'\(r)': No such file or directory"); status = 1; continue }
            walk(r, p, 0)
        }
        return status
    }

    // MARK: du / df

    static func diskUsage(_ path: String, _ ctx: CommandContext, visit: ((String, Int64) -> Void)?, display: String) -> Int64 {
        guard !ctx.shouldStop, let info = FileInfo(path: path) else { return 0 }
        var total = (info.size + 4095) / 4096 * 4096
        if info.isDirectory, let children = try? fm.contentsOfDirectory(atPath: path) {
            for c in children.sorted() {
                total += diskUsage(path + "/" + c, ctx, visit: visit, display: display.hasSuffix("/") ? display + c : display + "/" + c)
            }
            visit?(display, total)
        }
        return total
    }

    static func du(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "hsacSkm", withValues: "d")
        if let e = opts.error { ctx.error(e); return 1 }
        let roots = opts.operands.isEmpty ? ["."] : opts.operands
        func fmt(_ bytes: Int64) -> String {
            if opts.has("h") { return ShellFormat.humanSize(bytes) }
            if opts.has("m") { return String((bytes + 1048575) / 1048576) }
            return String((bytes + 1023) / 1024)
        }
        var grand: Int64 = 0
        var status: Int32 = 0
        let maxDepth = opts.value("d").flatMap { Int($0) }
        for r in roots {
            let p = ctx.resolve(r)
            guard let info = FileInfo(path: p) else { ctx.error("cannot access '\(r)': No such file or directory"); status = 1; continue }
            let rootDepth = r.split(separator: "/").count
            let total = diskUsage(p, ctx, visit: opts.has("s") ? nil : { display, size in
                if display == r { return }
                if let md = maxDepth, display.split(separator: "/").count - rootDepth > md { return }
                ctx.print(fmt(size) + "\t" + display)
            }, display: r)
            _ = info
            ctx.print(fmt(total) + "\t" + r)
            grand += total
        }
        if opts.has("c") { ctx.print(fmt(grand) + "\ttotal") }
        return status
    }

    static func df(_ ctx: CommandContext) -> Int32 {
        let human = ctx.args.contains("-h")
        let paths = ctx.args.filter { !$0.hasPrefix("-") }
        func fmt(_ b: Int64) -> String { human ? ShellFormat.humanSize(b) : String(b / 1024) }
        var rows: [[String]] = [["Filesystem", human ? "Size" : "1K-blocks", "Used", "Available", "Use%", "Mounted on"]]
        for p in paths.isEmpty ? [ctx.homeDirectory] : paths.map({ ctx.resolve($0) }) {
            guard let attrs = try? fm.attributesOfFileSystem(forPath: p) else { ctx.error("\(p): No such file or directory"); continue }
            let size = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let used = size - free
            let pct = size > 0 ? Int((Double(used) / Double(size) * 100).rounded(.up)) : 0
            rows.append([paths.isEmpty ? "app-sandbox" : "-", fmt(size), fmt(used), fmt(free), "\(pct)%", ShellPath.abbreviate(p, home: ctx.homeDirectory)])
        }
        let w = (0..<6).map { c in rows.map { $0[c].count }.max() ?? 0 }
        for row in rows {
            ctx.print((0..<6).map { c in c == 5 ? row[c] : ShellFormat.pad(row[c], w[c], right: c > 0) }.joined(separator: " "))
        }
        return 0
    }

    // MARK: stat / chmod

    static func stat(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "L", withValues: "c")
        guard !opts.operands.isEmpty else { ctx.error("missing operand"); return 1 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSSSS Z"
        var status: Int32 = 0
        for a in opts.operands {
            let path = ctx.resolve(a)
            guard let i = FileInfo(path: path, follow: opts.has("L")) else {
                ctx.error("cannot stat '\(a)': No such file or directory"); status = 1; continue
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
            if let format = opts.value("c") {
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
                    case "u": out += String(i.uid)
                    case "g": out += String(i.gid)
                    case "h": out += String(i.linkCount)
                    case "Y": out += String(Int(i.modificationDate.timeIntervalSince1970))
                    case "y": out += f.string(from: i.modificationDate)
                    case "%": out += "%"
                    default: out.append("%"); out.append(n)
                    }
                }
                ctx.print(out)
                continue
            }
            var name = "'\(a)'"
            if i.isSymlink, let t = try? fm.destinationOfSymbolicLink(atPath: path) { name += " -> '\(t)'" }
            ctx.print("  File: \(name)")
            ctx.print("  Size: \(ShellFormat.pad(String(i.size), 15))Type: \(type)")
            ctx.print(" Links: \(i.linkCount)")
            ctx.print("Access: (\(String(format: "%04o", i.permissions))/\(i.permissionString))  Uid: (\(i.uid)/\(i.userName))   Gid: (\(i.gid)/\(i.groupName))")
            ctx.print("Modify: \(f.string(from: i.modificationDate))")
        }
        return status
    }

    static func parseMode(_ spec: String, current: UInt32, isDir: Bool) -> UInt32? {
        if let v = UInt32(spec, radix: 8), spec.allSatisfy({ ("0"..."7").contains($0) }) { return v }
        var mode = current
        for clause in spec.split(separator: ",") {
            var who = ""
            var rest = Substring(clause)
            while let c = rest.first, "ugoa".contains(c) { who.append(c); rest.removeFirst() }
            if who.isEmpty || who.contains("a") { who = "ugo" }
            while let op = rest.first, "+-=".contains(op) {
                rest.removeFirst()
                var perms = ""
                while let c = rest.first, "rwxXst".contains(c) { perms.append(c); rest.removeFirst() }
                var bits: UInt32 = 0
                for w in who {
                    let shift: UInt32 = w == "u" ? 6 : (w == "g" ? 3 : 0)
                    for p in perms {
                        switch p {
                        case "r": bits |= 4 << shift
                        case "w": bits |= 2 << shift
                        case "x": bits |= 1 << shift
                        case "X": if isDir || (current & 0o111) != 0 { bits |= 1 << shift }
                        case "s": if w == "u" { bits |= 0o4000 } else if w == "g" { bits |= 0o2000 }
                        case "t": bits |= 0o1000
                        default: break
                        }
                    }
                }
                switch op {
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

    static func chmod(_ ctx: CommandContext) -> Int32 {
        var args = ctx.args
        let recursive = args.first == "-R"
        if recursive { args.removeFirst() }
        guard args.count >= 2 else { ctx.error("missing operand"); return 1 }
        let spec = args.removeFirst()
        var status: Int32 = 0
        func apply(_ path: String, _ label: String) {
            guard let info = FileInfo(path: path, follow: true) else { ctx.error("cannot access '\(label)': No such file or directory"); status = 1; return }
            guard let mode = parseMode(spec, current: info.permissions, isDir: info.isDirectory) else {
                ctx.error("invalid mode: '\(spec)'"); status = 1; return
            }
            do { try fm.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: path) }
            catch { ctx.error("changing permissions of '\(label)': \(errorDescription(error))"); status = 1 }
            if recursive && info.isDirectory, let children = try? fm.contentsOfDirectory(atPath: path) {
                for c in children { apply(path + "/" + c, label + "/" + c) }
            }
        }
        for a in args { apply(ctx.resolve(a), a) }
        return status
    }

    // MARK: tree

    static func tree(_ ctx: CommandContext) -> Int32 {
        let opts = ParsedOptions(ctx.args, flags: "adf", withValues: "L")
        if let e = opts.error { ctx.error(e); return 1 }
        let maxDepth = opts.value("L").flatMap { Int($0) } ?? Int.max
        let color = ctx.stdout.isTerminal
        var dirs = 0, files = 0
        func walk(_ path: String, _ prefix: String, _ depth: Int) {
            guard depth < maxDepth, !ctx.shouldStop, var names = try? fm.contentsOfDirectory(atPath: path) else { return }
            if !opts.has("a") { names = names.filter { !$0.hasPrefix(".") } }
            names.sort { $0.lowercased() < $1.lowercased() }
            var entries = names.map { ($0, path + "/" + $0, FileInfo(path: path + "/" + $0)) }
            if opts.has("d") { entries = entries.filter { $0.2?.isDirectory == true } }
            for (idx, (name, p, info)) in entries.enumerated() {
                let last = idx == entries.count - 1
                var shown = color ? colorize(name, info, path: p) : name
                if info?.isSymlink == true, let t = try? fm.destinationOfSymbolicLink(atPath: p) { shown += " -> " + t }
                ctx.print(prefix + (last ? "└── " : "├── ") + shown)
                if info?.isDirectory == true {
                    dirs += 1
                    walk(p, prefix + (last ? "    " : "│   "), depth + 1)
                } else {
                    files += 1
                }
            }
        }
        let roots = opts.operands.isEmpty ? ["."] : opts.operands
        for r in roots {
            let p = ctx.resolve(r)
            guard FileInfo(path: p, follow: true)?.isDirectory == true else { ctx.print("\(r) [error opening dir]"); continue }
            ctx.print(color ? ANSI.boldBlue + r + ANSI.reset : r)
            walk(p, "", 0)
        }
        ctx.print()
        ctx.print("\(dirs) director\(dirs == 1 ? "y" : "ies")" + (opts.has("d") ? "" : ", \(files) file\(files == 1 ? "" : "s")"))
        return 0
    }
}

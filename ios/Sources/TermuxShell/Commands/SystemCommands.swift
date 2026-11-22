import Foundation

/// System information commands (date, uname, id, uptime, ...).
enum SystemCommands {
    static func register(_ r: CommandRegistry) {
        r.register("date", "print the date (+FORMAT, -u UTC, -d @EPOCH)") { date($0) }
        r.register("whoami", "print the user name") { ctx in ctx.print(SystemInfo.userName); return 0 }
        r.register("hostname", "print the host name") { ctx in ctx.print(SystemInfo.hostName); return 0 }
        r.register("uname", "print system information (-a -s -n -r -v -m -o)") { uname($0) }
        r.register("id", "print user and group ids") { ctx in
            let uid = getuid(), gid = getgid()
            let u = FileInfo.userName(UInt32(uid)), g = FileInfo.groupName(UInt32(gid))
            if ctx.args.contains("-u") { ctx.print(ctx.args.contains("-n") ? u : String(uid)); return 0 }
            if ctx.args.contains("-g") { ctx.print(ctx.args.contains("-n") ? g : String(gid)); return 0 }
            ctx.print("uid=\(uid)(\(u)) gid=\(gid)(\(g)) groups=\(gid)(\(g))")
            return 0
        }
        r.register("uptime", "show how long the system has been running") { uptime($0) }
        r.register("nproc", "print the number of processors") { ctx in ctx.print(String(ProcessInfo.processInfo.activeProcessorCount)); return 0 }
        r.register("free", "display memory information (-h)") { ctx in
            let total = Int64(ProcessInfo.processInfo.physicalMemory)
            let human = ctx.args.contains("-h")
            func f(_ v: Int64) -> String { human ? ShellFormat.humanSize(v) : String(v / 1024) }
            ctx.print(ShellFormat.pad("", 7) + ShellFormat.pad("total", 12, right: true))
            ctx.print(ShellFormat.pad("Mem:", 7) + ShellFormat.pad(f(total), 12, right: true))
            return 0
        }
        r.register("cal", "display a calendar") { cal($0) }
        r.register("tty", "print the terminal name") { ctx in
            if ctx.stdin.isTerminal { ctx.print("/dev/pts/0"); return 0 }
            ctx.print("not a tty"); return 1
        }
        r.register("termux-info", "print information about this Termux installation") { ctx in
            let u = SystemInfo.uname
            ctx.print("Termux for iOS (built-in shell)")
            ctx.print("HOME=\(ctx.homeDirectory)")
            ctx.print("Kernel: \(u.sysname) \(u.release) \(u.machine)")
            ctx.print("OS: \(u.operatingSystem) \(ProcessInfo.processInfo.operatingSystemVersionString)")
            ctx.print("Commands: \(ctx.shell.registry.names.count) built-in")
            return 0
        }
    }

    static func date(_ ctx: CommandContext) -> Int32 {
        var utc = false
        var format: String? = nil
        var when = Date()
        var args = ctx.args
        while !args.isEmpty {
            let a = args.removeFirst()
            if a == "-u" || a == "--utc" { utc = true }
            else if a == "-d" || a == "--date", let v = args.first {
                args.removeFirst()
                if v.hasPrefix("@"), let t = Double(v.dropFirst()) { when = Date(timeIntervalSince1970: t) }
                else if let d = ISO8601DateFormatter().date(from: v) { when = d }
                else { ctx.error("invalid date '\(v)'"); return 1 }
            }
            else if a == "-R" { format = "%a, %d %b %Y %H:%M:%S %z" }
            else if a == "-I" { format = "%Y-%m-%d" }
            else if a.hasPrefix("+") { format = String(a.dropFirst()) }
            else { ctx.error("invalid argument '\(a)'"); return 1 }
        }
        ctx.print(strftime(format ?? "%a %b %e %H:%M:%S %Z %Y", when, utc: utc))
        return 0
    }

    static func strftime(_ format: String, _ date: Date, utc: Bool) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tmValue = tm()
        if utc { gmtime_r(&t, &tmValue) } else { localtime_r(&t, &tmValue) }
        var buffer = [CChar](repeating: 0, count: 1024)
        // Support %N (nanoseconds) which libc strftime lacks.
        let nanos = String(format: "%09d", Int((date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)) * 1e9))
        let fmt = format.replacingOccurrences(of: "%N", with: nanos)
        let n = Foundation.strftime(&buffer, buffer.count, fmt, &tmValue)
        return n > 0 ? String(cString: buffer) : ""
    }

    static func uname(_ ctx: CommandContext) -> Int32 {
        let u = SystemInfo.uname
        let opts = ParsedOptions(ctx.args, flags: "asnrvmpio")
        if let e = opts.error { ctx.error(e); return 1 }
        var parts: [String] = []
        let all = opts.has("a")
        if all || opts.has("s") || opts.flags.isEmpty { parts.append(u.sysname) }
        if all || opts.has("n") { parts.append(u.nodename) }
        if all || opts.has("r") { parts.append(u.release) }
        if all || opts.has("v") { parts.append(u.version) }
        if all || opts.has("m") { parts.append(u.machine) }
        if opts.has("p") { parts.append(u.machine) }
        if opts.has("i") { parts.append(u.machine) }
        if all || opts.has("o") { parts.append(u.operatingSystem) }
        ctx.print(parts.joined(separator: " "))
        return 0
    }

    static func uptime(_ ctx: CommandContext) -> Int32 {
        let up = Int(ProcessInfo.processInfo.systemUptime)
        let days = up / 86400, hours = (up % 86400) / 3600, mins = (up % 3600) / 60
        if ctx.args.contains("-p") {
            var parts: [String] = []
            if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
            if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
            parts.append("\(mins) minute\(mins == 1 ? "" : "s")")
            ctx.print("up " + parts.joined(separator: ", "))
            return 0
        }
        let now = strftime("%H:%M:%S", Date(), utc: false)
        var upText = days > 0 ? "\(days) day\(days == 1 ? "" : "s"), " : ""
        upText += String(format: "%2d:%02d", hours, mins)
        var load = [Double](repeating: 0, count: 3)
        let loadText: String
        if getloadavg(&load, 3) == 3 {
            loadText = String(format: ",  load average: %.2f, %.2f, %.2f", load[0], load[1], load[2])
        } else { loadText = "" }
        ctx.print(" \(now) up \(upText),  1 user\(loadText)")
        return 0
    }

    static func cal(_ ctx: CommandContext) -> Int32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let cal = calendar
        let now = Date()
        var comps = cal.dateComponents([.year, .month], from: now)
        if ctx.args.count == 2, let m = Int(ctx.args[0]), let y = Int(ctx.args[1]) { comps.month = m; comps.year = y }
        else if ctx.args.count == 1, let y = Int(ctx.args[0]), y > 12 {
            for m in 1...12 {
                let sub = CommandContext(argumentVector: ["cal", String(m), String(y)], stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr,
                                         shell: ctx.shell, cancellation: ctx.cancellation, environment: ctx.environment,
                                         currentDirectory: ctx.currentDirectory)
                _ = SystemCommands.cal(sub); ctx.print()
            }
            return 0
        }
        comps.day = 1
        guard let first = cal.date(from: comps), let range = cal.range(of: .day, in: .month, for: first) else { ctx.error("invalid date"); return 1 }
        let weekday = cal.component(.weekday, from: first) - 1
        let title = "\(cal.monthSymbols[comps.month! - 1]) \(comps.year!)"
        let pad = (20 - title.count) / 2
        ctx.print(String(repeating: " ", count: max(0, pad)) + title)
        ctx.print("Su Mo Tu We Th Fr Sa")
        var line = String(repeating: "   ", count: weekday)
        let today = cal.dateComponents([.year, .month, .day], from: now)
        var col = weekday
        for d in range {
            var cell = ShellFormat.pad(String(d), 2, right: true)
            if ctx.stdout.isTerminal && today.year == comps.year && today.month == comps.month && today.day == d {
                cell = "\u{1B}[7m" + cell + ANSI.reset
            }
            line += cell
            col += 1
            if col == 7 { ctx.print(line); line = ""; col = 0 } else { line += " " }
        }
        if !line.isEmpty { ctx.print(line.trimmingCharacters(in: .whitespaces) == "" ? "" : String(line.dropLast())) }
        return 0
    }
}

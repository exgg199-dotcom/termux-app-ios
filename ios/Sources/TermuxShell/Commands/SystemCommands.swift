import Foundation

enum SystemCommands {
    static func register(_ r: CommandRegistry) {
        r.register("date", "print the date (+FORMAT, -u UTC, -d @EPOCH)") { date($0) }
        r.register("whoami", "print the user name") { context in context.print(SystemInfo.userName); return 0 }
        r.register("hostname", "print the host name") { context in context.print(SystemInfo.hostName); return 0 }
        r.register("uname", "print system information (-a -s -n -r -v -m -o)") { uname($0) }
        r.register("id", "print user and group ids") { context in
            let userIdentifier = getuid(), groupIdentifier = getgid()
            let u = FileInfo.userName(UInt32(userIdentifier)), g = FileInfo.groupName(UInt32(groupIdentifier))
            if context.arguments.contains("-u") { context.print(context.arguments.contains("-n") ? u : String(userIdentifier)); return 0 }
            if context.arguments.contains("-g") { context.print(context.arguments.contains("-n") ? g : String(groupIdentifier)); return 0 }
            context.print("uid=\(userIdentifier)(\(u)) gid=\(groupIdentifier)(\(g)) groups=\(groupIdentifier)(\(g))")
            return 0
        }
        r.register("uptime", "show how long the system has been running") { uptime($0) }
        r.register("nproc", "print the number of processors") { context in context.print(String(ProcessInfo.processInfo.activeProcessorCount)); return 0 }
        r.register("free", "display memory information (-h)") { context in
            let total = Int64(ProcessInfo.processInfo.physicalMemory)
            let human = context.arguments.contains("-h")
            func f(_ v: Int64) -> String { human ? ShellFormat.humanSize(v) : String(v / 1024) }
            context.print(ShellFormat.pad("", 7) + ShellFormat.pad("total", 12, right: true))
            context.print(ShellFormat.pad("Mem:", 7) + ShellFormat.pad(f(total), 12, right: true))
            return 0
        }
        r.register("cal", "display a calendar") { cal($0) }
        r.register("tty", "print the terminal name") { context in
            if context.stdin.isTerminal { context.print("/dev/pts/0"); return 0 }
            context.print("not a tty"); return 1
        }
        r.register("termux-info", "print information about this Termux installation") { context in
            let u = SystemInfo.uname
            context.print("Termux for iOS (built-in shell)")
            context.print("HOME=\(context.homeDirectory)")
            context.print("Kernel: \(u.sysname) \(u.release) \(u.machine)")
            context.print("OS: \(u.operatingSystem) \(ProcessInfo.processInfo.operatingSystemVersionString)")
            context.print("Commands: \(context.shell.registry.names.count) built-in")
            return 0
        }
    }

    static func date(_ context: CommandContext) -> Int32 {
        var utc = false
        var format: String? = nil
        var when = Date()
        var arguments = context.arguments
        while !arguments.isEmpty {
            let a = arguments.removeFirst()
            if a == "-u" || a == "--utc" { utc = true }
            else if a == "-d" || a == "--date", let v = arguments.first {
                arguments.removeFirst()
                if v.hasPrefix("@"), let t = Double(v.dropFirst()) { when = Date(timeIntervalSince1970: t) }
                else if let d = ISO8601DateFormatter().date(from: v) { when = d }
                else { context.error("invalid date '\(v)'"); return 1 }
            }
            else if a == "-R" { format = "%a, %d %b %Y %H:%M:%S %z" }
            else if a == "-I" { format = "%Y-%m-%d" }
            else if a.hasPrefix("+") { format = String(a.dropFirst()) }
            else { context.error("invalid argument '\(a)'"); return 1 }
        }
        context.print(strftime(format ?? "%a %b %e %H:%M:%S %Z %Y", when, utc: utc))
        return 0
    }

    static func strftime(_ format: String, _ date: Date, utc: Bool) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var timeValue = tm()
        if utc { gmtime_r(&t, &timeValue) } else { localtime_r(&t, &timeValue) }
        var buffer = [CChar](repeating: 0, count: 1024)
        let nanoseconds = String(format: "%09d", Int((date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)) * 1e9))
        let formatCharacters = format.replacingOccurrences(of: "%N", with: nanoseconds)
        let n = Foundation.strftime(&buffer, buffer.count, formatCharacters, &timeValue)
        return n > 0 ? String(cString: buffer) : ""
    }

    static func uname(_ context: CommandContext) -> Int32 {
        let u = SystemInfo.uname
        let options = ParsedOptions(context.arguments, flags: "asnrvmpio")
        if let e = options.error { context.error(e); return 1 }
        var parts: [String] = []
        let all = options.has("a")
        if all || options.has("s") || options.flags.isEmpty { parts.append(u.sysname) }
        if all || options.has("n") { parts.append(u.nodename) }
        if all || options.has("r") { parts.append(u.release) }
        if all || options.has("v") { parts.append(u.version) }
        if all || options.has("m") { parts.append(u.machine) }
        if options.has("p") { parts.append(u.machine) }
        if options.has("i") { parts.append(u.machine) }
        if all || options.has("o") { parts.append(u.operatingSystem) }
        context.print(parts.joined(separator: " "))
        return 0
    }

    static func uptime(_ context: CommandContext) -> Int32 {
        let up = Int(ProcessInfo.processInfo.systemUptime)
        let days = up / 86400, hours = (up % 86400) / 3600, mins = (up % 3600) / 60
        if context.arguments.contains("-p") {
            var parts: [String] = []
            if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
            if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
            parts.append("\(mins) minute\(mins == 1 ? "" : "s")")
            context.print("up " + parts.joined(separator: ", "))
            return 0
        }
        let now = strftime("%H:%M:%S", Date(), utc: false)
        var uptimeText = days > 0 ? "\(days) day\(days == 1 ? "" : "s"), " : ""
        uptimeText += String(format: "%2d:%02d", hours, mins)
        var load = [Double](repeating: 0, count: 3)
        let loadText: String
        if getloadavg(&load, 3) == 3 {
            loadText = String(format: ",  load average: %.2f, %.2f, %.2f", load[0], load[1], load[2])
        } else { loadText = "" }
        context.print(" \(now) up \(uptimeText),  1 user\(loadText)")
        return 0
    }

    static func cal(_ context: CommandContext) -> Int32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let cal = calendar
        let now = Date()
        var components = cal.dateComponents([.year, .month], from: now)
        if context.arguments.count == 2, let m = Int(context.arguments[0]), let y = Int(context.arguments[1]) { components.month = m; components.year = y }
        else if context.arguments.count == 1, let y = Int(context.arguments[0]), y > 12 {
            for m in 1...12 {
                let subcontext = CommandContext(argumentVector: ["cal", String(m), String(y)], stdin: context.stdin, stdout: context.stdout, stderr: context.stderr,
                                         shell: context.shell, cancellation: context.cancellation, environment: context.environment,
                                         currentDirectory: context.currentDirectory)
                _ = SystemCommands.cal(subcontext); context.print()
            }
            return 0
        }
        components.day = 1
        guard let first = cal.date(from: components), let range = cal.range(of: .day, in: .month, for: first) else { context.error("invalid date"); return 1 }
        let weekday = cal.component(.weekday, from: first) - 1
        let title = "\(cal.monthSymbols[components.month! - 1]) \(components.year!)"
        let pad = (20 - title.count) / 2
        context.print(String(repeating: " ", count: max(0, pad)) + title)
        context.print("Su Mo Tu We Th Fr Sa")
        var line = String(repeating: "   ", count: weekday)
        let today = cal.dateComponents([.year, .month, .day], from: now)
        var column = weekday
        for d in range {
            var cell = ShellFormat.pad(String(d), 2, right: true)
            if context.stdout.isTerminal && today.year == components.year && today.month == components.month && today.day == d {
                cell = "\u{1B}[7m" + cell + ANSI.reset
            }
            line += cell
            column += 1
            if column == 7 { context.print(line); line = ""; column = 0 } else { line += " " }
        }
        if !line.isEmpty { context.print(line.trimmingCharacters(in: .whitespaces) == "" ? "" : String(line.dropLast())) }
        return 0
    }
}

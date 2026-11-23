import Foundation

enum PackageCommands {
    static var fetcherFactory: () -> PackageFetcher = { URLSessionPackageFetcher() }

    static let ignoredOptions: Set<String> = ["-y", "--yes", "--assume-yes", "-q", "--quiet", "-qq", "--no-install-recommends",
                                              "--no-install-suggests", "--fix-missing", "-f", "--fix-broken"]

    static func register(_ registry: CommandRegistry) {
        registry.register("pkg", "install and manage WebAssembly packages (pkg help)") { runPackageTool($0) }
        registry.register("apt", "install and manage WebAssembly packages") { runAdvancedPackageTool($0, variant: .standard) }
        registry.register("apt-get", "") { runAdvancedPackageTool($0, variant: .classic) }
        registry.register("apt-cache", "") { runPackageCache($0) }
        registry.register("dpkg", "list installed packages (-l, -L)") { runPackageDatabase($0) }
    }

    static func prefix(for context: CommandContext) -> String {
        if let prefix = context.environment["PREFIX"], !prefix.isEmpty { return ShellPath.normalize(prefix) }
        return ShellPath.normalize(context.homeDirectory + "/../usr")
    }

    static func manager(for context: CommandContext) -> PackageManager {
        PackageManager(layout: PackageLayout(prefix: prefix(for: context)), fetcher: fetcherFactory())
    }

    static let packageToolUsage = """
    Usage: pkg [--check-mirror] command [arguments]

    A tool for managing packages.
      --check-mirror forces a re-check of availability of mirrors (ignored)

    Commands:

      autoclean            - Remove all outdated downloaded .wasm files.
      clean                - Remove all downloaded .wasm files.
      files <packages>     - Show all files installed by packages.
      install <packages>   - Install specified packages.
      list-all             - List all packages available for installation.
      list-installed       - List installed packages.
      reinstall <packages> - Reinstall specified installed packages at the
                             latest version.
      search <query>       - Search package by query, for example by name or
                             description part.
      show <packages>      - Show basic metadata, such as dependencies.
      uninstall <packages> - Uninstall specified packages. Configuration files
                             will be left intact.
      upgrade              - Upgrade all installed packages to the latest
                             version.
      update               - Update apt databases from configured mirrors.

    Packages for Termux for iOS are WebAssembly (wasm32) programs.
    """

    static let advancedPackageToolUsage = """
    apt 2.7.3 (wasm32)
    Usage: apt [options] command

    apt is a commandline package manager for the WebAssembly packages
    of Termux for iOS.

    Most used commands:
      list - list packages based on package names
      search - search in package descriptions
      show - show package details
      install - install packages
      reinstall - reinstall packages
      remove - remove packages
      autoremove - automatically remove all unused packages
      update - update list of available packages
      upgrade - upgrade the system by installing/upgrading packages
      full-upgrade - upgrade the system by removing/installing/upgrading packages
      clean - remove downloaded package files

    Packages for Termux for iOS are WebAssembly (wasm32) programs.
    """

    static func splitOptions(_ arguments: [String], context: CommandContext) -> (options: Set<String>, operands: [String])? {
        var options: Set<String> = []
        var operands: [String] = []
        for argument in arguments {
            if argument.hasPrefix("-") && argument.count > 1 {
                if ignoredOptions.contains(argument) || argument == "--reinstall" || argument == "--installed"
                    || argument == "--upgradable" || argument == "--check-mirror" || argument == "--all-versions" {
                    options.insert(argument)
                } else {
                    context.stderr.writeLine("E: Command line option '\(argument)' is not understood")
                    return nil
                }
            } else {
                operands.append(argument)
            }
        }
        return (options, operands)
    }

    static func requireOperands(_ operands: [String], context: CommandContext) -> Bool {
        if operands.isEmpty {
            context.stderr.writeLine("E: No packages given")
            return false
        }
        return true
    }

    static func runPackageTool(_ context: CommandContext) -> Int32 {
        guard let (_, operands) = splitOptions(context.arguments, context: context) else { return 100 }
        guard let subcommand = operands.first else {
            context.print(packageToolUsage)
            return 1
        }
        let rest = Array(operands.dropFirst())
        let manager = manager(for: context)
        switch subcommand {
        case "update":
            return manager.update(context)
        case "upgrade", "up":
            return manager.upgrade(context)
        case "install", "in", "i", "add":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.install(rest, reinstall: false, context: context)
        case "reinstall", "rei":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.install(rest, reinstall: true, context: context)
        case "uninstall", "un", "rem", "remove", "rm":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.remove(rest, context: context)
        case "list-all", "la":
            return manager.listAvailable(context)
        case "list-installed", "li":
            return manager.listInstalled(context)
        case "search", "se":
            return manager.search(rest, context: context)
        case "show", "sh":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.show(rest, context: context)
        case "files":
            return manager.files(rest, context: context)
        case "clean", "autoclean":
            return manager.clean(context)
        case "help", "-h", "--help":
            context.print(packageToolUsage)
            return 0
        default:
            context.stderr.writeLine("Unknown command: '\(subcommand)' (run 'pkg help' for usage information)")
            context.print(packageToolUsage)
            return 1
        }
    }

    enum AdvancedPackageToolVariant { case standard, classic }

    static func runAdvancedPackageTool(_ context: CommandContext, variant: AdvancedPackageToolVariant) -> Int32 {
        guard let (options, operands) = splitOptions(context.arguments, context: context) else { return 100 }
        guard let subcommand = operands.first else {
            context.print(advancedPackageToolUsage)
            return 1
        }
        let rest = Array(operands.dropFirst())
        let manager = manager(for: context)
        switch subcommand {
        case "update":
            return manager.update(context)
        case "upgrade", "full-upgrade", "dist-upgrade":
            return manager.upgrade(context)
        case "install":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.install(rest, reinstall: options.contains("--reinstall"), context: context)
        case "reinstall":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.install(rest, reinstall: true, context: context)
        case "remove", "purge":
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.remove(rest, context: context)
        case "autoremove", "autopurge":
            return manager.autoremove(context)
        case "clean", "autoclean":
            return manager.clean(context)
        case "list" where variant == .standard:
            if options.contains("--installed") { return manager.listInstalled(context) }
            if options.contains("--upgradable") { return manager.listUpgradable(context) }
            return manager.listAvailable(context)
        case "search" where variant == .standard:
            return manager.search(rest, context: context)
        case "show" where variant == .standard:
            guard requireOperands(rest, context: context) else { return 100 }
            return manager.show(rest, context: context)
        case "help", "-h", "--help":
            context.print(advancedPackageToolUsage)
            return 0
        default:
            context.stderr.writeLine("E: Invalid operation \(subcommand)")
            return 100
        }
    }

    static func runPackageCache(_ context: CommandContext) -> Int32 {
        guard let (_, operands) = splitOptions(context.arguments, context: context) else { return 100 }
        let manager = manager(for: context)
        switch operands.first {
        case "search"?:
            return manager.search(Array(operands.dropFirst()), context: context)
        case "show"?:
            let names = Array(operands.dropFirst())
            guard requireOperands(names, context: context) else { return 100 }
            return manager.show(names, context: context)
        case nil:
            context.print("Usage: apt-cache [options] command\n\nCommands: search, show")
            return 1
        case let subcommand?:
            context.stderr.writeLine("E: Invalid operation \(subcommand)")
            return 100
        }
    }

    static func runPackageDatabase(_ context: CommandContext) -> Int32 {
        let arguments = context.arguments
        let manager = manager(for: context)
        switch arguments.first {
        case "-l"?, "--list"?:
            return manager.listInstalledTable(context)
        case "-L"?, "--listfiles"?:
            let names = Array(arguments.dropFirst())
            guard !names.isEmpty else {
                context.stderr.writeLine("dpkg-query: error: --listfiles needs at least one package name argument")
                return 2
            }
            return manager.files(names, context: context)
        default:
            context.stderr.writeLine("dpkg: error: only -l and -L are supported on Termux for iOS (use pkg to install packages)")
            return 2
        }
    }
}

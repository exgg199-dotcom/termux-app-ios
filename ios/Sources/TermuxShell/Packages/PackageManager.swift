import Foundation

public enum PackageResolutionError: Error, Equatable {
    case notFound(String)
    case missingDependency(package: String, dependency: String)
    case cycle([String])
}

public final class PackageManager {
    public static var bundledIndexURL: URL?

    static let platformHint = "N: Termux for iOS can only install WebAssembly packages. Android Termux packages cannot run on iOS. Run 'pkg list-all' to see what is available."

    public let layout: PackageLayout
    public let fetcher: PackageFetcher
    public let bundledIndexURL: URL?
    let database: PackageDatabase
    private let fileManager = FileManager.default

    public init(layout: PackageLayout, fetcher: PackageFetcher = URLSessionPackageFetcher(), bundledIndexURL: URL? = PackageManager.bundledIndexURL) {
        self.layout = layout
        self.fetcher = fetcher
        self.bundledIndexURL = bundledIndexURL
        self.database = PackageDatabase(layout: layout)
    }

    private struct Failure: Error {
        let status: Int32
    }

    private enum Operation {
        case install
        case upgrade(InstalledPackage)
        case reinstall(InstalledPackage)
    }

    private struct PlannedPackage {
        let record: PackageRecord
        let operation: Operation
    }

    private struct DownloadedFile {
        let file: PackageFile
        let stagedPath: String
    }

    public func sources() -> [URL] {
        guard let data = fileManager.contents(atPath: layout.sourcesFile) else {
            return URL(string: PackageLayout.defaultSource).map { [$0] } ?? []
        }
        var result: [URL] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var text = String(line)
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if let url = URL(string: text), url.scheme != nil { result.append(url) }
        }
        return result
    }

    private func cachedIndexes() -> [PackageIndex] {
        sources().compactMap { source in
            fileManager.contents(atPath: layout.listFile(for: source)).flatMap { try? PackageIndex.decode($0) }
        }
    }

    private func bundledIndex() -> PackageIndex? {
        guard let url = bundledIndexURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? PackageIndex.decode(data)
    }

    private var hasCachedLists: Bool { !cachedIndexes().isEmpty }

    public func availablePackages() -> [PackageRecord] {
        var indexes = cachedIndexes()
        if indexes.isEmpty, let bundled = bundledIndex() { indexes = [bundled] }
        var records: [String: PackageRecord] = [:]
        for index in indexes {
            for record in index.packages {
                if let existing = records[record.name], PackageVersion.compare(existing.version, record.version) != .orderedAscending { continue }
                records[record.name] = record
            }
        }
        return records.values.sorted { $0.name < $1.name }
    }

    private func availableByName() -> [String: PackageRecord] {
        Dictionary(availablePackages().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func installedPackages() -> [InstalledPackage] {
        database.load().packages.values.sorted { $0.name < $1.name }
    }

    private func upgradablePackages(available: [String: PackageRecord], status: PackageStatus) -> [(InstalledPackage, PackageRecord)] {
        status.packages.values.sorted { $0.name < $1.name }.compactMap { installed in
            guard let record = available[installed.name], PackageVersion.compare(record.version, installed.version) == .orderedDescending else { return nil }
            return (installed, record)
        }
    }

    private func withLock(_ context: CommandContext, _ body: () throws -> Int32) -> Int32 {
        do {
            try layout.createDirectories()
        } catch {
            context.stderr.writeLine("E: Could not create \(layout.prefix): \(error.localizedDescription)")
            return 100
        }
        guard let lock = PackageLock(path: layout.lockFile) else {
            context.stderr.writeLine("E: Could not get lock \(layout.lockFile). It is held by another session.")
            return 100
        }
        defer { withExtendedLifetime(lock) {} }
        do {
            return try body()
        } catch let failure as Failure {
            return failure.status
        } catch {
            context.stderr.writeLine("E: \(error.localizedDescription)")
            return 100
        }
    }

    private func interrupted(_ context: CommandContext) -> Failure {
        context.stderr.writeLine("E: Interrupted")
        return Failure(status: 130)
    }

    private func printTreeHeader(_ context: CommandContext) {
        context.print("Reading package lists... Done")
        context.print("Building dependency tree... Done")
    }

    public func update(_ context: CommandContext) -> Int32 {
        withLock(context) { try performUpdate(context, quiet: false) }
    }

    private func performUpdate(_ context: CommandContext, quiet: Bool) throws -> Int32 {
        let start = Date()
        var fetchedBytes: Int64 = 0
        var failures = 0
        for (offset, source) in sources().enumerated() {
            let number = offset + 1
            let listFile = layout.listFile(for: source)
            let stagedFile = listFile + ".partial"
            let result = fetcher.fetch(source, to: stagedFile, cancellation: context.cancellation) { _, _ in }
            switch result {
            case .success(let size):
                guard let data = fileManager.contents(atPath: stagedFile), (try? PackageIndex.decode(data)) != nil else {
                    try? fileManager.removeItem(atPath: stagedFile)
                    context.print("Err:\(number) \(source.absoluteString)")
                    context.print("  The package index is not valid")
                    failures += 1
                    continue
                }
                try? fileManager.removeItem(atPath: listFile)
                try fileManager.moveItem(atPath: stagedFile, toPath: listFile)
                fetchedBytes += size
                if !quiet { context.print("Get:\(number) \(source.absoluteString) [\(PackageFormat.size(size))]") }
            case .failure(.cancelled):
                try? fileManager.removeItem(atPath: stagedFile)
                throw interrupted(context)
            case .failure(let error):
                try? fileManager.removeItem(atPath: stagedFile)
                context.print("Err:\(number) \(source.absoluteString)")
                context.print("  \(error.message)")
                failures += 1
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        if !quiet && fetchedBytes > 0 {
            context.print("Fetched \(PackageFormat.size(fetchedBytes)) in \(PackageFormat.duration(elapsed)) (\(PackageFormat.rate(bytes: fetchedBytes, seconds: elapsed)))")
        }
        if !quiet { printTreeHeader(context) }
        if failures > 0 {
            context.stderr.writeLine("W: Some index files failed to download. They have been ignored, or old ones used instead.")
        }
        if !hasCachedLists {
            guard bundledIndex() != nil else {
                context.stderr.writeLine("E: No package lists are available. Check your network connection and \(layout.sourcesFile).")
                return 100
            }
            context.stderr.writeLine("W: Using the package list bundled with the app.")
        }
        if !quiet {
            let upgradable = upgradablePackages(available: availableByName(), status: database.load()).count
            if upgradable == 0 {
                context.print("All packages are up to date.")
            } else {
                context.print("\(upgradable) package\(upgradable == 1 ? "" : "s") can be upgraded. Run 'apt list --upgradable' to see \(upgradable == 1 ? "it" : "them").")
            }
        }
        return 0
    }

    func resolve(_ names: [String], available: [String: PackageRecord]) -> Result<[PackageRecord], PackageResolutionError> {
        var ordered: [PackageRecord] = []
        var visited: Set<String> = []
        func lookup(_ name: String) -> PackageRecord? {
            if let record = available[name] { return record }
            return available.values.sorted { $0.name < $1.name }.first { ($0.provides ?? []).contains(name) }
        }
        func visit(_ record: PackageRecord, chain: [String]) -> PackageResolutionError? {
            if visited.contains(record.name) { return nil }
            if chain.contains(record.name) { return .cycle(chain + [record.name]) }
            for dependency in record.dependencies {
                guard let dependencyRecord = lookup(dependency) else {
                    return .missingDependency(package: record.name, dependency: dependency)
                }
                if let error = visit(dependencyRecord, chain: chain + [record.name]) { return error }
            }
            visited.insert(record.name)
            ordered.append(record)
            return nil
        }
        for name in names {
            guard let record = lookup(name) else { return .failure(.notFound(name)) }
            if let error = visit(record, chain: []) { return .failure(error) }
        }
        return .success(ordered)
    }

    public func install(_ names: [String], reinstall: Bool, context: CommandContext) -> Int32 {
        withLock(context) {
            if !hasCachedLists {
                let status = try performUpdate(context, quiet: true)
                if status != 0 { return status }
            }
            return try performInstall(names, reinstall: reinstall, upgrading: false, context: context)
        }
    }

    public func upgrade(_ context: CommandContext) -> Int32 {
        withLock(context) {
            let updateStatus = try performUpdate(context, quiet: false)
            if updateStatus != 0 { return updateStatus }
            let names = upgradablePackages(available: availableByName(), status: database.load()).map { $0.0.name }
            return try performInstall(names, reinstall: false, upgrading: true, context: context)
        }
    }

    private func summaryLine(upgraded: Int, installed: Int, reinstalled: Int, removed: Int, notUpgraded: Int) -> String {
        var line = "\(upgraded) upgraded, \(installed) newly installed, "
        if reinstalled > 0 { line += "\(reinstalled) reinstalled, " }
        line += "\(removed) to remove and \(notUpgraded) not upgraded."
        return line
    }

    private func printNames(_ names: [String], context: CommandContext) {
        var line = " "
        for name in names {
            if line.count + name.count + 1 > max(40, context.terminalColumns - 1) && line != " " {
                context.print(line)
                line = " "
            }
            line += " " + name
        }
        if line != " " { context.print(line) }
    }

    private func performInstall(_ names: [String], reinstall: Bool, upgrading: Bool, context: CommandContext) throws -> Int32 {
        if context.isCancelled { throw interrupted(context) }
        if !upgrading { printTreeHeader(context) }
        let available = availableByName()
        let records: [PackageRecord]
        switch resolve(names, available: available) {
        case .success(let resolved):
            records = resolved
        case .failure(.notFound(let name)):
            context.stderr.writeLine("E: Unable to locate package \(name)")
            context.stderr.writeLine(PackageManager.platformHint)
            return 100
        case .failure(.missingDependency(let package, let dependency)):
            context.print("Some packages could not be installed.")
            context.print("The following packages have unmet dependencies:")
            context.print(" \(package) : Depends: \(dependency) but it is not installable")
            context.stderr.writeLine("E: Unable to correct problems, you have held broken packages.")
            return 100
        case .failure(.cycle(let chain)):
            context.stderr.writeLine("E: Dependency cycle: \(chain.joined(separator: " -> "))")
            return 100
        }
        for record in records {
            if let problem = record.validationError() {
                context.stderr.writeLine("E: \(record.name): \(problem) in the package index")
                return 100
            }
        }
        var status = database.load()
        let requested = Set(names.compactMap { name in available[name]?.name ?? records.first { ($0.provides ?? []).contains(name) }?.name })
        var plan: [PlannedPackage] = []
        for record in records {
            if let installed = status.packages[record.name] {
                if PackageVersion.compare(record.version, installed.version) == .orderedDescending {
                    plan.append(PlannedPackage(record: record, operation: .upgrade(installed)))
                } else if reinstall && requested.contains(record.name) {
                    plan.append(PlannedPackage(record: record, operation: .reinstall(installed)))
                } else if requested.contains(record.name) {
                    context.print("\(record.name) is already the newest version (\(installed.version)).")
                }
            } else {
                plan.append(PlannedPackage(record: record, operation: .install))
            }
        }
        var owners: [String: String] = [:]
        for installed in status.packages.values where !plan.contains(where: { $0.record.name == installed.name }) {
            for file in installed.files { owners[file] = installed.name }
        }
        for planned in plan {
            let paths = planned.record.files.map { $0.path } + planned.record.commands.keys.map { "bin/" + $0 }
            for path in paths.sorted() {
                if let owner = owners[path], owner != planned.record.name {
                    context.stderr.writeLine("E: \(planned.record.name): trying to overwrite '\(layout.path(for: path))', which is also in package \(owner)")
                    return 100
                }
                owners[path] = planned.record.name
            }
        }
        let newNames = plan.compactMap { if case .install = $0.operation { return $0.record.name } else { return nil } }
        let upgradeNames = plan.compactMap { if case .upgrade = $0.operation { return $0.record.name } else { return nil } }
        let reinstallNames = plan.compactMap { if case .reinstall = $0.operation { return $0.record.name } else { return nil } }
        let plannedNames = Set(plan.map { $0.record.name })
        let notUpgraded = upgradablePackages(available: available, status: status).filter { !plannedNames.contains($0.0.name) }.count
        if !newNames.isEmpty {
            context.print("The following NEW packages will be installed:")
            printNames(newNames, context: context)
        }
        if !upgradeNames.isEmpty {
            context.print("The following packages will be upgraded:")
            printNames(upgradeNames, context: context)
        }
        context.print(summaryLine(upgraded: upgradeNames.count, installed: newNames.count, reinstalled: reinstallNames.count,
                                  removed: 0, notUpgraded: notUpgraded))
        if plan.isEmpty { return 0 }
        for planned in plan {
            for command in planned.record.commands.keys.sorted() where context.shell.registry.command(named: command) != nil {
                context.stderr.writeLine("W: '\(command)' is also a built-in command; run the package version as \(layout.binDirectory)/\(command)")
            }
        }
        let downloadTotal = plan.reduce(Int64(0)) { $0 + $1.record.downloadSize }
        let sizeChange = plan.reduce(Int64(0)) { total, planned in
            switch planned.operation {
            case .install: return total + planned.record.installedSizeEstimate
            case .upgrade(let old), .reinstall(let old): return total + planned.record.installedSizeEstimate - old.installedSize
            }
        }
        if downloadTotal > 0 { context.print("Need to get \(PackageFormat.size(downloadTotal)) of archives.") }
        if sizeChange > 0 {
            context.print("After this operation, \(PackageFormat.size(sizeChange)) of additional disk space will be used.")
        } else if sizeChange < 0 {
            context.print("After this operation, \(PackageFormat.size(-sizeChange)) disk space will be freed.")
        }

        var stagedPaths: [String] = []
        defer { for path in stagedPaths { try? fileManager.removeItem(atPath: path) } }
        var downloads: [String: [DownloadedFile]] = [:]
        let progress = DownloadProgress(context: context, totalBytes: downloadTotal)
        var number = 0
        for planned in plan {
            var files: [DownloadedFile] = []
            for (fileIndex, file) in planned.record.files.enumerated() {
                let stagedPath = layout.archivesDirectory + "/\(planned.record.name)_\(planned.record.version)_\(fileIndex).partial"
                stagedPaths.append(stagedPath)
                try? fileManager.removeItem(atPath: stagedPath)
                if let text = file.text {
                    guard fileManager.createFile(atPath: stagedPath, contents: Data(text.utf8)) else {
                        context.stderr.writeLine("E: Could not write \(stagedPath)")
                        return 100
                    }
                } else {
                    number += 1
                    try download(file, record: planned.record, number: number, to: stagedPath, progress: progress, context: context)
                }
                files.append(DownloadedFile(file: file, stagedPath: stagedPath))
            }
            downloads[planned.record.name] = files
        }
        progress.finish()

        let transaction = PackageTransaction(layout: layout)
        for planned in plan {
            if context.isCancelled {
                transaction.rollback()
                throw interrupted(context)
            }
            let record = planned.record
            switch planned.operation {
            case .install:
                context.print("Selecting previously unselected package \(record.name).")
                context.print("Unpacking \(record.name) (\(record.version)) ...")
            case .upgrade(let old), .reinstall(let old):
                context.print("Preparing to unpack \(record.name) (\(record.version)) ...")
                context.print("Unpacking \(record.name) (\(record.version)) over (\(old.version)) ...")
            }
            do {
                let installed = try place(record, files: downloads[record.name] ?? [], transaction: transaction)
                if case .upgrade(let old) = planned.operation {
                    for obsolete in Set(old.files).subtracting(installed.files).sorted() {
                        try transaction.remove(layout.path(for: obsolete))
                    }
                } else if case .reinstall(let old) = planned.operation {
                    for obsolete in Set(old.files).subtracting(installed.files).sorted() {
                        try transaction.remove(layout.path(for: obsolete))
                    }
                }
                status.packages[record.name] = installed
            } catch {
                transaction.rollback()
                context.stderr.writeLine("E: \(record.name): \(error.localizedDescription)")
                return 100
            }
        }
        do {
            try database.save(status)
        } catch {
            transaction.rollback()
            context.stderr.writeLine("E: Could not write \(layout.statusFile): \(error.localizedDescription)")
            return 100
        }
        transaction.commit()
        for planned in plan {
            context.print("Setting up \(planned.record.name) (\(planned.record.version)) ...")
        }
        for planned in plan {
            if let notes = planned.record.notes, !notes.isEmpty {
                context.print()
                context.print("\(planned.record.name): \(notes)")
            }
        }
        return 0
    }

    private func download(_ file: PackageFile, record: PackageRecord, number: Int, to stagedPath: String,
                          progress: DownloadProgress, context: CommandContext) throws {
        guard let expectedHash = file.sha256?.lowercased(), !expectedHash.isEmpty else {
            context.stderr.writeLine("E: \(record.name): file has no checksum")
            throw Failure(status: 100)
        }
        let urls = (file.urls ?? []).compactMap { URL(string: $0) }
        var lastError: (URL, String)?
        for url in urls {
            progress.begin(number: number, name: record.name, expected: file.size)
            let result = fetcher.fetch(url, to: stagedPath, cancellation: context.cancellation) { received, expected in
                progress.update(received: received, expected: expected)
            }
            switch result {
            case .failure(.cancelled):
                progress.clear()
                try? fileManager.removeItem(atPath: stagedPath)
                throw interrupted(context)
            case .failure(let error):
                progress.clear()
                lastError = (url, error.message)
                continue
            case .success(let size):
                progress.complete(size)
                context.print("Get:\(number) \(url.absoluteString) \(record.name) \(record.architectureName) \(record.version) [\(PackageFormat.size(size))]")
                let receivedHash = PackageChecksum.sha256(fileAtPath: stagedPath) ?? ""
                if receivedHash != expectedHash || (file.size.map { $0 != size } ?? false) {
                    try? fileManager.removeItem(atPath: stagedPath)
                    context.stderr.writeLine("E: Failed to fetch \(url.absoluteString)  Hash Sum mismatch")
                    context.stderr.writeLine("   Hashes of expected file:")
                    context.stderr.writeLine("    - SHA256:\(expectedHash)")
                    if let expectedSize = file.size { context.stderr.writeLine("    - Filesize:\(expectedSize)") }
                    context.stderr.writeLine("   Hashes of received file:")
                    context.stderr.writeLine("    - SHA256:\(receivedHash)")
                    context.stderr.writeLine("    - Filesize:\(size)")
                    throw Failure(status: 100)
                }
                return
            }
        }
        if let (url, message) = lastError {
            context.stderr.writeLine("E: Failed to fetch \(url.absoluteString)  \(message)")
        } else {
            context.stderr.writeLine("E: \(record.name): file \(file.path) has no download URL")
        }
        throw Failure(status: 100)
    }

    private func place(_ record: PackageRecord, files: [DownloadedFile], transaction: PackageTransaction) throws -> InstalledPackage {
        var installedFiles: [String] = []
        var installedSize: Int64 = 0
        for downloaded in files {
            let destination = layout.path(for: downloaded.file.path)
            let mode = downloaded.file.mode.flatMap { Int($0, radix: 8) } ?? record.defaultMode(for: downloaded.file)
            try transaction.place(downloaded.stagedPath, at: destination, mode: mode)
            installedFiles.append(downloaded.file.path)
            installedSize += (try? fileManager.attributesOfItem(atPath: destination)[.size] as? NSNumber)?.int64Value ?? 0
        }
        for command in record.commands.keys.sorted() {
            guard let target = record.commands[command] else { continue }
            try transaction.link(layout.binDirectory + "/" + command, to: "../" + target)
            installedFiles.append("bin/" + command)
        }
        return InstalledPackage(name: record.name, version: record.version, description: record.description,
                                depends: record.depends, files: installedFiles, commands: record.commands.keys.sorted(),
                                installedSize: installedSize, installationDate: Date())
    }

    public func remove(_ names: [String], context: CommandContext) -> Int32 {
        withLock(context) {
            printTreeHeader(context)
            var status = database.load()
            var targets: [InstalledPackage] = []
            for name in names {
                if let installed = status.packages[name] {
                    if !targets.contains(where: { $0.name == name }) { targets.append(installed) }
                } else {
                    context.print("Package '\(name)' is not installed, so not removed")
                }
            }
            let targetNames = Set(targets.map { $0.name })
            let available = availableByName()
            for installed in status.packages.values.sorted(by: { $0.name < $1.name }) where !targetNames.contains(installed.name) {
                let dependencies = installed.depends ?? available[installed.name]?.dependencies ?? []
                if let needed = dependencies.first(where: { targetNames.contains($0) }) {
                    context.stderr.writeLine("E: \(needed) is needed by \(installed.name)")
                    return 100
                }
            }
            let notUpgraded = upgradablePackages(available: available, status: status).filter { !targetNames.contains($0.0.name) }.count
            if !targets.isEmpty {
                context.print("The following packages will be REMOVED:")
                printNames(targets.map { $0.name }, context: context)
            }
            context.print(summaryLine(upgraded: 0, installed: 0, reinstalled: 0, removed: targets.count, notUpgraded: notUpgraded))
            if targets.isEmpty { return 0 }
            let freed = targets.reduce(Int64(0)) { $0 + $1.installedSize }
            if freed > 0 { context.print("After this operation, \(PackageFormat.size(freed)) disk space will be freed.") }
            let transaction = PackageTransaction(layout: layout)
            for installed in targets {
                context.print("Removing \(installed.name) (\(installed.version)) ...")
                do {
                    for file in installed.files.sorted().reversed() { try transaction.remove(layout.path(for: file)) }
                } catch {
                    transaction.rollback()
                    context.stderr.writeLine("E: \(installed.name): \(error.localizedDescription)")
                    return 100
                }
                status.packages[installed.name] = nil
            }
            do {
                try database.save(status)
            } catch {
                transaction.rollback()
                context.stderr.writeLine("E: Could not write \(layout.statusFile): \(error.localizedDescription)")
                return 100
            }
            transaction.commit()
            return 0
        }
    }

    private func listLine(_ record: PackageRecord, installed: InstalledPackage?, color: Bool) -> String {
        let name = color ? ANSI.boldGreen + record.name + ANSI.reset : record.name
        var line = "\(name)/stable \(record.version) \(record.architectureName)"
        if let installed = installed {
            if PackageVersion.compare(record.version, installed.version) == .orderedDescending {
                line += " [upgradable from: \(installed.version)]"
            } else {
                line += " [installed]"
            }
        }
        return line
    }

    private func warnIfNoPackageLists(_ records: [PackageRecord], context: CommandContext) {
        if records.isEmpty && !hasCachedLists {
            context.stderr.writeLine("W: No package lists are available. Run 'pkg update' first.")
        }
    }

    public func listAvailable(_ context: CommandContext) -> Int32 {
        let status = database.load()
        let records = availablePackages()
        context.print("Listing... Done")
        warnIfNoPackageLists(records, context: context)
        for record in records {
            context.print(listLine(record, installed: status.packages[record.name], color: context.stdout.isTerminal))
        }
        return 0
    }

    public func listInstalled(_ context: CommandContext) -> Int32 {
        let available = availableByName()
        context.print("Listing... Done")
        for installed in installedPackages() {
            let color = context.stdout.isTerminal
            let name = color ? ANSI.boldGreen + installed.name + ANSI.reset : installed.name
            if let record = available[installed.name] {
                let upgradable = PackageVersion.compare(record.version, installed.version) == .orderedDescending
                context.print("\(name)/stable \(installed.version) \(record.architectureName) [installed\(upgradable ? ",upgradable to: \(record.version)" : "")]")
            } else {
                context.print("\(name)/now \(installed.version) \(PackageRecord.defaultArchitecture) [installed,local]")
            }
        }
        return 0
    }

    public func listUpgradable(_ context: CommandContext) -> Int32 {
        context.print("Listing... Done")
        for (installed, record) in upgradablePackages(available: availableByName(), status: database.load()) {
            context.print(listLine(record, installed: installed, color: context.stdout.isTerminal))
        }
        return 0
    }

    public func search(_ patterns: [String], context: CommandContext) -> Int32 {
        guard !patterns.isEmpty else {
            context.stderr.writeLine("E: You must give at least one search pattern")
            return 100
        }
        var expressions: [NSRegularExpression] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                context.stderr.writeLine("E: Regex compilation error: \(pattern)")
                return 100
            }
            expressions.append(expression)
        }
        let status = database.load()
        let records = availablePackages()
        context.print("Sorting... Done")
        context.print("Full Text Search... Done")
        warnIfNoPackageLists(records, context: context)
        for record in records {
            let text = record.name + "\n" + record.description + "\n" + (record.provides ?? []).joined(separator: " ")
            let range = NSRange(text.startIndex..., in: text)
            guard expressions.allSatisfy({ $0.firstMatch(in: text, options: [], range: range) != nil }) else { continue }
            context.print(listLine(record, installed: status.packages[record.name], color: context.stdout.isTerminal))
            context.print("  " + record.description)
            context.print()
        }
        return 0
    }

    public func show(_ names: [String], context: CommandContext) -> Int32 {
        let available = availableByName()
        let status = database.load()
        var result: Int32 = 0
        for name in names {
            guard let record = available[name] ?? available.values.first(where: { ($0.provides ?? []).contains(name) }) else {
                context.stderr.writeLine("N: Unable to locate package \(name)")
                context.stderr.writeLine("E: No packages found")
                result = 100
                continue
            }
            context.print("Package: \(record.name)")
            context.print("Version: \(record.version)")
            context.print("Architecture: \(record.architectureName)")
            if !record.dependencies.isEmpty { context.print("Depends: \(record.dependencies.joined(separator: ", "))") }
            if let provides = record.provides, !provides.isEmpty { context.print("Provides: \(provides.joined(separator: ", "))") }
            if let homepage = record.homepage { context.print("Homepage: \(homepage)") }
            context.print("Download-Size: \(PackageFormat.size(record.downloadSize))")
            let installedSize = status.packages[record.name]?.installedSize ?? record.installedSizeEstimate
            context.print("Installed-Size: \(PackageFormat.size(installedSize))")
            if let license = record.license { context.print("License: \(license)") }
            if !record.commands.isEmpty { context.print("Commands: \(record.commands.keys.sorted().joined(separator: ", "))") }
            context.print("Description: \(record.description)")
            if let notes = record.notes, !notes.isEmpty { context.print(" \(notes)") }
            context.print()
        }
        return result
    }

    public func files(_ names: [String], context: CommandContext) -> Int32 {
        guard !names.isEmpty else {
            context.stderr.writeLine("E: No package name given")
            return 1
        }
        let status = database.load()
        var result: Int32 = 0
        for name in names {
            guard let installed = status.packages[name] else {
                context.stderr.writeLine("E: Package '\(name)' is not installed")
                result = 1
                continue
            }
            for file in installed.files.sorted() { context.print(layout.path(for: file)) }
        }
        return result
    }

    public func listInstalledTable(_ context: CommandContext) -> Int32 {
        let packages = installedPackages()
        let nameWidth = max(14, packages.map { $0.name.count }.max() ?? 0)
        let versionWidth = max(12, packages.map { $0.version.count }.max() ?? 0)
        context.print("Desired=Unknown/Install/Remove/Purge/Hold")
        context.print("| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend")
        context.print("|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)")
        context.print("||/ " + ShellFormat.pad("Name", nameWidth) + " " + ShellFormat.pad("Version", versionWidth) + " Architecture Description")
        context.print("+++-" + String(repeating: "=", count: nameWidth) + "-" + String(repeating: "=", count: versionWidth) + "-============-" + String(repeating: "=", count: 40))
        for installed in packages {
            context.print("ii  " + ShellFormat.pad(installed.name, nameWidth) + " " + ShellFormat.pad(installed.version, versionWidth) + " "
                          + ShellFormat.pad(PackageRecord.defaultArchitecture, 12) + " " + installed.description)
        }
        return 0
    }

    public func clean(_ context: CommandContext) -> Int32 {
        withLock(context) {
            for entry in (try? fileManager.contentsOfDirectory(atPath: layout.archivesDirectory)) ?? [] {
                try? fileManager.removeItem(atPath: layout.archivesDirectory + "/" + entry)
            }
            return 0
        }
    }

    public func autoremove(_ context: CommandContext) -> Int32 {
        printTreeHeader(context)
        context.print(summaryLine(upgraded: 0, installed: 0, reinstalled: 0, removed: 0, notUpgraded: 0))
        return 0
    }
}

final class DownloadProgress {
    private let context: CommandContext
    private let totalBytes: Int64
    private let enabled: Bool
    private var completedBytes: Int64 = 0
    private var currentReceived: Int64 = 0
    private var currentExpected: Int64?
    private var number = 0
    private var name = ""
    private var start = Date()
    private var lastDraw = Date.distantPast
    private var visible = false
    let startDate = Date()

    init(context: CommandContext, totalBytes: Int64) {
        self.context = context
        self.totalBytes = totalBytes
        self.enabled = context.stdout.isTerminal
    }

    func begin(number: Int, name: String, expected: Int64?) {
        self.number = number
        self.name = name
        currentReceived = 0
        currentExpected = expected
        start = Date()
    }

    func update(received: Int64, expected: Int64?) {
        currentReceived = received
        if let expected = expected { currentExpected = expected }
        guard enabled, Date().timeIntervalSince(lastDraw) >= 0.1 else { return }
        lastDraw = Date()
        let done = completedBytes + currentReceived
        let percent = totalBytes > 0 ? min(100, Int(done * 100 / totalBytes)) : 0
        let total = currentExpected.map { PackageFormat.size($0) } ?? "?"
        let rate = PackageFormat.rate(bytes: currentReceived, seconds: Date().timeIntervalSince(start))
        context.stdout.write("\r\u{1B}[K\(percent)% [\(number) \(name) \(PackageFormat.size(currentReceived))/\(total) \(rate)]")
        context.stdout.flush()
        visible = true
    }

    func clear() {
        guard visible else { return }
        context.stdout.write("\r\u{1B}[K")
        visible = false
    }

    func complete(_ size: Int64) {
        clear()
        completedBytes += size
        currentReceived = 0
    }

    func finish() {
        clear()
        guard completedBytes > 0 else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        context.print("Fetched \(PackageFormat.size(completedBytes)) in \(PackageFormat.duration(elapsed)) (\(PackageFormat.rate(bytes: completedBytes, seconds: elapsed)))")
    }
}

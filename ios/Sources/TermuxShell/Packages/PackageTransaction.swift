import Foundation

final class PackageTransaction {
    private let layout: PackageLayout
    private let fileManager = FileManager.default
    private var createdPaths: [String] = []
    private var createdDirectories: [String] = []
    private var backups: [(original: String, backup: String)] = []
    private var emptiedDirectoryCandidates: Set<String> = []

    init(layout: PackageLayout) {
        self.layout = layout
    }

    private func exists(_ path: String) -> Bool { FileInfo(path: path) != nil }

    private func makeParentDirectory(of path: String) throws {
        var missing: [String] = []
        var directory = ShellPath.dirname(path)
        while !exists(directory) && directory != "/" {
            missing.append(directory)
            directory = ShellPath.dirname(directory)
        }
        for directory in missing.reversed() {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: false)
            createdDirectories.append(directory)
        }
    }

    private func backUp(_ path: String) throws {
        guard exists(path) else { return }
        let backup = layout.archivesDirectory + "/backup-" + UUID().uuidString
        try fileManager.moveItem(atPath: path, toPath: backup)
        backups.append((path, backup))
    }

    func place(_ source: String, at destination: String, mode: Int) throws {
        try makeParentDirectory(of: destination)
        try backUp(destination)
        try fileManager.moveItem(atPath: source, toPath: destination)
        createdPaths.append(destination)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination)
    }

    func link(_ path: String, to target: String) throws {
        try makeParentDirectory(of: path)
        try backUp(path)
        try fileManager.createSymbolicLink(atPath: path, withDestinationPath: target)
        createdPaths.append(path)
    }

    func remove(_ path: String) throws {
        guard !createdPaths.contains(path) else { return }
        try backUp(path)
        emptiedDirectoryCandidates.insert(ShellPath.dirname(path))
    }

    func rollback() {
        for path in createdPaths.reversed() { try? fileManager.removeItem(atPath: path) }
        for (original, backup) in backups.reversed() {
            try? fileManager.createDirectory(atPath: ShellPath.dirname(original), withIntermediateDirectories: true)
            try? fileManager.moveItem(atPath: backup, toPath: original)
        }
        for directory in createdDirectories.reversed() { try? fileManager.removeItem(atPath: directory) }
        createdPaths = []
        backups = []
        createdDirectories = []
    }

    func commit() {
        for (_, backup) in backups { try? fileManager.removeItem(atPath: backup) }
        backups = []
        let protected = Set(layout.directories + [layout.prefix, layout.prefix + "/libexec", layout.prefix + "/var", layout.prefix + "/etc"])
        for candidate in emptiedDirectoryCandidates.sorted(by: { $0.count > $1.count }) {
            var directory = candidate
            while directory.hasPrefix(layout.prefix + "/") && !protected.contains(directory) {
                guard let entries = try? fileManager.contentsOfDirectory(atPath: directory), entries.isEmpty else { break }
                try? fileManager.removeItem(atPath: directory)
                directory = ShellPath.dirname(directory)
            }
        }
        emptiedDirectoryCandidates = []
        createdPaths = []
        createdDirectories = []
    }
}

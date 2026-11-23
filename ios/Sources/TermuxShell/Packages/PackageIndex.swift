import Foundation

public struct PackageIndex: Codable, Equatable {
    public var format: Int
    public var name: String
    public var packages: [PackageRecord]

    public init(format: Int = 1, name: String, packages: [PackageRecord]) {
        self.format = format
        self.name = name
        self.packages = packages
    }

    public static func decode(_ data: Data) throws -> PackageIndex {
        try JSONDecoder().decode(PackageIndex.self, from: data)
    }
}

public struct PackageRecord: Codable, Equatable {
    public static let defaultArchitecture = "wasm32"

    public var name: String
    public var version: String
    public var architecture: String?
    public var description: String
    public var homepage: String?
    public var license: String?
    public var depends: [String]?
    public var provides: [String]?
    public var files: [PackageFile]
    public var commands: [String: String]
    public var notes: String?

    public init(name: String, version: String, architecture: String? = nil, description: String, homepage: String? = nil,
                license: String? = nil, depends: [String]? = nil, provides: [String]? = nil, files: [PackageFile],
                commands: [String: String] = [:], notes: String? = nil) {
        self.name = name
        self.version = version
        self.architecture = architecture
        self.description = description
        self.homepage = homepage
        self.license = license
        self.depends = depends
        self.provides = provides
        self.files = files
        self.commands = commands
        self.notes = notes
    }

    public var architectureName: String { architecture ?? PackageRecord.defaultArchitecture }

    public var dependencies: [String] { depends ?? [] }

    public var downloadSize: Int64 {
        files.reduce(0) { total, file in total + (file.isDownloaded ? (file.size ?? 0) : 0) }
    }

    public var installedSizeEstimate: Int64 {
        files.reduce(0) { total, file in total + (file.size ?? Int64(file.text?.utf8.count ?? 0)) }
    }

    public func defaultMode(for file: PackageFile) -> Int {
        commands.values.contains(file.path) ? 0o755 : 0o644
    }

    public func validationError() -> String? {
        if name.isEmpty || name.contains("/") || name.contains(" ") || name.contains("\0") || name == "." || name == ".." {
            return "invalid package name '\(name)'"
        }
        if version.isEmpty || version.contains("/") || version.contains(" ") || version.contains("\0") { return "invalid version '\(version)'" }
        var seenPaths: Set<String> = []
        for file in files {
            if !PackageFile.isSafeRelativePath(file.path) || PackageFile.isReservedPath(file.path) { return "invalid file path '\(file.path)'" }
            if !seenPaths.insert(file.path).inserted { return "duplicate file path '\(file.path)'" }
            if file.text == nil && (file.urls ?? []).isEmpty { return "file '\(file.path)' has neither text nor a download URL" }
            if let mode = file.mode, Int(mode, radix: 8) == nil { return "invalid mode '\(mode)' for '\(file.path)'" }
        }
        for (command, path) in commands {
            if command.isEmpty || command.contains("/") || command == "." || command == ".." { return "invalid command name '\(command)'" }
            if !PackageFile.isSafeRelativePath(path) { return "invalid command path '\(path)'" }
            if seenPaths.contains("bin/" + command) { return "command '\(command)' conflicts with the file 'bin/\(command)'" }
            if !files.contains(where: { $0.path == path }) { return "command '\(command)' points to a file that is not in the package" }
        }
        return nil
    }
}

public struct PackageFile: Codable, Equatable {
    public var path: String
    public var urls: [String]?
    public var sha256: String?
    public var size: Int64?
    public var text: String?
    public var mode: String?

    public init(path: String, urls: [String]? = nil, sha256: String? = nil, size: Int64? = nil, text: String? = nil, mode: String? = nil) {
        self.path = path
        self.urls = urls
        self.sha256 = sha256
        self.size = size
        self.text = text
        self.mode = mode
    }

    public var isDownloaded: Bool { text == nil }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.hasSuffix("/") || path.contains("\0") { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    public static let reservedDirectories = ["etc/pkg", "var/lib/pkg", "var/cache/pkg", "tmp"]

    public static func isReservedPath(_ path: String) -> Bool {
        reservedDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

public struct InstalledPackage: Codable, Equatable {
    public var name: String
    public var version: String
    public var description: String
    public var depends: [String]?
    public var files: [String]
    public var commands: [String]
    public var installedSize: Int64
    public var installationDate: Date

    public init(name: String, version: String, description: String, depends: [String]? = nil, files: [String], commands: [String],
                installedSize: Int64, installationDate: Date) {
        self.name = name
        self.version = version
        self.description = description
        self.depends = depends
        self.files = files
        self.commands = commands
        self.installedSize = installedSize
        self.installationDate = installationDate
    }
}

public struct PackageStatus: Codable, Equatable {
    public var format: Int
    public var packages: [String: InstalledPackage]

    public init(format: Int = 1, packages: [String: InstalledPackage] = [:]) {
        self.format = format
        self.packages = packages
    }
}

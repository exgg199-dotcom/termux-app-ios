import Foundation

public struct PackageLayout {
    public static let defaultSource = "https://raw.githubusercontent.com/exgg199-dotcom/termux-app-ios/master/packages/index.json"

    public let prefix: String

    public init(prefix: String) {
        self.prefix = ShellPath.normalize(prefix)
    }

    public var binDirectory: String { prefix + "/bin" }
    public var webAssemblyDirectory: String { prefix + "/libexec/wasm" }
    public var configurationDirectory: String { prefix + "/etc/pkg" }
    public var sourcesFile: String { configurationDirectory + "/sources.list" }
    public var stateDirectory: String { prefix + "/var/lib/pkg" }
    public var statusFile: String { stateDirectory + "/status.json" }
    public var listsDirectory: String { stateDirectory + "/lists" }
    public var archivesDirectory: String { prefix + "/var/cache/pkg/archives" }
    public var lockFile: String { stateDirectory + "/lock" }
    public var temporaryDirectory: String { prefix + "/tmp" }

    public func path(for relativePath: String) -> String { prefix + "/" + relativePath }

    public func listFile(for source: URL) -> String {
        let name = String(source.absoluteString.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        })
        return listsDirectory + "/" + name + ".json"
    }

    public var directories: [String] {
        [binDirectory, configurationDirectory, webAssemblyDirectory, listsDirectory, archivesDirectory, temporaryDirectory]
    }

    public func createDirectories() throws {
        for directory in directories {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }
}

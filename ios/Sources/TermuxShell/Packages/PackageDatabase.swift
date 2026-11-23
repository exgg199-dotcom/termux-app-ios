import Foundation

public final class PackageDatabase {
    public let layout: PackageLayout

    public init(layout: PackageLayout) {
        self.layout = layout
    }

    public func load() -> PackageStatus {
        guard let data = FileManager.default.contents(atPath: layout.statusFile) else { return PackageStatus() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PackageStatus.self, from: data)) ?? PackageStatus()
    }

    public func save(_ status: PackageStatus) throws {
        try FileManager.default.createDirectory(atPath: layout.stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(status)
        try data.write(to: URL(fileURLWithPath: layout.statusFile), options: .atomic)
    }
}

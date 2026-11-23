import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum PackageChecksum {
    public static func sha256(fileAtPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        #if canImport(CryptoKit)
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        let data = handle.readDataToEndOfFile()
        return Hashing.hex(Hashing.sha256([UInt8](data)))
        #endif
    }
}

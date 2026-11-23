import Foundation
import WasmKit
import SystemPackage
import TermuxShell

enum WasmModuleLoadError: Error {
    case unreadable
    case component
    case invalid(String)
}

final class WasmModuleCache {
    private struct Key: Equatable {
        let path: String
        let size: Int64
        let modificationDate: Date
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [(key: Key, module: Module)] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func module(at requestedPath: String) -> Result<Module, WasmModuleLoadError> {
        let path = URL(fileURLWithPath: requestedPath).resolvingSymlinksInPath().path
        guard let fileInformation = FileInfo(path: path, follow: true) else { return .failure(.unreadable) }
        let key = Key(path: path, size: fileInformation.size, modificationDate: fileInformation.modificationDate)
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return .success(entry.module)
        }
        lock.unlock()
        guard let handle = FileHandle(forReadingAtPath: path) else { return .failure(.unreadable) }
        let header = [UInt8](handle.readData(ofLength: 8))
        handle.closeFile()
        if header.count == 8 && header.starts(with: [0x00, 0x61, 0x73, 0x6D]) && Array(header[4..<8]) != [0x01, 0x00, 0x00, 0x00] {
            return .failure(.component)
        }
        let module: Module
        do {
            module = try parseWasm(filePath: FilePath(path))
        } catch {
            return .failure(.invalid(String(describing: error)))
        }
        guard capacity > 0 else { return .success(module) }
        lock.lock()
        entries.removeAll { $0.key.path == path }
        entries.append((key, module))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        return .success(module)
    }
}

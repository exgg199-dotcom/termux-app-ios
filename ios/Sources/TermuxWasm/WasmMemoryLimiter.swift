import Foundation
import WasmKit

final class WasmMemoryLimiter: ResourceLimiter {
    let maximumBytes: Int
    private let lock = NSLock()
    private var allocatedBytes = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var currentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return allocatedBytes
    }

    func limitMemoryGrowth(to desired: Int) throws -> Bool {
        if desired > maximumBytes { return false }
        lock.lock()
        allocatedBytes = desired
        lock.unlock()
        return true
    }

    func limitTableGrowth(to desired: Int) throws -> Bool {
        true
    }
}

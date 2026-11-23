import Foundation
import WasmKit

struct WasmGuestMemoryAccess {
    let memory: Memory
    let limiter: WasmMemoryLimiter

    func contains(_ offset: UInt32, count: UInt32) -> Bool {
        let size = UInt64(limiter.currentBytes)
        return size > 0 && UInt64(offset) + UInt64(count) <= size
    }

    func readBytes(_ offset: UInt32, count: UInt32) -> [UInt8]? {
        guard contains(offset, count: count) else { return nil }
        if count == 0 { return [] }
        return memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: Int(count)) { Array($0) }
    }

    @discardableResult
    func writeBytes(_ offset: UInt32, _ bytes: [UInt8]) -> Bool {
        guard bytes.count <= Int(UInt32.max), contains(offset, count: UInt32(bytes.count)) else { return false }
        if bytes.isEmpty { return true }
        memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: bytes.count) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return true
    }

    func readUInt16(_ offset: UInt32) -> UInt16? {
        guard let bytes = readBytes(offset, count: 2) else { return nil }
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    func readUInt32(_ offset: UInt32) -> UInt32? {
        guard let bytes = readBytes(offset, count: 4) else { return nil }
        return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    func readUInt64(_ offset: UInt32) -> UInt64? {
        guard let bytes = readBytes(offset, count: 8) else { return nil }
        return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    @discardableResult
    func writeUInt16(_ offset: UInt32, _ value: UInt16) -> Bool {
        writeBytes(offset, [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    @discardableResult
    func writeUInt32(_ offset: UInt32, _ value: UInt32) -> Bool {
        writeBytes(offset, (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    @discardableResult
    func writeUInt64(_ offset: UInt32, _ value: UInt64) -> Bool {
        writeBytes(offset, (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }
}

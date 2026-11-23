import Foundation
import WasmKit
import TermuxShell

final class WasmStandardStreams {
    static let success: UInt32 = 0
    static let badFileDescriptor: UInt32 = 8
    static let fault: UInt32 = 21
    static let invalidArgument: UInt32 = 28
    static let notSupported: UInt32 = 58
    static let brokenPipe: UInt32 = 64

    private let context: CommandContext
    private let limiter: WasmMemoryLimiter

    init(context: CommandContext, limiter: WasmMemoryLimiter) {
        self.context = context
        self.limiter = limiter
    }

    func handle(_ name: String, memory: Memory, arguments: [Value]) throws -> [Value]? {
        let access = WasmGuestMemoryAccess(memory: memory, limiter: limiter)
        switch name {
        case "fd_write":
            let descriptor = arguments[0].i32
            guard descriptor == 1 || descriptor == 2 else { return nil }
            return [.i32(write(descriptor == 1 ? context.stdout : context.stderr, access: access,
                               vectors: arguments[1].i32, count: arguments[2].i32, resultPointer: arguments[3].i32))]
        case "fd_read":
            guard arguments[0].i32 == 0 else { return nil }
            return [.i32(try read(access: access, vectors: arguments[1].i32, count: arguments[2].i32, resultPointer: arguments[3].i32))]
        case "poll_oneoff":
            return [.i32(try poll(access: access, subscriptions: arguments[0].i32, events: arguments[1].i32,
                                  count: arguments[2].i32, resultPointer: arguments[3].i32))]
        case "sched_yield":
            return [.i32(WasmStandardStreams.success)]
        case "fd_close":
            return arguments[0].i32 <= 2 ? [.i32(WasmStandardStreams.success)] : nil
        case "fd_renumber":
            return arguments[0].i32 <= 2 || arguments[1].i32 <= 2 ? [.i32(WasmStandardStreams.notSupported)] : nil
        default:
            return nil
        }
    }

    private func vectorList(access: WasmGuestMemoryAccess, vectors: UInt32, count: UInt32) -> [(UInt32, UInt32)]? {
        guard UInt64(count) * 8 <= UInt64(UInt32.max), access.contains(vectors, count: count * 8) else { return nil }
        var list: [(UInt32, UInt32)] = []
        for index in 0..<count {
            guard let buffer = access.readUInt32(vectors + index * 8), let length = access.readUInt32(vectors + index * 8 + 4),
                  access.contains(buffer, count: length) else { return nil }
            list.append((buffer, length))
        }
        return list
    }

    private func write(_ stream: ShellOutputStream, access: WasmGuestMemoryAccess, vectors: UInt32, count: UInt32, resultPointer: UInt32) -> UInt32 {
        guard let list = vectorList(access: access, vectors: vectors, count: count), access.contains(resultPointer, count: 4) else {
            return WasmStandardStreams.fault
        }
        if stream.isClosed { return WasmStandardStreams.brokenPipe }
        var bytes: [UInt8] = []
        for (buffer, length) in list {
            guard let chunk = access.readBytes(buffer, count: length) else { return WasmStandardStreams.fault }
            bytes.append(contentsOf: chunk)
        }
        if !bytes.isEmpty { stream.write(bytes) }
        access.writeUInt32(resultPointer, UInt32(bytes.count))
        return WasmStandardStreams.success
    }

    private func read(access: WasmGuestMemoryAccess, vectors: UInt32, count: UInt32, resultPointer: UInt32) throws -> UInt32 {
        guard let list = vectorList(access: access, vectors: vectors, count: count), access.contains(resultPointer, count: 4) else {
            return WasmStandardStreams.fault
        }
        let total = list.reduce(UInt64(0)) { $0 + UInt64($1.1) }
        if total == 0 {
            access.writeUInt32(resultPointer, 0)
            return WasmStandardStreams.success
        }
        context.stdout.flush()
        context.stderr.flush()
        guard let bytes = context.stdin.read(maxLength: Int(min(total, 1 << 20))) else {
            if context.isCancelled { throw WasmProgramInterruption() }
            access.writeUInt32(resultPointer, 0)
            return WasmStandardStreams.success
        }
        var offset = 0
        for (buffer, length) in list where offset < bytes.count {
            let amount = min(Int(length), bytes.count - offset)
            access.writeBytes(buffer, Array(bytes[offset..<(offset + amount)]))
            offset += amount
        }
        access.writeUInt32(resultPointer, UInt32(offset))
        return WasmStandardStreams.success
    }

    private func poll(access: WasmGuestMemoryAccess, subscriptions: UInt32, events: UInt32, count: UInt32, resultPointer: UInt32) throws -> UInt32 {
        guard count > 0 else { return WasmStandardStreams.invalidArgument }
        guard UInt64(count) * 48 <= UInt64(UInt32.max), access.contains(subscriptions, count: count * 48),
              access.contains(events, count: count * 32), access.contains(resultPointer, count: 4) else {
            return WasmStandardStreams.fault
        }
        struct Subscription {
            let userData: UInt64
            let tag: UInt8
            let deadline: Double
        }
        var list: [Subscription] = []
        let wallClockNow = Date().timeIntervalSince1970
        let monotonicNow = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        for index in 0..<count {
            let base = subscriptions + index * 48
            guard let userData = access.readUInt64(base), let tagBytes = access.readBytes(base + 8, count: 1),
                  let clock = access.readUInt32(base + 16), let timeout = access.readUInt64(base + 24),
                  let flags = access.readUInt16(base + 40) else { return WasmStandardStreams.fault }
            let tag = tagBytes[0]
            var deadline = 0.0
            if tag == 0 {
                let seconds = Double(timeout) / 1e9
                if flags & 1 != 0 {
                    deadline = clock == 0 ? seconds - wallClockNow : seconds - monotonicNow
                } else {
                    deadline = seconds
                }
            }
            list.append(Subscription(userData: userData, tag: tag, deadline: max(0, deadline)))
        }
        var ready = list.filter { $0.tag != 0 }
        if ready.isEmpty {
            let earliest = list.map { $0.deadline }.min() ?? 0
            context.stdout.flush()
            if earliest > 0 && !context.cancellation.sleep(earliest) { throw WasmProgramInterruption() }
            ready = list.filter { $0.deadline <= earliest }
        }
        if context.isCancelled { throw WasmProgramInterruption() }
        for (index, subscription) in ready.enumerated() {
            let base = events + UInt32(index) * 32
            access.writeBytes(base, [UInt8](repeating: 0, count: 32))
            access.writeUInt64(base, subscription.userData)
            access.writeUInt16(base + 8, 0)
            access.writeBytes(base + 10, [subscription.tag])
            if subscription.tag != 0 { access.writeUInt64(base + 16, 1) }
        }
        access.writeUInt32(resultPointer, UInt32(ready.count))
        return WasmStandardStreams.success
    }
}

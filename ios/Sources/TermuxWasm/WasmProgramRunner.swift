import Foundation
@_spi(Fuzzing) import WasmKit
import WasmKitWASI
import WASI
import SystemPackage
import TermuxShell

public final class WasmProgramRunner: ProgramRunner {
    public let threadStackSize: Int
    public let interpreterStackSize: Int
    public let memoryLimit: Int
    private let cache: WasmModuleCache

    public init(threadStackSize: Int = 16 << 20, interpreterStackSize: Int = 8 << 20, memoryLimit: Int = 1 << 30, cacheCapacity: Int = 3) {
        self.threadStackSize = threadStackSize
        self.interpreterStackSize = interpreterStackSize
        self.memoryLimit = memoryLimit
        self.cache = WasmModuleCache(capacity: cacheCapacity)
    }

    private final class Execution: @unchecked Sendable {
        let runner: WasmProgramRunner
        let module: Module
        let context: CommandContext
        var status: Int32 = 1

        init(runner: WasmProgramRunner, module: Module, context: CommandContext) {
            self.runner = runner
            self.module = module
            self.context = context
        }
    }

    public func run(programAt path: String, context: CommandContext) -> Int32 {
        let module: Module
        switch cache.module(at: path) {
        case .success(let loaded):
            module = loaded
        case .failure(.component):
            context.stderr.writeLine("\(context.name): WebAssembly components (WASI preview 2) are not supported")
            return 126
        case .failure(.unreadable):
            context.stderr.writeLine("\(context.name): Permission denied")
            return 126
        case .failure(.invalid(let message)):
            context.stderr.writeLine("\(context.name): not a valid WebAssembly program: \(message)")
            return 126
        }
        let execution = Execution(runner: self, module: module, context: context)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            execution.status = execution.runner.execute(execution.module, context: execution.context)
            finished.signal()
        }
        thread.stackSize = threadStackSize
        thread.start()
        finished.wait()
        context.stdout.flush()
        context.stderr.flush()
        return execution.status
    }

    private func standardDescriptor(terminal: Bool, reading: Bool, opened: inout [FileDescriptor]) -> FileDescriptor {
        if terminal {
            let descriptor = open("/dev/null", O_RDWR)
            if descriptor >= 0 {
                let fileDescriptor = FileDescriptor(rawValue: descriptor)
                opened.append(fileDescriptor)
                return fileDescriptor
            }
        } else {
            var ends: [Int32] = [-1, -1]
            if pipe(&ends) == 0 {
                let kept = reading ? ends[0] : ends[1]
                close(reading ? ends[1] : ends[0])
                let fileDescriptor = FileDescriptor(rawValue: kept)
                opened.append(fileDescriptor)
                return fileDescriptor
            }
        }
        if reading { return .standardInput }
        return .standardOutput
    }

    private func preopens(for context: CommandContext) -> [String: String] {
        var result: [String: String] = [:]
        func add(_ guestPath: String, _ hostPath: String?) {
            guard let hostPath = hostPath, !hostPath.isEmpty else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            if result[guestPath] == nil { result[guestPath] = hostPath }
        }
        add(".", context.currentDirectory)
        add(context.homeDirectory, context.homeDirectory)
        if let prefix = context.environment["PREFIX"] { add(ShellPath.normalize(prefix), ShellPath.normalize(prefix)) }
        if let temporary = context.environment["TMPDIR"] { add(ShellPath.normalize(temporary), ShellPath.normalize(temporary)) }
        return result
    }

    private func execute(_ module: Module, context: CommandContext) -> Int32 {
        let name = context.name
        let engine = Engine(configuration: EngineConfiguration(stackSize: interpreterStackSize))
        let store = Store(engine: engine)
        let limiter = WasmMemoryLimiter(maximumBytes: memoryLimit)
        store.resourceLimiter = limiter
        var openedDescriptors: [FileDescriptor] = []
        defer { for descriptor in openedDescriptors { try? descriptor.close() } }
        let standardInput = standardDescriptor(terminal: context.stdin.isTerminal, reading: true, opened: &openedDescriptors)
        let standardOutput = standardDescriptor(terminal: context.stdout.isTerminal, reading: false, opened: &openedDescriptors)
        let standardError = standardDescriptor(terminal: context.stderr.isTerminal, reading: false, opened: &openedDescriptors)
        let directories = preopens(for: context)
        let wasi: WASIBridgeToHost
        do {
            wasi = try WASIBridgeToHost(args: context.argumentVector, environment: context.environment, preopens: directories,
                                        stdin: standardInput, stdout: standardOutput, stderr: standardError)
        } catch {
            context.stderr.writeLine("\(name): \(error)")
            return 1
        }
        let streams = WasmStandardStreams(context: context, limiter: limiter)
        let openCounter = WasmOpenCounter()
        let currentDirectoryDescriptor = descriptor(ofPreopen: ".", in: wasi, count: directories.count)
        var imports = Imports()
        var defined: Set<String> = []
        for (moduleName, hostModule) in wasi.wasiHostModules {
            for (functionName, function) in hostModule.functions {
                let implementation = function.implementation
                let directoryArguments = WasmProgramRunner.directoryArgumentIndices[functionName] ?? []
                let body: (Caller, [Value]) throws -> [Value] = { caller, originalArguments in
                    var arguments = originalArguments
                    if let currentDirectoryDescriptor = currentDirectoryDescriptor {
                        for index in directoryArguments where index < arguments.count && arguments[index] == .i32(WasmProgramRunner.currentDirectoryAlias) {
                            arguments[index] = .i32(currentDirectoryDescriptor)
                        }
                    }
                    if context.isCancelled { throw WasmProgramInterruption() }
                    guard case .memory(let memory)? = caller.instance?.export("memory") else {
                        throw WASIError(description: "Missing required \"memory\" export")
                    }
                    if let result = try streams.handle(functionName, memory: memory, arguments: arguments) { return result }
                    let result = try implementation(memory, arguments)
                    if functionName == "path_open" && result == [.i32(0)] { openCounter.increment() }
                    return result
                }
                imports.define(module: moduleName, name: functionName, Function(store: store, type: function.type, body: body))
                defined.insert(WasmCompatibilityImports.key(module: moduleName, name: functionName))
            }
        }
        WasmCompatibilityImports.defineMissing(for: module, defined: defined, imports: &imports, store: store,
                                               context: context, limiter: limiter)
        defer { closeGuestDescriptors(wasi, count: directories.count + openCounter.value) }
        do {
            let instance = try module.instantiate(store: store, imports: imports)
            let code = try wasi.start(instance)
            return Int32(truncatingIfNeeded: code)
        } catch is WasmProgramInterruption {
            return 130
        } catch let trap as Trap {
            if context.isCancelled { return 130 }
            var message = trap.description
            if message.hasPrefix("Trap: ") { message = String(message.dropFirst(6)) }
            context.stderr.writeLine("\(name): WebAssembly trap: \(message)")
            return 134
        } catch {
            if context.isCancelled { return 130 }
            context.stderr.writeLine("\(name): \(error)")
            return 1
        }
    }

    static let currentDirectoryAlias = UInt32(bitPattern: -2)

    static let directoryArgumentIndices: [String: [Int]] = [
        "path_create_directory": [0], "path_filestat_get": [0], "path_filestat_set_times": [0], "path_link": [0, 4],
        "path_open": [0], "path_readlink": [0], "path_remove_directory": [0], "path_rename": [0, 3], "path_symlink": [2],
        "path_unlink_file": [0],
    ]

    private func descriptor(ofPreopen guestPath: String, in wasi: WASIBridgeToHost, count: Int) -> UInt32? {
        guard let functions = wasi.wasiHostModules["wasi_snapshot_preview1"]?.functions,
              let prestat = functions["fd_prestat_get"], let directoryName = functions["fd_prestat_dir_name"] else { return nil }
        let memory = WasmScratchMemory(size: 4096)
        for descriptor in UInt32(3)..<UInt32(3 + count) {
            guard (try? prestat.implementation(memory, [.i32(descriptor), .i32(0)])) == [.i32(0)] else { continue }
            let length = memory.readUInt32(at: 4)
            guard length > 0, length < 4000,
                  (try? directoryName.implementation(memory, [.i32(descriptor), .i32(16), .i32(length)])) == [.i32(0)] else { continue }
            if memory.string(at: 16, length: Int(length)) == guestPath { return descriptor }
        }
        return nil
    }

    private func closeGuestDescriptors(_ wasi: WASIBridgeToHost, count: Int) {
        guard let close = wasi.wasiHostModules["wasi_snapshot_preview1"]?.functions["fd_close"] else { return }
        let memory = WasmDetachedMemory()
        for descriptor in 3..<(3 + max(0, count)) {
            _ = try? close.implementation(memory, [.i32(UInt32(descriptor))])
        }
    }
}

final class WasmOpenCounter {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class WasmScratchMemory: GuestMemory {
    private var storage: [UInt8]

    init(size: Int) {
        storage = [UInt8](repeating: 0, count: size)
    }

    func withUnsafeMutableBufferPointer<T>(offset: UInt, count: Int, _ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        precondition(Int(offset) + count <= storage.count)
        return try storage.withUnsafeMutableBytes { buffer in
            try body(UnsafeMutableRawBufferPointer(rebasing: buffer[Int(offset)..<(Int(offset) + count)]))
        }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(storage[offset + $1]) << (8 * UInt32($1)) }
    }

    func string(at offset: Int, length: Int) -> String {
        String(decoding: storage[offset..<(offset + length)], as: UTF8.self)
    }
}

struct WasmDetachedMemory: GuestMemory {
    func withUnsafeMutableBufferPointer<T>(offset: UInt, count: Int, _ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        try body(UnsafeMutableRawBufferPointer(start: nil, count: 0))
    }
}

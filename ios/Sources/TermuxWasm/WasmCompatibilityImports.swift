import Foundation
import WasmKit
import TermuxShell

enum WasmCompatibilityImports {
    static func key(module: String, name: String) -> String { module + "\u{0}" + name }

    static func defineMissing(for module: Module, defined: Set<String>, imports: inout Imports, store: Store,
                              context: CommandContext, limiter: WasmMemoryLimiter) {
        var defined = defined
        for item in module.imports {
            guard case .function(let typeIndex) = item.descriptor, Int(typeIndex) < module.types.count else { continue }
            let importKey = key(module: item.module, name: item.name)
            if defined.contains(importKey) { continue }
            let type = module.types[Int(typeIndex)]
            guard let defaults = defaultResults(for: type) else { continue }
            let body = stub(named: item.name, type: type, defaults: defaults, context: context, limiter: limiter)
            imports.define(module: item.module, name: item.name, Function(store: store, type: type, body: body))
            defined.insert(importKey)
        }
    }

    static func defaultResults(for type: FunctionType) -> [Value]? {
        var values: [Value] = []
        for result in type.results {
            switch result {
            case .i32: values.append(.i32(UInt32(bitPattern: -1)))
            case .i64: values.append(.i64(0))
            case .f32: values.append(.f32(0))
            case .f64: values.append(.f64(0))
            case .ref(let referenceType): values.append(.ref(referenceType == .funcRef ? .function(nil) : .extern(nil)))
            case .v128: return nil
            }
        }
        return values
    }

    private static func stub(named name: String, type: FunctionType, defaults: [Value], context: CommandContext,
                             limiter: WasmMemoryLimiter) -> (Caller, [Value]) throws -> [Value] {
        let pointerPair = FunctionType(parameters: [.i32, .i32], results: [.i32])
        switch name {
        case "ashell_getcwd" where type == pointerPair:
            return { caller, arguments in
                if context.isCancelled { throw WasmProgramInterruption() }
                guard case .memory(let memory)? = caller.instance?.export("memory") else { return [.i32(0)] }
                let access = WasmGuestMemoryAccess(memory: memory, limiter: limiter)
                let bytes = Array(context.currentDirectory.utf8) + [0]
                let pointer = arguments[0].i32
                guard UInt64(bytes.count) <= UInt64(arguments[1].i32), access.writeBytes(pointer, bytes) else { return [.i32(0)] }
                return [.i32(pointer)]
            }
        case "ashell_chdir", "ashell_getenv":
            let results = type.results == [.i32] ? [Value.i32(0)] : defaults
            return { _, _ in
                if context.isCancelled { throw WasmProgramInterruption() }
                return results
            }
        default:
            return { _, _ in
                if context.isCancelled { throw WasmProgramInterruption() }
                return defaults
            }
        }
    }
}

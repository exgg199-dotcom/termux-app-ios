import Foundation

struct WasmProgramInterruption: Error, CustomStringConvertible {
    var description: String { "interrupted" }
}

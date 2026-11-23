import Foundation

public protocol ProgramRunner: AnyObject {
    func run(programAt path: String, context: CommandContext) -> Int32
}

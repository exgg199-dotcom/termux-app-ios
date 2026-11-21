// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermuxIOS",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TermuxTerminal", targets: ["TermuxTerminal"]),
        .library(name: "TermuxShell", targets: ["TermuxShell"]),
    ],
    targets: [
        .target(name: "TermuxTerminal", path: "Sources/TermuxTerminal"),
        .target(name: "TermuxShell", dependencies: ["TermuxTerminal"], path: "Sources/TermuxShell"),
        .testTarget(name: "TermuxTerminalTests", dependencies: ["TermuxTerminal"], path: "Tests/TermuxTerminalTests"),
        .testTarget(name: "TermuxShellTests", dependencies: ["TermuxShell"], path: "Tests/TermuxShellTests"),
    ]
)

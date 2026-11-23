// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermuxIOS",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TermuxTerminal", targets: ["TermuxTerminal"]),
        .library(name: "TermuxShell", targets: ["TermuxShell"]),
        .library(name: "TermuxWasm", targets: ["TermuxWasm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftwasm/WasmKit.git", .upToNextMinor(from: "0.2.2")),
        .package(url: "https://github.com/apple/swift-system.git", "1.5.0"..<"1.7.0"),
    ],
    targets: [
        .target(name: "TermuxTerminal", path: "Sources/TermuxTerminal"),
        .target(name: "TermuxShell", dependencies: ["TermuxTerminal"], path: "Sources/TermuxShell"),
        .target(
            name: "TermuxWasm",
            dependencies: [
                "TermuxShell",
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                .product(name: "WASI", package: "WasmKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/TermuxWasm"
        ),
        .testTarget(name: "TermuxTerminalTests", dependencies: ["TermuxTerminal"], path: "Tests/TermuxTerminalTests"),
        .testTarget(name: "TermuxShellTests", dependencies: ["TermuxShell"], path: "Tests/TermuxShellTests"),
        .testTarget(
            name: "TermuxWasmTests",
            dependencies: ["TermuxWasm", "TermuxShell", .product(name: "WAT", package: "WasmKit")],
            path: "Tests/TermuxWasmTests"
        ),
    ]
)

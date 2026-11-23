# Plan: `pkg` / `apt` for Termux for iOS, using WebAssembly (WASI) packages

## 0. What I checked

- **The repo today.**
  - `pkg`, `apt` and `apt-get` are a single stub in `ios/Sources/TermuxShell/Commands/ShellBuiltins.swift` (lines 336-348). It prints "package management is not available on iOS" and exits 1. `Tests/TermuxShellTests/BuiltinCommandTests.swift` `testPkgExplains` checks that stub.
  - `ShellInterpreter.runCommand` looks in the builtin registry first, then `findScript` (searches `PATH`), then `runScript`. `runScript` rejects ELF and Mach-O files and anything that is not text. Text files run as sh scripts.
  - The default `PATH` is `$HOME/bin`. Tab completion already scans `PATH`.
  - `BuiltinShellBackend` runs commands on a serial `DispatchQueue`. Ctrl-C (`0x03`) calls `CancellationToken.cancel()`. `TerminalInputStream` gives cooked, line-buffered input with echo. There is no raw mode.
  - The app creates one `BuiltinShellBackend` per session in `App/Sources/App/SessionManager.swift:71`. `TermuxPaths` is in `App/Sources/Settings/TermuxProperties.swift`: `$HOME` is `Documents/home`, and `UIFileSharingEnabled` is on.
- **WasmKit** (`https://github.com/swiftwasm/WasmKit.git`, MIT, pure Swift plus a small C target, SPM only).
  - Tags 0.3.0, 0.3.1, 0.4.x and 0.5.0 need `swift-tools-version:6.3` and iOS 18 / macOS 15. **They cannot be used** (Linux has Swift 6.0.3; the app targets iOS 15).
  - **0.2.2** (latest 0.2.x) uses `swift-tools-version:6.0` and `platforms: [.macOS(.v10_13), .iOS(.v12)]`. Its products include `WasmKit`, `WasmKitWASI`, `WASI` and `WAT`. It depends on swift-argument-parser (from 1.5.1) and swift-system (from 1.5.0).
  - swift-system 1.7.0 and later need tools 6.1/6.2, so it must be pinned to `"1.5.0"..<"1.7.0"` (1.6.x uses tools 5.9).
  - 0.2.2 API:
    - `parseWasm(bytes:)` / `parseWasm(filePath:)`, `Engine(configuration:)`, `EngineConfiguration(stackSize:)`, `Store(engine:)`, `store.resourceLimiter`, `Imports.define(module:name:_:)`.
    - `Function(store:type:body:)`, `module.imports: [Import]` with `.function(TypeIndex)`, `module.types`.
    - `WASIBridgeToHost(args:environment:preopens:stdin:stdout:stderr:...)` (the stdio arguments are `SystemPackage.FileDescriptor`).
    - `wasi.wasiHostModules: [String: WASIHostModule]`, `wasi.start(instance) -> UInt32`.
    - `Memory.withUnsafeMutableBufferPointer(offset:count:_:)`. It has **no bounds check**, and there is no public memory size.
    - `ResourceLimiter.limitMemoryGrowth(to:)`, which is called on the initial allocation and on every grow.
    - `Trap: Error, CustomStringConvertible`.
    - `WASIExitCode` has no public init, so we cannot throw it ourselves.
    - `poll_oneoff`, `sched_yield`, `proc_raise` and `sock_*` are stubs that report "unimplemented".
    - The engine has no way to interrupt execution (the interceptor only works in debug builds).
- **Package binaries I downloaded.** I read each file's import section and computed sha256. All are plain `wasi_snapshot_preview1` core modules unless noted:

| Package | URL | Size | sha256 | Imports outside WASI |
|---|---|---|---|---|
| quickjs 0.10.1 (`qjs`) | https://github.com/quickjs-ng/quickjs/releases/download/v0.10.1/qjs-wasi.wasm | 1404090 | 7612b78d07b227c525b5ebbf36d99346a47e0d003cefedf78603464f45f06a7c | none |
| quickjs 0.18.0 (latest) | https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/qjs-wasi.wasm | 1571399 | 2c218412cb8b17e46ee91bea7556ec38f5b9b6bd6312fddd3ceeed14aa71eaaa | not inspected |
| python 3.12.0 (Wasm Labs, stdlib embedded) | https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python%2F3.12.0%2B20231211-040d5a6/python-3.12.0.wasm | 26267204 | e5dc5a398b07b54ea8fdb503bf68fb583d533f10ec3f930963e02b9505f7a763 | none (uses poll_oneoff, sched_yield, sock_*) |
| ruby 3.2.2 (Wasm Labs) | https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/ruby%2F3.2.2%2B20230714-11be424/ruby-3.2.2.wasm | 24470606 | 8b4abc0da1cfca2bc6d04c9b4e89ac6cd52340e020c3bf974fb6139b8195d8ac | none |
| php-cgi 8.2.6 (Wasm Labs) | https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/php%2F8.2.6%2B20230714-11be424/php-cgi-8.2.6.wasm | 13164411 | edb29de7cd80597292670499846db56929af1166459c4a776ef606aef357c93b | none |
| xz (a-Shell) | https://github.com/holzschu/a-Shell-commands/releases/download/0.1/xz.wasm | 196301 | b3c7dc3ec1fe4e4370796c2f6e341d1da0edb99582ab15ce3229ce3575ef81df | none |
| lzmadec (a-Shell) | https://github.com/holzschu/a-Shell-commands/releases/download/0.1/lzmadec.wasm | 61872 | 77bf562bdbee30e4c019adaf3bd1d4931f14b952dfbc3e159ff069d121a63d45 | none |
| unzip (a-Shell) | https://github.com/holzschu/a-Shell-commands/releases/download/0.1/unzip.wasm | 196161 | eb864533fc3521c67f147eb911194a03c02b5e592465d41210e5dcb533eae33c | none |
| zip (a-Shell) | https://github.com/holzschu/a-Shell-commands/releases/download/0.1/zip.wasm | 262217 | f5fd0a5551e1dd4751ef2f2683b5cb140aa437378147538ed3d6f560183d3561 | `ashell_system` |
| sqlite3 (a-Shell) | https://github.com/holzschu/a-Shell-commands/releases/download/0.1/sqlite3.wasm | 926553 | 8766845186c9977f68939097b2b60e7ae125230a09cfbff5322854c741d45aed | `ashell_system`, `ashell_chdir`, `ashell_getcwd` |
| file (a-Shell) | https://github.com/holzschu/a-Shell-commands/releases/download/0.1/file.wasm | 495485 | 238edcb57f04d128e0684e5281e7b9aba5b053733865d10bd4948cb5e4e9bd42 | none (may need a magic database; optional) |

  - The `php-8.2.6.wasm` (CLI) asset returns 404. Only `php-cgi` exists.
  - The a-Shell binaries put the non-standard `ashell_*` functions in the `wasi_snapshot_preview1` namespace. I could not read their exact signatures, so the runner must stub them using the function types in the module.

## 1. Decision and rationale

**Main approach: (a) WASI preview1 WebAssembly packages, run in-process by WasmKit 0.2.2 (an interpreter, no JIT), managed by a Swift `pkg`/`apt` front end with a JSON index and sha256 checks.**

Why:
- It is the only option that fits all constraints:
  - iOS allows interpreting downloaded bytecode without JIT or exec.
  - It uses SPM only and supports iOS 12+.
  - It builds and tests on Linux, which keeps the 248 existing tests and lets new runtime tests run on Linux.
  - Its MIT license is compatible with the repo's GPLv3.
- Real-world WASI builds already exist: Python, Ruby, PHP, QuickJS, SQLite, xz, zip and unzip, all verified above.

Options I rejected:
- **(b) iSH, x86 user-mode emulation with Alpine `apk`.** It would give thousands of real packages, and its GPL licence matches Termux's GPLv3. But:
  - It needs meson, ninja, clang/LLD from Homebrew, git submodules, a hand-maintained Xcode project with custom build phases and assembly "gadgets". It cannot be an SPM dependency, cannot be tested on Linux in this setup, and would mean a second filesystem and kernel emulator inside the app.
  - The effort is weeks of work with a high risk of CI failure, for a user with no Mac.
  - Keep it as a possible future, separate `TerminalBackend`, not part of this plan.
- **(c) Script-only packages.** These are cheap, so the index format supports them as files with inline `text` content. They run through the existing sh interpreter. They are a complement, not the main approach.

**What users must be told.** This goes in the motd, `pkg help`, the "Unable to locate package" hint and the README:
- Real Termux packages (packages.termux.dev) are Android/Linux aarch64 programs. iOS cannot run them, and never will without a jailbreak.
- `pkg` installs a curated set of **WebAssembly** command-line programs (architecture `wasm32`). They run inside the app's interpreter and are about 10-50x slower than native. Large runtimes like Python take a few seconds to start.
- Limits of these programs:
  - They cannot start other programs (no `os.system` or subprocess).
  - They have no network sockets (WASI preview1 has none), so `pip install` and `gem install` from the network do not work.
  - They have no threads and no full-screen or raw-mode TUI (vim, htop). Input is line-based.
  - They can only reach files under `$HOME`, `$PREFIX`, `$TMPDIR` and the current directory.
  - Ctrl-C stops a program at its next I/O call, but cannot interrupt a pure CPU loop.

## 2. Files to create and modify

Code style: English, no comments, no abbreviations in new identifiers. Use the existing 4-space style.

### 2.1 TermuxShell (no new dependencies; must stay pure Foundation and Linux-buildable)

**Modify `ios/Sources/TermuxShell/ShellInterpreter.swift`**

- Add:
  ```swift
  public protocol ProgramRunner: AnyObject {
      func run(programAt path: String, context: CommandContext) -> Int32
  }
  ```
  You may put this in a new file `ProgramRunner.swift` next to it instead.
- Add `public var programRunner: ProgramRunner?`, guarded by `lock` like the other state. `subshell()` copies it to the child.
- In `findScript`:
  - With a slash in the name: accept a file that is executable, or whose name ends in `.sh` or `.wasm`.
  - Without a slash: for each `PATH` entry, try `name`, then `name + ".wasm"`. This follows a-Shell's convention, so users can drop `foo.wasm` into `~/bin`.
- In `runScript`, check the header before the ELF/Mach-O and binary rejection:
  - Add `static let webAssemblyMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]`.
  - If `bytes.starts(with: webAssemblyMagic)` and `programRunner` is set, build a `CommandContext` (same construction as in `runCommand`, using the current environment) and return `runner.run(programAt: path, context:)`.
  - If no runner is set, print `"\(shellName): \(name): cannot execute WebAssembly program: no WebAssembly runtime in this build"` and return 126.
  - Make `runScript` take the command environment, so that `FOO=1 prog` passes `FOO` through. Today it doesn't; thread `commandEnvironment` from `runCommand`.
- Change the ELF message to: `cannot execute binary file: native Linux/Android programs cannot run on iOS (install WebAssembly packages with 'pkg install')`.
- Leave the default `PATH` (`home + "/bin"`) unchanged. The app passes `PATH` and `PREFIX`.

**Modify `ios/Sources/TermuxShell/BuiltinShellBackend.swift`**

- Change the init to `public init(homeDirectory: URL, environment: [String: String] = [:], programRunner: ProgramRunner? = nil)` and set `interpreter.programRunner`.
- Update the `welcome` text in Termux style, keeping "Welcome to Termux". The text says that packages are WebAssembly programs, followed by:
  ```
  Working with packages:
   - Search packages:   pkg search <query>
   - Install a package: pkg install <package>
   - Upgrade packages:  pkg upgrade
  ```

**Modify `ios/Sources/TermuxShell/ShellCommand.swift`**

`CommandRegistry.standard()` also calls `PackageCommands.register(r)`.

**Modify `ios/Sources/TermuxShell/Commands/ShellBuiltins.swift`**

- Delete `packageMessage` and the `pkg`, `apt` and `apt-get` registrations.
- Update the `help` header text. It currently says iOS does not allow running native programs; add a line saying `pkg install` adds WebAssembly programs.

**Create `ios/Sources/TermuxShell/Packages/`**

`PackageIndex.swift` (Codable models):
```swift
public struct PackageIndex: Codable, Equatable {
    public var format: Int
    public var name: String
    public var packages: [PackageRecord]
}
public struct PackageRecord: Codable, Equatable {
    public var name: String
    public var version: String
    public var architecture: String?
    public var description: String
    public var homepage: String?
    public var license: String?
    public var depends: [String]?
    public var provides: [String]?
    public var files: [PackageFile]
    public var commands: [String: String]
    public var notes: String?
    public var downloadSize: Int64 { get }
}
public struct PackageFile: Codable, Equatable {
    public var path: String
    public var urls: [String]?
    public var sha256: String?
    public var size: Int64?
    public var text: String?
    public var mode: String?
}
public struct InstalledPackage: Codable, Equatable {
    public var name: String
    public var version: String
    public var description: String
    public var files: [String]
    public var commands: [String]
    public var installedSize: Int64
    public var installationDate: Date
}
public struct PackageStatus: Codable, Equatable {
    public var format: Int
    public var packages: [String: InstalledPackage]
}
```
- `architecture` defaults to `"wasm32"`.
- `commands` maps a command name to a path relative to `$PREFIX`.
- In `PackageFile`, `path` is relative to `$PREFIX` and must not contain `..` or start with `/`; validate this. `mode` is an octal string, default `"0644"` (`"0755"` for files referenced by `commands`).
- Dates are encoded as ISO 8601.

`PackageLayout.swift`:
```swift
public struct PackageLayout {
    public let prefix: String
    public init(prefix: String)
    public var binDirectory: String
    public var webAssemblyDirectory: String
    public var configurationDirectory: String
    public var sourcesFile: String
    public var stateDirectory: String
    public var statusFile: String
    public var listsDirectory: String
    public var archivesDirectory: String
    public var lockFile: String
    public func listFile(for source: URL) -> String
    public func createDirectories() throws
    public static let defaultSource: String
}
```
- `binDirectory` is `prefix/bin`.
- `webAssemblyDirectory` is `prefix/libexec/wasm`.
- `configurationDirectory` is `prefix/etc/pkg`.
- `sourcesFile` is `prefix/etc/pkg/sources.list`: one index URL per line; `#` starts a comment.
- `stateDirectory` is `prefix/var/lib/pkg`; `statusFile` is `status.json` inside it.
- `listsDirectory` is `prefix/var/lib/pkg/lists`.
- `archivesDirectory` is `prefix/var/cache/pkg/archives`.
- `lockFile` is `prefix/var/lib/pkg/lock`.
- `listFile(for:)` returns the lists directory plus the URL with non-alphanumerics mapped to `_`, plus `.json` (like apt's lists).
- `defaultSource` is `"https://raw.githubusercontent.com/exgg199-dotcom/termux-app-ios/master/packages/index.json"`.

`PackageFetcher.swift`:
```swift
public enum PackageFetchError: Error, Equatable { case cancelled, failed(String), httpStatus(Int) }
public protocol PackageFetcher: AnyObject {
    func fetch(_ url: URL, to destination: String, cancellation: CancellationToken,
               progress: @escaping (Int64, Int64?) -> Void) -> Result<Int64, PackageFetchError>
}
public final class URLSessionPackageFetcher: NSObject, PackageFetcher
```
- Handle `file://` URLs by copying the file.
- For https, use a `URLSession` data delegate that streams to a `FileHandle`. Poll `cancellation` every 0.1 s and call `task.cancel()` on Ctrl-C, the same pattern as `NetworkCommands.fetch`. Follow redirects, because GitHub release assets redirect.
- Use `#if canImport(FoundationNetworking)`.

`PackageVersion.swift`: `public enum PackageVersion { public static func compare(_ left: String, _ right: String) -> ComparisonResult }`. This is a simplified Debian ordering: split into alternating digit and non-digit runs, compare digit runs numerically and other runs lexically, with `~` sorting lowest.

`PackageChecksum.swift`: `public enum PackageChecksum { public static func sha256(fileAtPath path: String) -> String? }`. Use CryptoKit (`#if canImport(CryptoKit)`, streaming in 1 MB chunks) on Apple platforms; otherwise use `Hashing.hex(Hashing.sha256(bytes))`.

`PackageDatabase.swift`: `public final class PackageDatabase { init(layout:); func load() -> PackageStatus; func save(_:) throws }`. Write atomically.

`PackageLock.swift`: `final class PackageLock { init?(path: String) }` using `open(O_CREAT|O_RDWR)` + `flock(LOCK_EX|LOCK_NB)`. `deinit` unlocks and closes. If the lock is taken, print `E: Could not get lock <path>. It is held by another session.` and exit 100.

`PackageManager.swift` (the core; all output goes through the `CommandContext` streams):
```swift
public final class PackageManager {
    public static var bundledIndexURL: URL?
    public init(layout: PackageLayout, fetcher: PackageFetcher = URLSessionPackageFetcher(), bundledIndexURL: URL? = PackageManager.bundledIndexURL)
    public func sources() -> [URL]
    public func availablePackages() -> [PackageRecord]
    public func installedPackages() -> [InstalledPackage]
    public func update(_ context: CommandContext) -> Int32
    public func install(_ names: [String], reinstall: Bool, context: CommandContext) -> Int32
    public func remove(_ names: [String], context: CommandContext) -> Int32
    public func upgrade(_ context: CommandContext) -> Int32
    public func listAvailable(_ context: CommandContext) -> Int32
    public func listInstalled(_ context: CommandContext) -> Int32
    public func listUpgradable(_ context: CommandContext) -> Int32
    public func search(_ patterns: [String], context: CommandContext) -> Int32
    public func show(_ names: [String], context: CommandContext) -> Int32
    public func files(_ names: [String], context: CommandContext) -> Int32
    public func clean(_ context: CommandContext) -> Int32
    func resolve(_ names: [String], available: [String: PackageRecord]) -> Result<[PackageRecord], PackageResolutionError>
}
```

`PackageFormat.swift`: apt-style decimal sizes (`12.3 kB`, `26.3 MB`, `B` under 1000) and a transfer rate (`3,283 kB/s`).

`ios/Sources/TermuxShell/Commands/PackageCommands.swift`:
- `enum PackageCommands { static func register(_ r: CommandRegistry) }` registers `pkg`, `apt`, `apt-get`, `apt-cache` and `dpkg` (only `-l` and `-L`).
- The prefix is `context.environment["PREFIX"]`, or else `ShellPath.normalize(home + "/../usr")`.
- Each command builds `PackageManager(layout: PackageLayout(prefix:))`.

### 2.2 New target TermuxWasm (`ios/Sources/TermuxWasm/`)

`WasmProgramRunner.swift`:
```swift
public final class WasmProgramRunner: ProgramRunner {
    public init(threadStackSize: Int = 16 << 20, interpreterStackSize: Int = 8 << 20, memoryLimit: Int = 1 << 30, cacheCapacity: Int = 3)
    public func run(programAt path: String, context: CommandContext) -> Int32
}
```

How `run` works:

1. Load the module through `WasmModuleCache`, keyed by path, size and mtime.
   - If parsing fails: `"<argv0>: not a valid WebAssembly program: <error>"`, return 126.
   - If the module is a component (magic followed by version bytes other than `01 00 00 00`): `"<argv0>: WebAssembly components (WASI preview 2) are not supported"`, return 126.
2. Do the work on a `Thread` with `stackSize = threadStackSize`, wait on a `DispatchSemaphore`, and return the status. GCD threads have small stacks.
3. Engine and store: `Engine(configuration: EngineConfiguration(stackSize: interpreterStackSize))`. Create a `Store` and set `store.resourceLimiter = WasmMemoryLimiter(maximumBytes: memoryLimit)`.
4. Preopens, as guest path → host path. Identity mapping means absolute paths the shell shows are valid inside the program:
   - `"."` → `context.currentDirectory`
   - `home` → `home`
   - `PREFIX` → `PREFIX`, if it exists
   - `TMPDIR` → `TMPDIR`
   - Skip any path that does not exist.
5. stdio file descriptors for `WASIBridgeToHost`. These only serve `fd_fdstat_get` / isatty, because reads and writes are intercepted:
   - For a terminal stream, open `/dev/null` (a character device, so programs see a tty).
   - For a non-terminal stream, use one end of a `pipe()`.
   - Close all of them afterwards.
6. Create `WASIBridgeToHost(args: context.argumentVector, environment: context.environment, preopens: ..., stdin: ..., stdout: ..., stderr: ...)`.
7. Linking:
   - Define every WASI host function yourself instead of calling `wasi.link`. Each wrapper:
     - throws `WasmProgramInterruption()` (our own `Error`) if `context.isCancelled`;
     - gets `Memory` from `caller.instance?.export("memory")`;
     - hands the call to `WasmStandardStreams` for `fd_read` on fd 0, `fd_write` on fds 1 and 2, `poll_oneoff` and `sched_yield`;
     - otherwise calls `function.implementation(memory, values)`.
   - Then call `WasmCompatibilityImports.defineMissing(for: module, defined: Set<String>, imports: &imports, store: store, context: context)`.
8. Run it: `let instance = try module.instantiate(store:imports:)`, then `try wasi.start(instance)`, and return `Int32(truncatingIfNeeded: code)`. Errors map as follows:
   - `WasmProgramInterruption` → 130.
   - `Trap` → print `"<argv0>: WebAssembly trap: \(trap)"`, return 134.
   - Anything else → print `"<argv0>: \(error)"`, return 1.
   - Always flush `context.stdout`.

`WasmStandardStreams.swift`: `final class WasmStandardStreams` takes `context`, `limiter`.
- Read and write iovecs, which are pairs of little-endian u32 `(buffer, length)`, using `memory.withUnsafeMutableBufferPointer(offset:count:)`.
- **Every access must be bounds-checked** against `limiter.currentBytes`; on overflow return errno 21 (`EFAULT`).
- `fd_write(1|2)`: copy the bytes to `context.stdout` / `context.stderr`. Return errno 64 (`EPIPE`) if `isClosed`. Write the `nwritten` u32.
- `fd_read(0)`: call `context.stdin.read(maxLength: totalLength)` and scatter the bytes into the iovecs. On `nil`, set `nread = 0`, and if the token is cancelled throw `WasmProgramInterruption`.
- `poll_oneoff`:
  - Subscriptions are 48 bytes: userdata u64 @0, tag u8 @8, clock timeout u64 @24, flags u16 @40.
  - Events are 32 bytes: userdata u64 @0, error u16 @8, type u8 @10.
  - For clock subscriptions, sleep for the smallest timeout using `context.cancellation.sleep(seconds)`, honouring the absolute flag (bit 0) against `clock_time_get`-equivalent `Date`. Throw the interruption if cancelled.
  - Report fd_read and fd_write subscriptions as ready immediately.
  - Write `nevents`.
- `sched_yield`: return 0.

`WasmCompatibilityImports.swift`: for every function import of the module that is not yet defined, create a stub from `module.types[typeIndex]`:
- `ashell_getcwd(pointer, size)`: write the cwd as a NUL-terminated string if it fits and return the pointer, otherwise 0. Only if its type is `(i32, i32) -> i32`.
- `ashell_chdir`: return 0.
- `ashell_getenv`: return 0.
- `ashell_system`: return -1.
- Any other unknown function returns zero for each result type, except an `i32` result, which is -1.
- Imports that are not functions (memory, table, global) are left alone, so instantiation fails with a clear error.

`WasmMemoryLimiter.swift`: `final class WasmMemoryLimiter: ResourceLimiter`. `limitMemoryGrowth(to desired: Int)` returns false if `desired > maximumBytes`, otherwise records `currentBytes = desired` (under a lock) and returns true. `limitTableGrowth` returns true.

`WasmModuleCache.swift`: an LRU of `Module` values, guarded by `NSLock`.

### 2.3 App (`ios/App`)

**`App/Sources/Settings/TermuxProperties.swift`, `TermuxPaths`**
- Add `public let prefixDirectory: URL` and the init `init(documentsDirectory: URL, libraryDirectory: URL? = nil)`.
- `prefixDirectory = (libraryDirectory ?? documentsDirectory.deletingLastPathComponent().appendingPathComponent("Library", isDirectory: true)).appendingPathComponent("usr", isDirectory: true)`.
- `appDefault()` passes the real `.libraryDirectory`.
- So `$PREFIX` is `<container>/Library/usr`: no spaces, not visible in Files (users cannot delete it by accident), and excluded from backup.
- Check that the existing app tests use a unique temporary parent; if not, pass an explicit `libraryDirectory` in the tests.

**`App/Sources/App/Bootstrap.swift`**
- Create `bin`, `etc/pkg`, `libexec/wasm`, `var/lib/pkg/lists`, `var/cache/pkg/archives` and `tmp` under the prefix. This list must match `PackageLayout`.
- Write `sources.list` (`PackageLayout.defaultSource`) if it is missing.
- Set `URLResourceValues.isExcludedFromBackup = true` on the prefix.
- Keep this file Foundation-only; it is compiled into `TermuxAppTests`.
- Rewrite `defaultMotd`. Drop "there is no package manager (no pkg/apt)" and use the Termux wording "Working with packages: pkg search / pkg install / pkg upgrade", plus one honest line: "Packages are WebAssembly programs; Android Termux packages cannot run on iOS."

**`App/Sources/App/TermuxEnvironment.swift`**
- `shellEnvironment()` adds `"PREFIX": paths.prefixDirectory.path`, `"PATH": prefix + "/bin:" + home + "/bin"` and `"TMPDIR": prefix + "/tmp"`.
- Add `let programRunner = WasmProgramRunner()`, a single instance shared across sessions.
- In `bootstrapIfNeeded`, set `PackageManager.bundledIndexURL = Bundle.main.url(forResource: "index", withExtension: "json")`.

**`App/Sources/App/SessionManager.swift`**: pass `programRunner: environment.programRunner` to `BuiltinShellBackend`.

**`App/project.yml`**
- Add the Termux target dependency `- package: TermuxIOS` / `product: TermuxWasm`.
- Add a source entry `- path: ../../packages/index.json` / `buildPhase: resources`.
- `TermuxAppTests` stays as it is (Bootstrap is Foundation-only).

### 2.4 Repository package index

- `packages/index.json` (see section 4).
- `packages/README.md`: the format, how to add a package, and the licences.
- `packages/verify_index.py`: a no-comments Python script. It downloads every URL, compares size and sha256, prints `OK name` or `FAIL name reason`, and exits 1 on any failure.

### 2.5 Docs

- `ios/docs/ARCHITECTURE.md`: add a "Packages" section covering the `TermuxWasm` row, `ProgramRunner`, the new `BuiltinShellBackend` init, the `PREFIX` layout and the limits from section 1.
- `ios/App/README.md`: one line each for prefix and packages.

## 3. Package.swift

```swift
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
        .target(name: "TermuxWasm", dependencies: [
            "TermuxShell",
            .product(name: "WasmKit", package: "WasmKit"),
            .product(name: "WasmKitWASI", package: "WasmKit"),
            .product(name: "WASI", package: "WasmKit"),
            .product(name: "SystemPackage", package: "swift-system"),
        ], path: "Sources/TermuxWasm"),
        .testTarget(name: "TermuxTerminalTests", dependencies: ["TermuxTerminal"], path: "Tests/TermuxTerminalTests"),
        .testTarget(name: "TermuxShellTests", dependencies: ["TermuxShell"], path: "Tests/TermuxShellTests"),
        .testTarget(name: "TermuxWasmTests", dependencies: ["TermuxWasm", "TermuxShell", .product(name: "WAT", package: "WasmKit")], path: "Tests/TermuxWasmTests"),
    ]
)
```

- **The swift-system pin is required.** 1.7+ needs tools 6.1+. Xcode ignores `ios/Package.resolved` for a local package, so the constraint has to be in the manifest. `TermuxWasm` really uses `SystemPackage.FileDescriptor`, so it is not a dead dependency.
- **Never let WasmKit go past 0.2.x.** 0.3+ needs tools 6.3 and iOS 18.
- TermuxShell and TermuxTerminal still have no external dependencies.
- Commit `ios/Package.resolved` after `swift package resolve` on Linux.
- **Phase 0 spike (do this first, alone):**
  - Add only the dependency and an empty `TermuxWasm` file that does `import WasmKit; import WasmKitWASI; import WASI; import SystemPackage`. Run `cd ios && swift build && swift test` with `/opt/swift/usr/bin`.
  - If 0.2.2 fails on Swift 6.0.3, try `exact: "0.2.1"`, then `"0.2.0"`.
  - If none work on Linux, wrap the TermuxWasm target and its test target in `#if !os(Linux)` inside Package.swift (the manifest can do this). TermuxShell is unaffected because it only knows `ProgramRunner`.
  - Push the spike to CI as well, to confirm Xcode on macos-latest compiles WasmKit 0.2.2.

## 4. Package index format and initial package set

The index is `packages/index.json` in this repo. Clients fetch it from `https://raw.githubusercontent.com/exgg199-dotcom/termux-app-ios/master/packages/index.json`.
- This needs the repo to be public. If it is not, `pkg update` falls back to the copy bundled in the app, with a warning (section 5).
- Payloads use the upstream release URLs pinned by sha256. `urls` is an array, so a mirror can be added later: a release `packages-1` in this repo created by a manual workflow, uploaded with `gh release upload`. That is optional and not required for the first iteration.

Example entry:
```json
{
  "format": 1,
  "name": "termux-ios-wasm",
  "packages": [
    {
      "name": "quickjs",
      "version": "0.10.1",
      "architecture": "wasm32",
      "description": "QuickJS-ng JavaScript engine (qjs)",
      "homepage": "https://github.com/quickjs-ng/quickjs",
      "license": "MIT",
      "depends": [],
      "provides": ["qjs"],
      "files": [{"path": "libexec/wasm/quickjs/qjs.wasm",
                 "urls": ["https://github.com/quickjs-ng/quickjs/releases/download/v0.10.1/qjs-wasi.wasm"],
                 "sha256": "7612b78d07b227c525b5ebbf36d99346a47e0d003cefedf78603464f45f06a7c",
                 "size": 1404090, "mode": "0755"}],
      "commands": {"qjs": "libexec/wasm/quickjs/qjs.wasm"}
    }
  ]
}
```

Initial set. Use the URLs, sizes and sha256 values from the table in section 0.

| name | version | commands | file path under $PREFIX | license |
|---|---|---|---|---|
| quickjs | 0.10.1 (try 0.18.0 in the network test; switch if it works) | qjs | libexec/wasm/quickjs/qjs.wasm | MIT |
| python | 3.12.0 | python, python3 | libexec/wasm/python/python.wasm | PSF-2.0 |
| ruby | 3.2.2 | ruby | libexec/wasm/ruby/ruby.wasm | Ruby/BSD-2-Clause |
| php | 8.2.6 | php-cgi | libexec/wasm/php/php-cgi.wasm | PHP-3.01 |
| xz-utils | 5.2 (a-Shell build) | xz, unxz, xzcat (same file; xz picks its mode from argv[0]), lzmadec | libexec/wasm/xz-utils/xz.wasm, lzmadec.wasm | 0BSD/public domain/LGPL parts |
| unzip | 6.0 | unzip | libexec/wasm/unzip/unzip.wasm | Info-ZIP |
| zip | 3.0 | zip | libexec/wasm/zip/zip.wasm | Info-ZIP |
| sqlite | 3 (a-Shell build) | sqlite3 | libexec/wasm/sqlite/sqlite3.wasm | public domain |

- Use the `notes` field to state limits, e.g. for python: "No network: pip cannot download packages. Startup takes a few seconds."
- `file.wasm` is left out until it is checked in the network test.
- **Drop any package that fails the opt-in network test (section 7) rather than shipping it broken.**

## 5. Shell integration

**Lookup.** The app sets `PATH=$PREFIX/bin:$HOME/bin`. Install creates `$PREFIX/bin/<command>` as a **relative symlink** (`../libexec/wasm/<pkg>/<file>`) via `FileManager.createSymbolicLink`.
- `findScript` resolves it, and `runScript` reads the file through the symlink and sees the wasm magic number. argv[0] is the name the user typed, which xz needs.
- Builtins in the registry still take precedence. If a package command clashes with a builtin name, install prints `W: '<command>' is also a built-in command; run the package version as $PREFIX/bin/<command>`.
- `which`, `type`, `command -v` and tab completion already work through `findScript` and the PATH scan.

**Running.** On a terminal, stdin, stdout and stderr are the session streams. In pipelines and redirections they are the pipe or file streams, so `echo 'print(1)' | python -` works.
- The environment is the full exported environment, including `HOME`, `PREFIX`, `PWD`, `TERM`, `COLUMNS` and `LINES`.
- The exit status is the program's `proc_exit` code: 130 after Ctrl-C, 134 on a trap, 126 if the file cannot be run.

**Subcommands.** pkg follows Termux's `pkg` script; apt and apt-get follow apt. Unknown subcommands print the usage and return 1.

| Command | Does |
|---|---|
| `pkg update`, `apt update`, `apt-get update` | Fetch every source in sources.list into lists/ |
| `pkg upgrade` / `up`, `apt upgrade`, `apt full-upgrade` | `update` first, then reinstall each installed package whose index version is newer |
| `pkg install` / `in` / `i`, `apt install [--reinstall] [-y]`, `apt-get install` | Install packages; `-y` is accepted and ignored (we never prompt) |
| `pkg reinstall` / `rei` | Reinstall |
| `pkg uninstall` / `un` / `rem` / `remove` / `rm`, `apt remove`, `apt purge`, `apt-get remove` | Remove packages |
| `apt autoremove` | Prints `0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.` |
| `pkg list-all` / `la`, `apt list` | List available packages |
| `pkg list-installed` / `li`, `apt list --installed` | List installed packages |
| `apt list --upgradable` | List upgradable packages |
| `pkg search` / `se`, `apt search`, `apt-cache search` | Case-insensitive regex over name and description (NSRegularExpression) |
| `pkg show` / `sh`, `apt show`, `apt-cache show` | Show package metadata |
| `pkg files`, `dpkg -L` | List installed files |
| `pkg clean` / `autoclean`, `apt clean` | Empty archives/ |
| `dpkg -l` | List installed packages in dpkg table style |
| `pkg help` | Usage |

**Output texts.**

`update`:
```
Get:1 <url> [12.3 kB]
Fetched 12.3 kB in 0s (45.6 kB/s)
Reading package lists... Done
Building dependency tree... Done
All packages are up to date.
```
The last line is `N packages can be upgraded. Run 'apt list --upgradable' to see them.` when there are upgrades.

On a fetch error:
```
Err:1 <url>
  <message>
W: Some index files failed to download. They have been ignored, or old ones used instead.
```
- Exit 0 if a cached list or the bundled index is usable, otherwise exit 100.
- The bundled index is used when lists/ is empty and the fetch failed. In that case print `W: Using the package list bundled with the app.`

`install`. If no lists are cached, run `update` silently first; this mirrors Termux's automatic update.
```
Reading package lists... Done
Building dependency tree... Done
The following NEW packages will be installed:
  python
0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.
Need to get 26.3 MB of archives.
After this operation, 26.3 MB of additional disk space will be used.
Get:1 <url> python wasm32 3.12.0 [26.3 MB]
Fetched 26.3 MB in 9s (2,918 kB/s)
Selecting previously unselected package python.
Unpacking python (3.12.0) ...
Setting up python (3.12.0) ...
```
- When upgrading, `The following packages will be upgraded:` and `Preparing to unpack ... Unpacking python (3.12.1) over (3.12.0) ...`.
- When nothing needs doing: `python is already the newest version (3.12.0).` followed by the summary line.
- After install, print the package `notes` if there are any.
- **Progress** appears only if `context.stdout.isTerminal`. Rewrite one line with `\r\u{1B}[K` at most every 0.1 s: `<percent>% [<n> <name> <done>/<total> <rate>]`. Clear it before printing `Fetched`.

`remove`:
```
Reading package lists... Done
Building dependency tree... Done
The following packages will be REMOVED:
  python
0 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.
After this operation, 26.3 MB disk space will be freed.
Removing python (3.12.0) ...
```
- Removing a package that is not installed prints `Package 'x' is not installed, so not removed`.
- Refuse to remove a package that another installed package depends on: `E: python is needed by <name>` (exit 100).

`apt list` line format: `python/stable 3.12.0 wasm32`, with ` [installed]` or ` [upgradable from: 3.11]` when relevant. It starts with the `Listing... Done` header.

`search`: `Sorting... Done`, `Full Text Search... Done`, then for each match `name/stable version wasm32[ [installed]]`, the description indented by 2 spaces, and a blank line. Highlight the name with `ANSI.boldGreen` on a terminal.

`show`: these fields, then a blank line:
```
Package: 
Version: 
Architecture: wasm32
Depends: 
Homepage: 
Download-Size: 
Installed-Size: 
License: 
Description: 
```

Errors (exit 100):
- `E: Unable to locate package <name>`. If the name is not in the index, add: `N: Termux for iOS can only install WebAssembly packages. Android Termux packages cannot run on iOS. Run 'pkg list-all' to see what is available.`
- `E: Failed to fetch <url>  <message>`.
- `E: Hash Sum mismatch` with `Hashes of expected file: SHA256:<x>` and `Hashes of received file: SHA256:<y>`.
- `E: Interrupted` (exit 130) after Ctrl-C.

`pkg` with no arguments or `pkg help` prints Termux's usage text (the list in the planning notes: autoclean, clean, files, install, list-all, list-installed, reinstall, search, show, uninstall, upgrade, update), followed by `Packages for Termux for iOS are WebAssembly (wasm32) programs.`

**Install procedure.** Hold the lock for the whole operation.
1. Resolve dependencies depth-first, with a cycle check.
2. Install files by kind:
   - Inline text files: write the text.
   - Downloaded files: fetch into `archives/<name>_<version>_<index>.partial`.
3. For downloaded files, if `size` is given and differs, treat it as a hash mismatch. Check sha256; a missing `sha256` on a downloaded file is an error: `E: <name>: file has no checksum`.
4. Move each file into place: remove the old file, `moveItem`, then `chmod` to `mode`.
5. Create command symlinks.
6. Record `InstalledPackage` (files include the symlinks) and save the status atomically.
7. On any failure, delete what this run created and leave the status unchanged.
8. On upgrade, remove old files that are not in the new file list.

## 6. App bootstrap summary

- Section 2.3 has the details: `$PREFIX = Library/usr`, excluded from backup and not shown in Files.
- `$HOME` stays in `Documents/home`, which Files shows. Users can also put their own `.wasm` files in `~/bin`.
- Bootstrap is idempotent, and if creating the prefix fails it reports through the existing `bootstrapError` path.
- `project.yml` changes: the `TermuxWasm` product and the bundled `packages/index.json` resource.
- No Info.plist changes. All URLs are https.

## 7. Tests

Every test target must run on Linux with `cd ios && swift build && swift test`. The existing 248 tests must keep passing. Replace `testPkgExplains`.

**`Tests/TermuxShellTests/PackageManagerTests.swift`** (subclass `ShellTestCase`).
- Use a `FakePackageFetcher: PackageFetcher` with `[URL: [UInt8]]`, a list of requested URLs, and optional failure or cancellation per URL.
- Set the shell variables `PREFIX=home/usr` and `PATH=$PREFIX/bin:...`.
- Inject the fetcher. Make the injection point testable, e.g. `PackageCommands.fetcherFactory` as an internal static that `@testable` can override, reset in `tearDown`.

Cases:
- `update` writes `lists/…json` and prints `Get:1` and `Reading package lists... Done`.
- A failed fetch with no cache exits 100. With `bundledIndexURL` pointing to a temporary file it exits 0 and prints the warning.
- Install a package made of a script file (`#!/bin/sh` / `echo hello-from-package`, mode 0755, inline `text`, command `hello`). Then `hello` prints `hello-from-package`, `which hello` shows `$PREFIX/bin/hello`, `pkg list-installed` contains `hello/stable 1.0 wasm32 [installed]`, and status.json is written.
- Install a downloaded file with a correct sha256 (computed with `Hashing.sha256` in the test) succeeds. With a wrong sha256 it exits 100, prints `Hash Sum mismatch`, and installs nothing: no bin link, no status entry, no `.partial` left over.
- Installing an unknown package exits 100 with `Unable to locate package` and the iOS hint.
- `depends` are installed in order. A missing dependency is an error.
- Upgrade: index version 1.0 installed, new index 1.1, then `pkg upgrade` installs 1.1 and removes files that are gone. `apt list --upgradable` shows it before the upgrade.
- `remove` deletes files and links. `remove` of a package another one needs is refused.
- `search` uses a regex and shows descriptions. `show` prints the fields. `files` lists the files.
- `PackageVersion.compare`: "1.10" > "1.9", "1.0~rc1" < "1.0", "3.12.0" == "3.12.0".
- Path validation: an index file path containing `..` is rejected.
- The lock: a second `PackageLock` on the same path fails.
- Cancellation: a fetcher that returns `.cancelled` gives exit 130 and `E: Interrupted`.

**`Tests/TermuxShellTests/ProgramRunnerTests.swift`.**
- A `FakeProgramRunner` records the path and argv and returns 42.
- Write a file starting with `\0asm` into `home/bin/tool` (chmod 755) and run `tool a b`: status 42, argv `["tool","a","b"]`.
- `tool.wasm` is found as `tool`.
- `./x.wasm` without the executable bit runs.
- With no runner set: status 126 and the message.
- An environment prefix (`FOO=1 tool`) reaches `context.environment`.

**`Tests/TermuxWasmTests/WasmProgramRunnerTests.swift`.** Build fixtures with `wat2wasm` from `WAT`, write them to a temporary directory, and run them through a `ShellInterpreter` that has `programRunner = WasmProgramRunner()`.
- Hello: `fd_write` to fd 1 with "hello\n"; stdout is "hello\n", status 0.
- Exit code: `proc_exit 3` gives status 3.
- stdin echo: a loop of `fd_read` 0 → `fd_write` 1 until nread is 0. `runCapturing("echo-program", stdin: "abc\n")` returns "abc\n". It also works in a pipeline: `echo hi | echo-program`.
- stderr: `fd_write` 2 ends up in stderr.
- argv: a program that calls `args_sizes_get` and exits with argc. `prog a b` gives 3.
- File access: a program that does `path_open` on fd 3 (the first preopen) with an `"out.txt"` creat flag, then `fd_write`. The test must check which preopen fd maps to `.`; the preopen order is dictionary order, so either make the order deterministic, e.g. by passing `"."` first and checking `fd_prestat_dir_name`, or open via the absolute home preopen.
- Cancellation: a program looping on `fd_write` forever. Cancel a `CancellationToken` after 0.3 s from another thread; status is 130 and the run returns within 2 s.
- Unknown import: a module importing `wasi_snapshot_preview1.ashell_system (param i32) (result i32)` and calling it instantiates and returns -1 as its exit code.
- Out-of-bounds iovec: a `fd_write` with a buffer pointer beyond memory returns errno 21. Check for status ≠ crash, i.e. the program exits with that errno.
- A trap (`unreachable`) gives 134 and "WebAssembly trap".
- A non-wasm file gives 126.

**Opt-in network test** `Tests/TermuxWasmTests/RealPackageTests.swift`. Skip unless `TERMUX_NETWORK_TESTS=1`. It uses the real `packages/index.json` through a `file://` source and the real fetcher, and checks:
- `pkg install quickjs`, then `qjs -e "console.log(6*7)"` gives "42".
- `pkg install python`, then `python3 -c "print(6*7)"` gives "42".
- `ruby -e "puts 6*7"` gives "42".
- `xz --version` exits 0.
- `printf 'select 6*7;' | sqlite3` gives "42".
- `zip` / `unzip` round-trip a file.

The implementer must run this once locally (network is available) and **remove from the index any package that fails**. Record the results in `packages/README.md`.

**CI.**
- `.github/workflows/build-ios.yml`:
  - Keep the job, the `Termux-unsigned-ipa` artifact and the `error.txt` / `build-error` failure path exactly as they are.
  - Add `-skipPackagePluginValidation -skipMacroValidation` to xcodebuild.
  - Add a step before the build, logging into `build.log` so errors reach error.txt:
    ```bash
    set -o pipefail
    xcodebuild -resolvePackageDependencies -project TermuxIOS.xcodeproj -scheme Termux 2>&1 | tee ../../resolve.log
    ```
    Include `resolve.log` in the `grep` and `tail` of the "Collect errors" step.
- Add a job `test-linux` in the same workflow:
  - `runs-on: ubuntu-latest`, `container: swift:6.0.3-jammy`.
  - Steps: checkout, then `cd ios && swift build 2>&1 | tee ../linux.log && swift test 2>&1 | tee -a ../linux.log` with `set -o pipefail`.
  - On failure, upload `linux.log` as artifact `linux-test-error`.
  - It must not be a `needs:` of `build`, so a test failure does not block the IPA.
- New `.github/workflows/verify-packages.yml`: on `workflow_dispatch` and `push` with `paths: ['packages/**']`; `ubuntu-latest`; run `python3 packages/verify_index.py packages/index.json`.

## 8. Risks and reviewer checklist

**Risks**
1. WasmKit 0.2.2 may not compile with Linux Swift 6.0.3 or the newest Xcode in Swift 6 mode. Mitigation: the Phase 0 spike, falling back to 0.2.1/0.2.0, or excluding the target on Linux.
2. Some packages may use wasm features or WASI calls that 0.2.2 lacks (exception handling, threads, `sock_*`). Mitigation: the network test and dropping broken packages.
3. Performance: Python and Ruby start slowly in an interpreter, and a 26 MB parse costs time and memory. Mitigation: the module cache, the Release build (`-O`), and honest notes. The memory limit of 1 GiB guards against jetsam.
4. A CPU-bound loop cannot be interrupted. Ctrl-C only works at the next WASI call. Closing the session leaves the thread running until it finishes or hits I/O. This is documented.
5. `raw.githubusercontent.com` needs a public repo. The bundled index is the fallback, and `sources.list` can be edited.
6. Upstream URLs can disappear. sha256 pins plus `urls` arrays allow a mirror release.
7. `Memory.withUnsafeMutableBufferPointer` has no bounds check. Every intercepted call must check against `WasmMemoryLimiter.currentBytes`.
8. isatty is approximate: stdin opened on `/dev/null` reports a tty. Pipes report as FIFO.
9. Upstream WASI code inherits WasmKit's own (unchecked) memory access. Accept this as a known limit.

**Reviewer checklist**
- [ ] `cd ios && swift build && swift test` on Linux. All earlier tests (248 minus the replaced `testPkgExplains`) plus the new tests pass. There is no network access in the default tests.
- [ ] `Package.swift` has exactly WasmKit `.upToNextMinor(from: "0.2.2")` and swift-system `"1.5.0"..<"1.7.0"`. TermuxShell and TermuxTerminal have no external dependencies. `Package.resolved` is committed.
- [ ] There are no comments in any new Swift or Python code, and no abbreviated identifiers.
- [ ] CI `build-ios.yml` produces `Termux-unsigned-ipa` and still uploads `error.txt` on failure. The `test-linux` job passes.
- [ ] `packages/index.json` parses with `PackageIndex`. `verify_index.py` passes. Every package passed `RealPackageTests` locally.
- [ ] On the phone (sideloaded IPA):
  - [ ] A fresh launch shows the new motd.
  - [ ] `echo $PREFIX` shows `.../Library/usr`.
  - [ ] `pkg update` prints Get/Fetched lines.
  - [ ] `pkg list-all` and `pkg search py` work.
  - [ ] `pkg install quickjs` shows progress, then `qjs -e "console.log(1+1)"` prints 2.
  - [ ] `pkg install python`, then `python3 -c "import sys; print(sys.version)"`, then `python3` REPL line input, then Ctrl-D exits.
  - [ ] `python3 -c "import time; time.sleep(5)"` stops on Ctrl-C and returns 130.
  - [ ] `echo 'print(2)' | python3 -` works.
  - [ ] `cd ~; python3 -c "open('t.txt','w').write('x')"`, then `cat t.txt` shows x and Files shows the file.
  - [ ] `pkg install sqlite`, then `sqlite3 test.db "create table t(a); insert into t values(1); select * from t;"`.
  - [ ] `xz file && unxz file.xz` works.
  - [ ] `pkg remove python` frees the space and `python3` is "command not found".
  - [ ] In airplane mode, `pkg install` gives a clean `E:` message and the bundled list is used.
  - [ ] Two sessions running `pkg install` at once: the second gets the lock error.
  - [ ] `pkg install git` gives "Unable to locate package" and the iOS hint.

---

### Critical Files for Implementation
- /home/user/termux-app-ios/ios/Package.swift
- /home/user/termux-app-ios/ios/Sources/TermuxShell/ShellInterpreter.swift
- /home/user/termux-app-ios/ios/Sources/TermuxShell/Commands/ShellBuiltins.swift (remove stub) and new /home/user/termux-app-ios/ios/Sources/TermuxShell/Packages/PackageManager.swift
- /home/user/termux-app-ios/ios/Sources/TermuxWasm/WasmProgramRunner.swift (new)
- /home/user/termux-app-ios/ios/App/Sources/App/TermuxEnvironment.swift, /home/user/termux-app-ios/ios/App/Sources/App/Bootstrap.swift, /home/user/termux-app-ios/ios/App/project.yml, /home/user/termux-app-ios/.github/workflows/build-ios.yml
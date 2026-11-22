#if !os(iOS)
import Foundation
import TermuxTerminal
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class PTYProcessBackend: TerminalBackend {
    public var onOutput: (([UInt8]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOutput }
        set { lock.lock(); _onOutput = newValue; lock.unlock() }
    }
    public var onExit: ((Int32) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onExit }
        set { lock.lock(); _onExit = newValue; lock.unlock() }
    }
    public var pid: Int32 { lock.lock(); defer { lock.unlock() }; return storedProcessIdentifier }

    public var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return _exitStatus }

    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public let workingDirectory: String

    private let lock = NSLock()
    private var _onOutput: (([UInt8]) -> Void)?
    private var _onExit: ((Int32) -> Void)?
    private var storedProcessIdentifier: Int32 = -1
    private var _exitStatus: Int32?
    private var masterFD: Int32 = -1
    private var started = false
    private let writeQueue = DispatchQueue(label: "com.termux.pty.write")
    private let readerDone = DispatchSemaphore(value: 0)

    public init(executable: String, arguments: [String], environment: [String], workingDirectory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    deinit {
        if masterFD >= 0 { close(masterFD) }
    }

    public func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        do {
            let (fileDescriptor, childProcessIdentifier) = try PTYProcessBackend.createSubprocess(
                executable: executable, arguments: [executable] + arguments, environment: environment,
                workingDirectory: workingDirectory, rows: rows, columns: columns,
                cellWidth: cellWidthPixels, cellHeight: cellHeightPixels)
            lock.lock()
            masterFD = fileDescriptor
            storedProcessIdentifier = childProcessIdentifier
            lock.unlock()
            startReaderThread(fileDescriptor)
            startWaiterThread(childProcessIdentifier)
        } catch {
            let message = "\r\n[Failed to start \(executable): \(error)]\r\n"
            onOutput?(Array(message.utf8))
            lock.lock(); _exitStatus = 1; lock.unlock()
            onExit?(1)
        }
    }

    public func write(_ data: [UInt8]) {
        let fileDescriptor = lock.withLock { masterFD }
        guard fileDescriptor >= 0, !data.isEmpty else { return }
        writeQueue.async {
            var offset = 0
            while offset < data.count {
                let n = data[offset...].withUnsafeBytes { Glue.write(fileDescriptor, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                offset += n
            }
        }
    }

    public func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        let fileDescriptor = lock.withLock { masterFD }
        guard fileDescriptor >= 0 else { return }
        PTYProcessBackend.setWindowSize(fileDescriptor, rows: rows, columns: columns, cellWidth: cellWidthPixels, cellHeight: cellHeightPixels)
    }

    public func terminate() {
        let p = lock.withLock { _exitStatus == nil ? storedProcessIdentifier : -1 }
        if p > 0 { kill(p, SIGKILL) }
    }

    private func startReaderThread(_ fileDescriptor: Int32) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { Glue.read(fileDescriptor, $0.baseAddress, $0.count) }
                if n > 0 {
                    self?.onOutput?(Array(buffer[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            self?.readerDone.signal()
        }
        thread.name = "TermuxPtyReader"
        thread.start()
    }

    private func startWaiterThread(_ childProcessIdentifier: Int32) {
        let thread = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(childProcessIdentifier, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
            guard let self = self else { return }
            _ = self.readerDone.wait(timeout: .now() + 1)
            self.lock.lock()
            self._exitStatus = code
            self.lock.unlock()
            self.onExit?(code)
        }
        thread.name = "TermuxPtyWaiter"
        thread.start()
    }

    public struct SpawnError: Error, CustomStringConvertible {
        public let message: String
        public let code: Int32
        public var description: String { "\(message): \(String(cString: strerror(code)))" }
    }

    static func setWindowSize(_ fileDescriptor: Int32, rows: Int, columns: Int, cellWidth: Int, cellHeight: Int) {
        var windowSize = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
                         ws_xpixel: UInt16(clamping: columns * cellWidth), ws_ypixel: UInt16(clamping: rows * cellHeight))
        _ = ioctl(fileDescriptor, UInt(TIOCSWINSZ), &windowSize)
    }

    static func createSubprocess(executable: String, arguments: [String], environment: [String], workingDirectory: String,
                                 rows: Int, columns: Int, cellWidth: Int, cellHeight: Int) throws -> (Int32, Int32) {
        let masterDescriptor = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard masterDescriptor >= 0 else { throw SpawnError(message: "Cannot open /dev/ptmx", code: errno) }
        guard let deviceName = PTYFunctions.slaveName(masterDescriptor) else {
            let e = errno
            close(masterDescriptor)
            throw SpawnError(message: "Cannot grantpt()/unlockpt()/ptsname_r() on /dev/ptmx", code: e)
        }

        var terminalAttributes = termios()
        tcgetattr(masterDescriptor, &terminalAttributes)
        terminalAttributes.c_iflag |= tcflag_t(IUTF8)
        terminalAttributes.c_iflag &= ~tcflag_t(IXON | IXOFF)
        tcsetattr(masterDescriptor, TCSANOW, &terminalAttributes)

        setWindowSize(masterDescriptor, rows: rows, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight)

        #if canImport(Glibc)
        var actions = posix_spawn_file_actions_t()
        var spawnAttributes = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        var spawnAttributes: posix_spawnattr_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&spawnAttributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&spawnAttributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, deviceName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if !workingDirectory.isEmpty {
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }

        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&spawnAttributes, &noSignals)
        posix_spawnattr_setsigdefault(&spawnAttributes, &allSignals)
        let flags = PTYFunctions.spawnSetSID | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&spawnAttributes, Int16(truncatingIfNeeded: flags))

        let argumentVector: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let environmentVector: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argumentVector.forEach { free($0) }
            environmentVector.forEach { free($0) }
        }
        var childProcessIdentifier: pid_t = 0
        let result = posix_spawnp(&childProcessIdentifier, executable, &actions, &spawnAttributes, argumentVector, environmentVector)
        guard result == 0 else {
            close(masterDescriptor)
            throw SpawnError(message: "exec(\"\(executable)\")", code: result)
        }
        return (masterDescriptor, childProcessIdentifier)
    }
}

private enum PTYFunctions {
    #if canImport(Glibc)
    static let spawnSetSID: Int32 = 0x80
    private typealias IntegerFunction = @convention(c) (Int32) -> Int32
    private typealias SlaveNameFunction = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32
    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let p = dlsym(nil, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    static func slaveName(_ fileDescriptor: Int32) -> String? {
        guard let grant = symbol("grantpt", as: IntegerFunction.self), let unlock = symbol("unlockpt", as: IntegerFunction.self),
              let slaveNameLookup = symbol("ptsname_r", as: SlaveNameFunction.self) else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        guard grant(fileDescriptor) == 0, unlock(fileDescriptor) == 0, slaveNameLookup(fileDescriptor, &buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
    }
    #else
    static let spawnSetSID = Int32(POSIX_SPAWN_SETSID)
    static func slaveName(_ fileDescriptor: Int32) -> String? {
        guard grantpt(fileDescriptor) == 0, unlockpt(fileDescriptor) == 0, let p = ptsname(fileDescriptor) else { return nil }
        return String(cString: p)
    }
    #endif
}

private enum Glue {
    static func read(_ fileDescriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Glibc)
        return Glibc.read(fileDescriptor, buffer, count)
        #else
        return Darwin.read(fileDescriptor, buffer, count)
        #endif
    }
    static func write(_ fileDescriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Glibc)
        return Glibc.write(fileDescriptor, buffer, count)
        #else
        return Darwin.write(fileDescriptor, buffer, count)
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
#endif

#if !os(iOS)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Real pseudo-terminal backend (port of terminal-emulator/src/main/jni/termux.c) for macOS and
/// Linux, used for development and tests. Not available on iOS, which forbids spawning processes.
///
/// The subprocess is started with `posix_spawn` in a new session with the pty slave as
/// stdin/stdout/stderr (equivalent to the fork + setsid + dup2 + execvp sequence in termux.c).
public final class PTYProcessBackend: TerminalBackend {
    public var onOutput: (([UInt8]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOutput }
        set { lock.lock(); _onOutput = newValue; lock.unlock() }
    }
    public var onExit: ((Int32) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onExit }
        set { lock.lock(); _onExit = newValue; lock.unlock() }
    }
    public var pid: Int32 { lock.lock(); defer { lock.unlock() }; return _pid }

    /// Exit status once the process has finished: the exit code, or -signal if killed by a signal.
    public var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return _exitStatus }

    public let executable: String
    /// Arguments after argv[0] (argv[0] is `executable`).
    public let arguments: [String]
    /// Environment as "NAME=value" strings.
    public let environment: [String]
    public let workingDirectory: String

    private let lock = NSLock()
    private var _onOutput: (([UInt8]) -> Void)?
    private var _onExit: ((Int32) -> Void)?
    private var _pid: Int32 = -1
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

    // MARK: TerminalBackend

    public func start(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        do {
            let (fd, childPid) = try PTYProcessBackend.createSubprocess(
                executable: executable, arguments: [executable] + arguments, environment: environment,
                workingDirectory: workingDirectory, rows: rows, columns: columns,
                cellWidth: cellWidthPixels, cellHeight: cellHeightPixels)
            lock.lock()
            masterFD = fd
            _pid = childPid
            lock.unlock()
            startReaderThread(fd)
            startWaiterThread(childPid)
        } catch {
            let message = "\r\n[Failed to start \(executable): \(error)]\r\n"
            onOutput?(Array(message.utf8))
            lock.lock(); _exitStatus = 1; lock.unlock()
            onExit?(1)
        }
    }

    public func write(_ data: [UInt8]) {
        let fd = lock.withLock { masterFD }
        guard fd >= 0, !data.isEmpty else { return }
        writeQueue.async {
            var offset = 0
            while offset < data.count {
                let n = data[offset...].withUnsafeBytes { Glue.write(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                offset += n
            }
        }
    }

    public func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        let fd = lock.withLock { masterFD }
        guard fd >= 0 else { return }
        PTYProcessBackend.setWindowSize(fd, rows: rows, columns: columns, cellWidth: cellWidthPixels, cellHeight: cellHeightPixels)
    }

    public func terminate() {
        let p = lock.withLock { _exitStatus == nil ? _pid : -1 }
        if p > 0 { kill(p, SIGKILL) }
    }

    // MARK: Threads

    private func startReaderThread(_ fd: Int32) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { Glue.read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    self?.onOutput?(Array(buffer[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break // EOF or EIO once the slave side is closed
                }
            }
            self?.readerDone.signal()
        }
        thread.name = "TermuxPtyReader"
        thread.start()
    }

    private func startWaiterThread(_ childPid: Int32) {
        let thread = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(childPid, &status, 0) < 0 && errno == EINTR {}
            // Same convention as termux.c waitFor(): exit code, or -signal.
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
            guard let self = self else { return }
            // Give the reader a moment to deliver remaining output.
            _ = self.readerDone.wait(timeout: .now() + 1)
            self.lock.lock()
            self._exitStatus = code
            self.lock.unlock()
            self.onExit?(code)
        }
        thread.name = "TermuxPtyWaiter"
        thread.start()
    }

    // MARK: Subprocess creation (port of create_subprocess in termux.c)

    public struct SpawnError: Error, CustomStringConvertible {
        public let message: String
        public let code: Int32
        public var description: String { "\(message): \(String(cString: strerror(code)))" }
    }

    static func setWindowSize(_ fd: Int32, rows: Int, columns: Int, cellWidth: Int, cellHeight: Int) {
        var sz = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
                         ws_xpixel: UInt16(clamping: columns * cellWidth), ws_ypixel: UInt16(clamping: rows * cellHeight))
        _ = ioctl(fd, UInt(TIOCSWINSZ), &sz)
    }

    static func createSubprocess(executable: String, arguments: [String], environment: [String], workingDirectory: String,
                                 rows: Int, columns: Int, cellWidth: Int, cellHeight: Int) throws -> (Int32, Int32) {
        let ptm = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard ptm >= 0 else { throw SpawnError(message: "Cannot open /dev/ptmx", code: errno) }
        guard let devname = PTYFunctions.slaveName(ptm) else {
            let e = errno
            close(ptm)
            throw SpawnError(message: "Cannot grantpt()/unlockpt()/ptsname_r() on /dev/ptmx", code: e)
        }

        // Enable UTF-8 mode and disable flow control to prevent Ctrl+S from locking up the display.
        var tios = termios()
        tcgetattr(ptm, &tios)
        tios.c_iflag |= tcflag_t(IUTF8)
        tios.c_iflag &= ~tcflag_t(IXON | IXOFF)
        tcsetattr(ptm, TCSANOW, &tios)

        setWindowSize(ptm, rows: rows, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight)

        #if canImport(Glibc)
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        // The child opens the slave after setsid(), which makes it the controlling terminal on Linux.
        posix_spawn_file_actions_addopen(&actions, 0, devname, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if !workingDirectory.isEmpty {
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }

        // Clear signals which the parent may have blocked or ignored.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        let flags = PTYFunctions.spawnSetSID | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var childPid: pid_t = 0
        let rc = posix_spawnp(&childPid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else {
            close(ptm)
            throw SpawnError(message: "exec(\"\(executable)\")", code: rc)
        }
        return (ptm, childPid)
    }
}

/// grantpt/unlockpt/ptsname_r are hidden behind feature-test macros in Swift's Glibc module,
/// so they are looked up dynamically there.
private enum PTYFunctions {
    #if canImport(Glibc)
    static let spawnSetSID: Int32 = 0x80 // POSIX_SPAWN_SETSID in glibc >= 2.26
    private typealias IntFn = @convention(c) (Int32) -> Int32
    private typealias PtsnameR = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32
    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let p = dlsym(nil, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    static func slaveName(_ fd: Int32) -> String? {
        guard let grant = symbol("grantpt", as: IntFn.self), let unlock = symbol("unlockpt", as: IntFn.self),
              let ptsnameR = symbol("ptsname_r", as: PtsnameR.self) else { return nil }
        var buf = [CChar](repeating: 0, count: 64)
        guard grant(fd) == 0, unlock(fd) == 0, ptsnameR(fd, &buf, buf.count) == 0 else { return nil }
        return String(cString: buf)
    }
    #else
    static let spawnSetSID = Int32(POSIX_SPAWN_SETSID)
    static func slaveName(_ fd: Int32) -> String? {
        guard grantpt(fd) == 0, unlockpt(fd) == 0, let p = ptsname(fd) else { return nil }
        return String(cString: p)
    }
    #endif
}

/// Avoids name clashes between the libc functions and methods of the backend.
private enum Glue {
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Glibc)
        return Glibc.read(fd, buf, count)
        #else
        return Darwin.read(fd, buf, count)
        #endif
    }
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Glibc)
        return Glibc.write(fd, buf, count)
        #else
        return Darwin.write(fd, buf, count)
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
#endif

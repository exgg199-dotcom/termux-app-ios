import Foundation
#if canImport(Glibc)
import Glibc
private func systemUname(_ u: inout utsname) -> Int32 { Glibc.uname(&u) }
#elseif canImport(Darwin)
import Darwin
private func systemUname(_ u: inout utsname) -> Int32 { Darwin.uname(&u) }
#endif

public enum SystemInfo {
    public static var userName: String {
        if let passwordEntry = getpwuid(getuid()), let n = passwordEntry.pointee.pw_name {
            let s = String(cString: n)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["USER"] ?? "mobile"
    }

    public static var hostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let s = String(cString: buffer)
            if !s.isEmpty { return s }
        }
        return "localhost"
    }

    public struct Uname {
        public var sysname: String
        public var nodename: String
        public var release: String
        public var version: String
        public var machine: String
        public var operatingSystem: String
    }

    public static var uname: Uname {
        var u = utsname()
        _ = systemUname(&u)
        func field<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[0..<end], as: UTF8.self)
            }
        }
        var result = Uname(sysname: field(u.sysname), nodename: field(u.nodename), release: field(u.release),
                           version: field(u.version), machine: field(u.machine), operatingSystem: "GNU/Linux")
        #if os(iOS)
        result.sysname = "Darwin"
        result.operatingSystem = "iOS"
        #elseif os(macOS)
        result.operatingSystem = "macOS"
        #elseif os(Linux)
        result.operatingSystem = "GNU/Linux"
        #endif
        if result.nodename.isEmpty { result.nodename = hostName }
        return result
    }
}

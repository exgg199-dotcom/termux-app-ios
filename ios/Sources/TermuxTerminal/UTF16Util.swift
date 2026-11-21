import Foundation

/// Helpers mirroring `java.lang.Character` UTF-16 functions, since the port keeps Java's
/// UTF-16 (`char[]`) text storage as `[UInt16]`.
enum UTF16Util {
    static let MIN_SUPPLEMENTARY_CODE_POINT = 0x10000

    @inline(__always) static func isHighSurrogate(_ c: UInt16) -> Bool {
        return c >= 0xD800 && c <= 0xDBFF
    }

    @inline(__always) static func isLowSurrogate(_ c: UInt16) -> Bool {
        return c >= 0xDC00 && c <= 0xDFFF
    }

    @inline(__always) static func toCodePoint(_ high: UInt16, _ low: UInt16) -> Int {
        return ((Int(high) - 0xD800) << 10) + (Int(low) - 0xDC00) + 0x10000
    }

    @inline(__always) static func charCount(_ codePoint: Int) -> Int {
        return codePoint >= MIN_SUPPLEMENTARY_CODE_POINT ? 2 : 1
    }

    /// Like `Character.toChars(codePoint, dst, dstIndex)`.
    @inline(__always) static func toChars(_ codePoint: Int, _ dst: inout [UInt16], _ index: Int) {
        if codePoint >= MIN_SUPPLEMENTARY_CODE_POINT {
            let cp = codePoint - 0x10000
            dst[index] = UInt16(0xD800 + (cp >> 10))
            dst[index + 1] = UInt16(0xDC00 + (cp & 0x3FF))
        } else {
            dst[index] = UInt16(truncatingIfNeeded: codePoint)
        }
    }

    /// Append a code point to a UTF-16 buffer, like `StringBuilder.appendCodePoint()`.
    @inline(__always) static func appendCodePoint(_ codePoint: Int, to dst: inout [UInt16]) {
        if codePoint >= MIN_SUPPLEMENTARY_CODE_POINT {
            let cp = codePoint - 0x10000
            dst.append(UInt16(0xD800 + (cp >> 10)))
            dst.append(UInt16(0xDC00 + (cp & 0x3FF)))
        } else {
            dst.append(UInt16(truncatingIfNeeded: codePoint))
        }
    }

    static func string(_ chars: [UInt16]) -> String {
        return String(decoding: chars, as: UTF16.self)
    }

    static func string(_ chars: ArraySlice<UInt16>) -> String {
        return String(decoding: chars, as: UTF16.self)
    }

    static func chars(_ string: String) -> [UInt16] {
        return Array(string.utf16)
    }

    /// Whether the code point is unassigned or a surrogate, like the Java
    /// `Character.getType(cp) == UNASSIGNED || SURROGATE` check.
    static func isUnassignedOrSurrogate(_ codePoint: Int) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: codePoint)) else { return true }
        return scalar.properties.generalCategory == .unassigned
    }
}

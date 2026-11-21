import XCTest
@testable import TermuxTerminal

/**
 * "\033P" is a device control string.
 */
final class DeviceControlStringTest: TerminalTestCase {

	private static func hexEncode(_ s: String) -> String {
		var result = ""
		for unit in s.utf16 {
			let hex = String(unit, radix: 16, uppercase: true)
			result += (hex.count < 2 ? "0" : "") + hex
		}
		return result
	}

	private func assertCapabilityResponse(_ cap: String, _ expectedResponse: String) {
		let hexEncode = DeviceControlStringTest.hexEncode
		let input = "\u{1B}P+q" + hexEncode(cap) + "\u{1B}\\";
		assertEnteringStringGivesResponse(input, "\u{1B}P1+r" + hexEncode(cap) + "=" + hexEncode(expectedResponse) + "\u{1B}\\");
	}

	func testReportColorsAndName() {
		// Request Termcap/Terminfo String. The string following the "q" is a list of names encoded in
		// hexadecimal (2 digits per character) separated by ; which correspond to termcap or terminfo key
		// names.
		// Two special features are also recognized, which are not key names: Co for termcap colors (or colors
		// for terminfo colors), and TN for termcap name (or name for terminfo name).
		// xterm responds with DCS 1 + r P t ST for valid requests, adding to P t an = , and the value of the
		// corresponding string that xterm would send, or DCS 0 + r P t ST for invalid requests. The strings are
		// encoded in hexadecimal (2 digits per character).
		withTerminalSized(3, 3).enterString("A");
		assertCapabilityResponse("Co", "256");
		assertCapabilityResponse("colors", "256");
		assertCapabilityResponse("TN", "xterm");
		assertCapabilityResponse("name", "xterm");
		enterString("B").assertLinesAre("AB ", "   ", "   ");
	}

	func testReportKeys() {
		withTerminalSized(3, 3);
		assertCapabilityResponse("kB", "\u{1B}[Z");
	}

	func testReallyLongDeviceControlString() {
		withTerminalSized(3, 3).enterString("\u{1B}P");
		for _ in 0..<10000 {
			enterString("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
		}
		// The terminal should ignore the overlong DCS sequence and continue printing "aaa." and fill at least the first two lines with
		// them:
		assertLineIs(0, "aaa");
		assertLineIs(1, "aaa");
	}

}

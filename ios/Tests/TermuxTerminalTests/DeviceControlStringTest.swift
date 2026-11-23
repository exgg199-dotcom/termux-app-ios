import XCTest
@testable import TermuxTerminal

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
		assertLineIs(0, "aaa");
		assertLineIs(1, "aaa");
	}

}

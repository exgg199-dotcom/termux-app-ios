import XCTest
@testable import TermuxTerminal

final class UnicodeInputTest: TerminalTestCase {

	func testIllFormedUtf8SuccessorByteNotConsumed() {
		withTerminalSized(5, 5);
		mTerminal.append([0b11101111, UInt8(ascii: "a")], 2);
		assertLineIs(0, stringFromCodePoint(TerminalEmulator.UNICODE_REPLACEMENT_CHAR) + "a   ");

		var input: [UInt8] = [
				0x61, 0xF1,
				0x80, 0x80,
				0xe1, 0x80,
				0xc2, 0x62,
				0x80, 0x63,
				0x80, 0xbf,
				0x64
		];
		withTerminalSized(10, 2);
		mTerminal.append(input, input.count);
		assertLinesAre("a\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}c\u{FFFD}\u{FFFD}d", "          ");

		withTerminalSized(5, 2);
		input = [
				0xed, 0xa0,
				0x80, 0xed,
				0xad, 0xbf,
				0xed, 0xae,
				0x80, 0xed,
				0xbf, 0xbf
		];
		mTerminal.append(input, input.count);
		assertLinesAre("\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD} ", "     ");

		withTerminalSized(5, 2);
		input = [0xe0, 0xa0, UInt8(ascii: " ")];
		mTerminal.append(input, input.count);
		assertLinesAre("\u{FFFD}    ", "     ");

	}

	func testUnassignedCodePoint() {
		withTerminalSized(3, 3);
		let b: [UInt8] = [0xf3, 0x82, 0x95, 0x81];
		mTerminal.append(b, b.count);
		enterString("Y");
		assertEquals(1, UTF16Util.charCount(TerminalEmulator.UNICODE_REPLACEMENT_CHAR));
		assertLineStartsWith(0, TerminalEmulator.UNICODE_REPLACEMENT_CHAR, c("Y"), c(" "));
	}

	func testStuff() {
		withTerminalSized(80, 24);
		let b: [UInt8] = [0xf3, 0x82, 0x95, 0x81, 0x61, 0x38, 0xe7, 0x8f,
				0xae, 0xc2, 0x9f, 0xe8, 0xa0, 0x9f, 0xe8, 0x8c, 0xa4,
				0xed, 0x93, 0x89, 0xef, 0xbf, 0xbd, 0x42, 0xc2, 0x9b,
				0xe6, 0x87, 0x89, 0x5a];
		mTerminal.append(b, b.count);
	}

	func testSimpleCombining() {
		withTerminalSized(3, 2).enterString(" a\u{302} ").assertLinesAre(" a\u{302} ", "   ");
	}

	func testCombiningCharacterInFirstColumn() {
		withTerminalSized(5, 3).enterString("test\r\nhi\r\n").assertLinesAre("test ", "hi   ", "     ");

		withTerminalSized(5, 5).enterString("test\r\nabc\r\n\u{302}\r\ndef\r\n");
		assertLinesAre("test ", "abc  ", " \u{302}    ", "def  ", "     ");
	}

	func testCombiningCharacterInLastColumn() {
		withTerminalSized(3, 2).enterString("  a\u{302}").assertLinesAre("  a\u{302}", "   ");
		withTerminalSized(3, 2).enterString("  à̲").assertLinesAre("  à̲", "   ");
		withTerminalSized(3, 2).enterString("Aà̲F").assertLinesAre("Aà̲F", "   ");
	}

	func testWideCharacterInLastColumn() {
		withTerminalSized(3, 2).enterString("  枝\u{302}").assertLinesAre("   ", "枝\u{302} ");

		withTerminalSized(3, 2).enterString(" 枝").assertLinesAre(" 枝", "   ").assertCursorAt(0, 2);
		enterString("a").assertLinesAre(" 枝", "a  ");
	}

	func testWideCharacterDeletion() {
		withTerminalSized(3, 2).enterString("枝\u{1B}[Da").assertLinesAre(" a ", "   ");
		withTerminalSized(3, 2).enterString("枝\u{1B}[2Da").assertLinesAre("a  ", "   ");
		withTerminalSized(3, 2).enterString("枝\u{1B}[2D枝").assertLinesAre("枝 ", "   ");
		withTerminalSized(3, 2).enterString("枝\u{1B}[1D枝").assertLinesAre(" 枝", "   ");
		withTerminalSized(5, 2).enterString(" 枝 \u{1B}[Da").assertLinesAre(" 枝a ", "     ");
		withTerminalSized(5, 2).enterString("a \u{1B}[D\u{302}").assertLinesAre("a\u{302}    ", "     ");
		withTerminalSized(5, 2).enterString("枝 \u{1B}[D\u{302}").assertLinesAre("枝\u{302}   ", "     ");
		enterString("Z").assertLinesAre("枝\u{302}Z  ", "     ");
		enterString("\u{1B}[D ").assertLinesAre("枝\u{302}   ", "     ");
		enterString("\u{1B}[2DU").assertLinesAre(" U   ", "     ");
	}

	func testWideCharOverwriting() {
		withTerminalSized(3, 2).enterString("abc\u{1B}[3D枝").assertLinesAre("枝c", "   ");
	}

	func testOverlongUtf8Encoding() {
		withTerminalSized(5, 5).mTerminal.append([0xc0, 0xa0, UInt8(ascii: "Y")], 3);
		assertLineIs(0, "\u{FFFD}Y   ");
	}

	func testWideCharacterWithoutWrapping() {
		withTerminalSized(3, 3).enterString("\u{1B}[?7l").enterString("枝枝枝").assertLinesAre("枝 ", "   ", "   ");
		enterString("a枝").assertLinesAre("枝a", "   ", "   ");
	}

}

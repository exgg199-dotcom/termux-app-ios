import XCTest
@testable import TermuxTerminal


final class UnicodeInputTest: TerminalTestCase {

	func testIllFormedUtf8SuccessorByteNotConsumed() {
		// The Unicode Standard Version 6.2 – Core Specification (http://www.unicode.org/versions/Unicode6.2.0/ch03.pdf):
		// "If the converter encounters an ill-formed UTF-8 code unit sequence which starts with a valid first byte, but which does not
		// continue with valid successor bytes (see Table 3-7), it must not consume the successor bytes as part of the ill-formed
		// subsequence whenever those successor bytes themselves constitute part of a well-formed UTF-8 code unit subsequence."
		withTerminalSized(5, 5);
		mTerminal.append([0b11101111, UInt8(ascii: "a")], 2);
		assertLineIs(0, stringFromCodePoint(TerminalEmulator.UNICODE_REPLACEMENT_CHAR) + "a   ");

		// https://code.google.com/p/chromium/issues/detail?id=212704
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

		// Surrogate pairs.
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

		// https://bugzilla.mozilla.org/show_bug.cgi?id=746900: "with this patch 0xe0 0x80 is decoded as two U+FFFDs,
		// but 0xe0 0xa0 is decoded as a single U+FFFD, and this is correct according to the "Best Practices", but IE
		// and Chrome (Version 22.0.1229.94) decode both of them as two U+FFFDs. Opera 12.11 decodes both of them as
		// one U+FFFD".
		withTerminalSized(5, 2);
		input = [0xe0, 0xa0, UInt8(ascii: " ")];
		mTerminal.append(input, input.count);
		assertLinesAre("\u{FFFD}    ", "     ");

		// withTerminalSized(5, 2);
		// input = [0xe0, 0x80, 'a'];
		// mTerminal.append(input, input.count);
		// assertLinesAre("\uFFFD\uFFFDa  ", "     ");
	}

	func testUnassignedCodePoint() {
		withTerminalSized(3, 3);
		// UTF-8 for U+C2541, an unassigned code point:
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

		// U+0302 is COMBINING CIRCUMFLEX ACCENT. Test case from mosh (http://mosh.mit.edu/).
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
		// CSI Ps D Cursor Backward Ps Times
		withTerminalSized(3, 2).enterString("枝\u{1B}[Da").assertLinesAre(" a ", "   ");
		withTerminalSized(3, 2).enterString("枝\u{1B}[2Da").assertLinesAre("a  ", "   ");
		withTerminalSized(3, 2).enterString("枝\u{1B}[2D枝").assertLinesAre("枝 ", "   ");
		withTerminalSized(3, 2).enterString("枝\u{1B}[1D枝").assertLinesAre(" 枝", "   ");
		withTerminalSized(5, 2).enterString(" 枝 \u{1B}[Da").assertLinesAre(" 枝a ", "     ");
		withTerminalSized(5, 2).enterString("a \u{1B}[D\u{302}").assertLinesAre("a\u{302}    ", "     ");
		withTerminalSized(5, 2).enterString("枝 \u{1B}[D\u{302}").assertLinesAre("枝\u{302}   ", "     ");
		enterString("Z").assertLinesAre("枝\u{302}Z  ", "     ");
		enterString("\u{1B}[D ").assertLinesAre("枝\u{302}   ", "     ");
		// Go back two columns, standing at the second half of the wide character:
		enterString("\u{1B}[2DU").assertLinesAre(" U   ", "     ");
	}

	func testWideCharOverwriting() {
		withTerminalSized(3, 2).enterString("abc\u{1B}[3D枝").assertLinesAre("枝c", "   ");
	}

	func testOverlongUtf8Encoding() {
		// U+0020 should be encoded as 0x20, 0xc0 0xa0 is an overlong encoding
		// so should be replaced with the replacement char U+FFFD.
		withTerminalSized(5, 5).mTerminal.append([0xc0, 0xa0, UInt8(ascii: "Y")], 3);
		assertLineIs(0, "\u{FFFD}Y   ");
	}

	func testWideCharacterWithoutWrapping() {
		// With wraparound disabled. The behaviour when a wide character is output with cursor in
		// the last column when autowrap is disabled is not obvious, but we expect the wide
		// character to be ignored here.
		withTerminalSized(3, 3).enterString("\u{1B}[?7l").enterString("枝枝枝").assertLinesAre("枝 ", "   ", "   ");
		enterString("a枝").assertLinesAre("枝a", "   ", "   ");
	}

}

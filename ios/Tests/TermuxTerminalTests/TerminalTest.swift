import XCTest
@testable import TermuxTerminal


final class TerminalTest: TerminalTestCase {

	func testCursorPositioning() {
		withTerminalSized(10, 10).placeCursorAndAssert(1, 2).placeCursorAndAssert(3, 5).placeCursorAndAssert(2, 2).enterString("A")
				.assertCursorAt(2, 3);
	}

	func testScreen() {
		withTerminalSized(3, 3);
		assertLinesAre("   ", "   ", "   ");

		assertEquals("", mTerminal.screen.transcriptText);
		enterString("hi").assertLinesAre("hi ", "   ", "   ");
		assertEquals("hi", mTerminal.screen.transcriptText);
		enterString("\r\nu");
		assertEquals("hi\nu", mTerminal.screen.transcriptText);
		mTerminal.reset();
		assertEquals("hi\nu", mTerminal.screen.transcriptText);

		withTerminalSized(3, 3).enterString("hello");
		assertEquals("hello", mTerminal.screen.transcriptText);
		enterString("\r\nworld");
		assertEquals("hello\nworld", mTerminal.screen.transcriptText);
	}

	func testScrollDownInAltBuffer() {
		withTerminalSized(3, 3).enterString("\u{1B}[?1049h");
		enterString("\u{1B}[38;5;111m1\r\n");
		enterString("\u{1B}[38;5;112m2\r\n");
		enterString("\u{1B}[38;5;113m3\r\n");
		enterString("\u{1B}[38;5;114m4\r\n");
		enterString("\u{1B}[38;5;115m5");
		assertLinesAre("3  ", "4  ", "5  ");
		assertForegroundColorAt(0, 0, 113);
		assertForegroundColorAt(1, 0, 114);
		assertForegroundColorAt(2, 0, 115);
	}

	func testMouseClick() {
		withTerminalSized(10, 10);
		assertFalse(mTerminal.isMouseTrackingActive);
		enterString("\u{1B}[?1000h");
		assertTrue(mTerminal.isMouseTrackingActive);
		enterString("\u{1B}[?1000l");
		assertFalse(mTerminal.isMouseTrackingActive);
		enterString("\u{1B}[?1000h");
		assertTrue(mTerminal.isMouseTrackingActive);

		enterString("\u{1B}[?1006h");
		mTerminal.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON, 3, 4, true);
		assertEquals("\u{1B}[<0;3;4M", mOutput.getOutputAndClear());
		mTerminal.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON, 3, 4, false);
		assertEquals("\u{1B}[<0;3;4m", mOutput.getOutputAndClear());

		// When the client says that a click is outside (which could happen when pixels are outside
		// the terminal area, see https://github.com/termux/termux-app/issues/501) the terminal
		// sends a click at the edge.
		mTerminal.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON, 0, 0, true);
		assertEquals("\u{1B}[<0;1;1M", mOutput.getOutputAndClear());
		mTerminal.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON, 11, 11, false);
		assertEquals("\u{1B}[<0;10;10m", mOutput.getOutputAndClear());
	}

	func testNormalization() {
		// var lowerCaseN = 0x006E;
		// var combiningTilde = 0x0303;
		// var combined = 0x00F1;
		withTerminalSized(3, 3).assertLinesAre("   ", "   ", "   ");
		enterString("n\u{303}");
		assertEquals(1, WcWidth.width(Array("n\u{303}".utf16), 0));
		// assertEquals("\u00F1  ", new String(mTerminal.screen.getLine(0)));
		assertLinesAre("n\u{303}  ", "   ", "   ");
	}

	/** On "\e[18t" xterm replies with "\e[8;${HEIGHT};${WIDTH}t" */
	func testReportTerminalSize() {
		withTerminalSized(5, 5);
		assertEnteringStringGivesResponse("\u{1B}[18t", "\u{1B}[8;5;5t");
		for width in 3..<12 {
			for height in 3..<12 {
				resize(width, height);
				assertEnteringStringGivesResponse("\u{1B}[18t", "\u{1B}[8;" + height + ";" + width + "t");
			}
		}
	}

	/** Device Status Report (DSR) and Report Cursor Position (CPR). */
	func testDeviceStatusReport() {
		withTerminalSized(5, 5);
		assertEnteringStringGivesResponse("\u{1B}[5n", "\u{1B}[0n");

		assertEnteringStringGivesResponse("\u{1B}[6n", "\u{1B}[1;1R");
		enterString("AB");
		assertEnteringStringGivesResponse("\u{1B}[6n", "\u{1B}[1;3R");
		enterString("\r\n");
		assertEnteringStringGivesResponse("\u{1B}[6n", "\u{1B}[2;1R");
	}

	/** Test the cursor shape changes using DECSCUSR. */
	func testSetCursorStyle() {
		withTerminalSized(5, 5);
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK, mTerminal.cursorStyle);
		enterString("\u{1B}[3 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE, mTerminal.cursorStyle);
		enterString("\u{1B}[5 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR, mTerminal.cursorStyle);
		enterString("\u{1B}[0 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK, mTerminal.cursorStyle);
		enterString("\u{1B}[6 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BAR, mTerminal.cursorStyle);
		enterString("\u{1B}[4 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE, mTerminal.cursorStyle);
		enterString("\u{1B}[1 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK, mTerminal.cursorStyle);
		enterString("\u{1B}[4 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_UNDERLINE, mTerminal.cursorStyle);
		enterString("\u{1B}[2 q");
		assertEquals(TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK, mTerminal.cursorStyle);
	}

	func testPaste() {
		withTerminalSized(5, 5);
		mTerminal.paste("hi");
		assertEquals("hi", mOutput.getOutputAndClear());

		enterString("\u{1B}[?2004h");
		mTerminal.paste("hi");
		assertEquals("\u{1B}[200~" + "hi" + "\u{1B}[201~", mOutput.getOutputAndClear());

		enterString("\u{1B}[?2004l");
		mTerminal.paste("hi");
		assertEquals("hi", mOutput.getOutputAndClear());
	}

	func testSelectGraphics() {
		selectGraphicsTestRun(";");
		selectGraphicsTestRun(":");
	}

	func selectGraphicsTestRun(_ separator: String) {
		withTerminalSized(5, 5);
		enterString("\u{1B}[31m");
		assertEquals(mTerminal.foreColor, 1);
		enterString("\u{1B}[32m");
		assertEquals(mTerminal.foreColor, 2);
		enterString("\u{1B}[43m");
		assertEquals(2, mTerminal.foreColor);
		assertEquals(3, mTerminal.backColor);

		// SGR 0 should reset both foreground and background color.
		enterString("\u{1B}[0m");
		assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
		assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, mTerminal.backColor);

		// Test CSI resetting to default if sequence starts with ; or has sequential ;;
        // Check TerminalEmulator.parseArg()
        enterString("\u{1B}[31m\u{1B}[m");
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        enterString("\u{1B}[31m\u{1B}[;m".replacingOccurrences(of: ";", with: separator));
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        enterString("\u{1B}[31m\u{1B}[0m");
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        enterString("\u{1B}[31m\u{1B}[0;m".replacingOccurrences(of: ";", with: separator));
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        enterString("\u{1B}[31;;m");
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        enterString("\u{1B}[31::m");
        assertEquals(1, mTerminal.foreColor);
        enterString("\u{1B}[31;m");
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        enterString("\u{1B}[31:m");
        assertEquals(1, mTerminal.foreColor);
        enterString("\u{1B}[31;;41m");
        assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
        assertEquals(1, mTerminal.backColor);
        enterString("\u{1B}[0m");
        assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, mTerminal.backColor);

		// 256 colors:
		enterString("\u{1B}[38;5;119m".replacingOccurrences(of: ";", with: separator));
		assertEquals(119, mTerminal.foreColor);
		assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, mTerminal.backColor);
		enterString("\u{1B}[48;5;129m".replacingOccurrences(of: ";", with: separator));
		assertEquals(119, mTerminal.foreColor);
		assertEquals(129, mTerminal.backColor);

		// Invalid parameter:
		enterString("\u{1B}[48;8;129m".replacingOccurrences(of: ";", with: separator));
		assertEquals(119, mTerminal.foreColor);
		assertEquals(129, mTerminal.backColor);

		// Multiple parameters at once:
		enterString("\u{1B}[38;5;178".replacingOccurrences(of: ";", with: separator) + ";" + "48;5;179m".replacingOccurrences(of: ";", with: separator));
		assertEquals(178, mTerminal.foreColor);
		assertEquals(179, mTerminal.backColor);

		// Omitted parameter means zero:
		enterString("\u{1B}[38;5;m".replacingOccurrences(of: ";", with: separator));
		assertEquals(0, mTerminal.foreColor);
		assertEquals(179, mTerminal.backColor);
		enterString("\u{1B}[48;5;m".replacingOccurrences(of: ";", with: separator));
		assertEquals(0, mTerminal.foreColor);
		assertEquals(0, mTerminal.backColor);

		// 24 bit colors:
		enterString(("\u{1B}[0m")); // Reset fg and bg colors.
		enterString("\u{1B}[38;2;255;127;2m".replacingOccurrences(of: ";", with: separator));
		var expectedForeground = 0xff000000 | (255 << 16) | (127 << 8) | 2;
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, mTerminal.backColor);
		enterString("\u{1B}[48;2;1;2;254m".replacingOccurrences(of: ";", with: separator));
		let expectedBackground = 0xff000000 | (1 << 16) | (2 << 8) | 254;
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(expectedBackground, mTerminal.backColor);

		// 24 bit colors, set fg and bg at once:
		enterString(("\u{1B}[0m")); // Reset fg and bg colors.
		assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, mTerminal.foreColor);
		assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, mTerminal.backColor);
		enterString("\u{1B}[38;2;255;127;2".replacingOccurrences(of: ";", with: separator) + ";" + "48;2;1;2;254m".replacingOccurrences(of: ";", with: separator));
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(expectedBackground, mTerminal.backColor);

		// 24 bit colors, invalid input:
		enterString("\u{1B}[38;2;300;127;2;48;2;1;300;254m".replacingOccurrences(of: ";", with: separator));
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(expectedBackground, mTerminal.backColor);

		// 24 bit colors, omitted parameter means zero:
		enterString("\u{1B}[38;2;255;127;m".replacingOccurrences(of: ";", with: separator));
		expectedForeground = 0xff000000 | (255 << 16) | (127 << 8);
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(expectedBackground, mTerminal.backColor);
		enterString("\u{1B}[38;2;123;;77m".replacingOccurrences(of: ";", with: separator));
		expectedForeground = 0xff000000 | (123 << 16) | 77;
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(expectedBackground, mTerminal.backColor);

		// 24 bit colors, extra sub-parameters are skipped:
		expectedForeground = 0xff000000 | (255 << 16) | (127 << 8) | 2;
		enterString("\u{1B}[0;38:2:255:127:2:48:2:1:2:254m");
		assertEquals(expectedForeground, mTerminal.foreColor);
		assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, mTerminal.backColor);
	}

	func testBackgroundColorErase() {
		let rows = 3;
		let cols = 3;
		withTerminalSized(cols, rows);
		for r in 0..<rows {
			for c in 0..<cols {
				let style = getStyleAt(r, c);
				assertEquals(TextStyle.COLOR_INDEX_FOREGROUND, TextStyle.decodeForeColor(style));
				assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, TextStyle.decodeBackColor(style));
			}
		}
		// Foreground color to 119:
		enterString("\u{1B}[38;5;119m");
		// Background color to 129:
		enterString("\u{1B}[48;5;129m");
		// Clear with ED, Erase in Display:
		enterString("\u{1B}[2J");
		for r in 0..<rows {
			for c in 0..<cols {
				let style = getStyleAt(r, c);
				assertEquals(119, TextStyle.decodeForeColor(style));
				assertEquals(129, TextStyle.decodeBackColor(style));
			}
		}
		// Background color to 139:
		enterString("\u{1B}[48;5;139m");
		// Insert two blank lines.
		enterString("\u{1B}[2L");
		for r in 0..<rows {
			for c in 0..<cols {
				let style = getStyleAt(r, c);
				assertEquals((r == 0 || r == 1) ? 139 : 129, TextStyle.decodeBackColor(style));
			}
		}

		withTerminalSized(cols, rows);
		// Background color to 129:
		enterString("\u{1B}[48;5;129m");
		// Erase two characters, filling them with background color:
		enterString("\u{1B}[2X");
		assertEquals(129, TextStyle.decodeBackColor(getStyleAt(0, 0)));
		assertEquals(129, TextStyle.decodeBackColor(getStyleAt(0, 1)));
		assertEquals(TextStyle.COLOR_INDEX_BACKGROUND, TextStyle.decodeBackColor(getStyleAt(0, 2)));
	}

	func testParseColor() {
		assertEquals(0xFF0000FA, TerminalColors.parse("#0000FA"));
		assertEquals(0xFF000000, TerminalColors.parse("#000000"));
		assertEquals(0xFF000000, TerminalColors.parse("#000"));
		assertEquals(0xFF000000, TerminalColors.parse("#000000000"));
		assertEquals(0xFF53186f, TerminalColors.parse("#53186f"));

		assertEquals(0xFFFF00FF, TerminalColors.parse("rgb:F/0/F"));
		assertEquals(0xFF0000FA, TerminalColors.parse("rgb:00/00/FA"));
		assertEquals(0xFF53186f, TerminalColors.parse("rgb:53/18/6f"));

		assertEquals(0, TerminalColors.parse("invalid_0000FA"));
		assertEquals(0, TerminalColors.parse("#3456"));
	}

	/** The ncurses library still uses this. */
	func testLineDrawing() {
		// 016 - shift out / G1. 017 - shift in / G0. "ESC ) 0" - use line drawing for G1
		withTerminalSized(4, 2).enterString("q\u{1B})0q\u{E}q\u{F}q").assertLinesAre("qq─q", "    ");
		// "\0337", saving cursor should save G0, G1 and invoked charset and "ESC 8" should restore.
		withTerminalSized(4, 2).enterString("\u{1B})0\u{E}qqq\u{1B}7\u{F}\u{1B}8q").assertLinesAre("────", "    ");
	}

	func testSoftTerminalReset() {
		// See http://vt100.net/docs/vt510-rm/DECSTR and https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=650304
		// "\033[?7l" is DECRST to disable wrap-around, and DECSTR ("\033[!p") should reset it.
		withTerminalSized(3, 3).enterString("\u{1B}[?7lABCD").assertLinesAre("ABD", "   ", "   ");
		enterString("\u{1B}[!pEF").assertLinesAre("ABE", "F  ", "   ");
	}

	func testBel() {
		withTerminalSized(3, 3);
		assertEquals(0, mOutput.bellsRung);
		enterString("\u{7}");
		assertEquals(1, mOutput.bellsRung);
		enterString("hello\u{7}");
		assertEquals(2, mOutput.bellsRung);
		enterString("\u{7}hello");
		assertEquals(3, mOutput.bellsRung);
		enterString("hello\u{7}world");
		assertEquals(4, mOutput.bellsRung);
	}

	func testAutomargins() {
		withTerminalSized(3, 3).enterString("abc").assertLinesAre("abc", "   ", "   ").assertCursorAt(0, 2);
		enterString("d").assertLinesAre("abc", "d  ", "   ").assertCursorAt(1, 1);

		withTerminalSized(3, 3).enterString("abc\r ").assertLinesAre(" bc", "   ", "   ").assertCursorAt(0, 1);
	}

	func testTab() {
		withTerminalSized(11, 2).enterString("01234567890\r\tXX").assertLinesAre("01234567XX0", "           ");
		withTerminalSized(11, 2).enterString("01234567890\u{1B}[44m\r\tXX").assertLinesAre("01234567XX0", "           ");
	}

}

import XCTest
@testable import TermuxTerminal


/** "\033[" is the Control Sequence Introducer char sequence (CSI). */
final class ControlSequenceIntroducerTest: TerminalTestCase {

	/** CSI Ps P Scroll down Ps lines (default = 1) (SD). */
	func testCsiT() {
		withTerminalSized(4, 6).enterString("1\r\n2\r\n3\r\nhi\u{1B}[2Tyo\r\nA\r\nB").assertLinesAre("    ", "    ", "1   ", "2 yo", "A   ",
				"Bi  ");
		// Default value (1):
		withTerminalSized(4, 6).enterString("1\r\n2\r\n3\r\nhi\u{1B}[Tyo\r\nA\r\nB").assertLinesAre("    ", "1   ", "2   ", "3 yo", "Ai  ",
				"B   ");
	}

	/** CSI Ps S Scroll up Ps lines (default = 1) (SU). */
	func testCsiS() {
		// The behaviour here is a bit inconsistent between terminals - this is how the OS X Terminal.app does it:
		withTerminalSized(3, 4).enterString("1\r\n2\r\n3\r\nhi\u{1B}[2Sy").assertLinesAre("3  ", "hi ", "   ", "  y");
		// Default value (1):
		withTerminalSized(3, 4).enterString("1\r\n2\r\n3\r\nhi\u{1B}[Sy").assertLinesAre("2  ", "3  ", "hi ", "  y");
	}

	/** CSI Ps X  Erase Ps Character(s) (default = 1) (ECH). */
	func testCsiX() {
		// See https://code.google.com/p/chromium/issues/detail?id=212712 where test was extraced from.
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[X").assertLinesAre("abcdefg ijkl ", "             ");
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[1X").assertLinesAre("abcdefg ijkl ", "             ");
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[2X").assertLinesAre("abcdefg  jkl ", "             ");
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[20X").assertLinesAre("abcdefg      ", "             ");
	}

	/** CSI Pm m  Set SGR parameter(s) from semicolon-separated list Pm. */
	func testCsiSGRParameters() {
		// Set more parameters (19) than supported (16).  Additional parameters should be silently consumed.
		withTerminalSized(3, 2).enterString("\u{1B}[0;38;2;255;255;255;48;2;0;0;0;1;2;3;4;5;7;8;9mabc").assertLinesAre("abc", "   ");
	}

	/** CSI Ps b  Repeat the preceding graphic character Ps times (REP). */
	func testRepeat() {
		withTerminalSized(3, 2).enterString("a\u{1B}[b").assertLinesAre("aa ", "   ");
		withTerminalSized(3, 2).enterString("a\u{1B}[2b").assertLinesAre("aaa", "   ");
		// When no char has been output we ignore REP:
		withTerminalSized(3, 2).enterString("\u{1B}[b").assertLinesAre("   ", "   ");
		// This shows that REP outputs the last emitted code point and not the one relative to the
		// current cursor position:
		withTerminalSized(5, 2).enterString("abcde\u{1B}[2G\u{1B}[2b\n").assertLinesAre("aeede", "     ");
	}

	/** CSI 3 J  Clear scrollback (xterm, libvte; non-standard). */
	func testCsi3J() {
		withTerminalSized(3, 2).enterString("a\r\nb\r\nc\r\nd");
		assertEquals("a\nb\nc\nd", mTerminal.screen.transcriptText);
		enterString("\u{1B}[3J");
		assertEquals("c\nd", mTerminal.screen.transcriptText);

		withTerminalSized(3, 2).enterString("Lorem_ipsum");
		assertEquals("Lorem_ipsum", mTerminal.screen.transcriptText);
		enterString("\u{1B}[3J");
		assertEquals("ipsum", mTerminal.screen.transcriptText);

		withTerminalSized(3, 2).enterString("w\r\nx\r\ny\r\nz\u{1B}[?1049h\u{1B}[3J\u{1B}[?1049l");
		assertEquals("y\nz", mTerminal.screen.transcriptText);
	}

    func testReportPixelSize() {
        var columns = 3;
        var rows = 3;
        withTerminalSized(columns, rows);
        var cellWidth = TerminalTestCase.INITIAL_CELL_WIDTH_PIXELS;
        var cellHeight = TerminalTestCase.INITIAL_CELL_HEIGHT_PIXELS;
        assertEnteringStringGivesResponse("\u{1B}[14t", "\u{1B}[4;" + (rows*cellHeight) + ";" + (columns*cellWidth) + "t");
        assertEnteringStringGivesResponse("\u{1B}[16t", "\u{1B}[6;" + cellHeight + ";" + cellWidth + "t");
        columns = 23;
        rows = 33;
        resize(columns, rows);
        assertEnteringStringGivesResponse("\u{1B}[14t", "\u{1B}[4;" + (rows*cellHeight) + ";" + (columns*cellWidth) + "t");
        assertEnteringStringGivesResponse("\u{1B}[16t", "\u{1B}[6;" + cellHeight + ";" + cellWidth + "t");
        cellWidth = 8;
        cellHeight = 18;
        mTerminal.resize(columns, rows, cellWidth, cellHeight);
        assertEnteringStringGivesResponse("\u{1B}[14t", "\u{1B}[4;" + (rows*cellHeight) + ";" + (columns*cellWidth) + "t");
        assertEnteringStringGivesResponse("\u{1B}[16t", "\u{1B}[6;" + cellHeight + ";" + cellWidth + "t");
    }

    /**
     * See <a href="https://sw.kovidgoyal.net/kitty/underlines/">Colored and styled underlines</a>:
     *
     * <pre>
     *  <ESC>[4:0m  # no underline
     *  <ESC>[4:1m  # straight underline
     *  <ESC>[4:2m  # double underline
     *  <ESC>[4:3m  # curly underline
     *  <ESC>[4:4m  # dotted underline
     *  <ESC>[4:5m  # dashed underline
     *  <ESC>[4m    # straight underline (for backwards compat)
     *  <ESC>[24m   # no underline (for backwards compat)
     * </pre>
     * <p>
     * We currently parse the variants, but map them to normal/no underlines as appropriate
     */
    func testUnderlineVariants() {
        for suffix in ["", ":1", ":2", ":3", ":4", ":5"] {
            for stop in ["24", "4:0"] {
                withTerminalSized(3, 3);
                enterString("\u{1B}[4" + suffix + "m").assertLinesAre("   ", "   ", "   ");
                assertEquals(TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, mTerminal.effect);
                enterString("\u{1B}[4;1m").assertLinesAre("   ", "   ", "   ");
                assertEquals(TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, mTerminal.effect);
                enterString("\u{1B}[" + stop + "m").assertLinesAre("   ", "   ", "   ");
                assertEquals(TextStyle.CHARACTER_ATTRIBUTE_BOLD, mTerminal.effect);
            }
        }
    }

    func testManyParameters() {
        var b = "\u{1B}[";
        for _ in 0..<30 {
            b += "0;";
        }
        b += "4:2";
        // This clearing of underline should be ignored as the parameters pass the threshold for too many parameters:
        b += "4:0m";
        withTerminalSized(3, 3)
            .enterString(b)
            .assertLinesAre("   ", "   ", "   ");
        assertEquals(TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, mTerminal.effect);
    }

}

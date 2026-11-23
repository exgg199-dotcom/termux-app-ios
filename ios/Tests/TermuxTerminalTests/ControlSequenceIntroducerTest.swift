import XCTest
@testable import TermuxTerminal

final class ControlSequenceIntroducerTest: TerminalTestCase {

	func testCsiT() {
		withTerminalSized(4, 6).enterString("1\r\n2\r\n3\r\nhi\u{1B}[2Tyo\r\nA\r\nB").assertLinesAre("    ", "    ", "1   ", "2 yo", "A   ",
				"Bi  ");
		withTerminalSized(4, 6).enterString("1\r\n2\r\n3\r\nhi\u{1B}[Tyo\r\nA\r\nB").assertLinesAre("    ", "1   ", "2   ", "3 yo", "Ai  ",
				"B   ");
	}

	func testCsiS() {
		withTerminalSized(3, 4).enterString("1\r\n2\r\n3\r\nhi\u{1B}[2Sy").assertLinesAre("3  ", "hi ", "   ", "  y");
		withTerminalSized(3, 4).enterString("1\r\n2\r\n3\r\nhi\u{1B}[Sy").assertLinesAre("2  ", "3  ", "hi ", "  y");
	}

	func testCsiX() {
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[X").assertLinesAre("abcdefg ijkl ", "             ");
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[1X").assertLinesAre("abcdefg ijkl ", "             ");
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[2X").assertLinesAre("abcdefg  jkl ", "             ");
		withTerminalSized(13, 2).enterString("abcdefghijkl\u{8}\u{8}\u{8}\u{8}\u{8}\u{1B}[20X").assertLinesAre("abcdefg      ", "             ");
	}

	func testCsiSGRParameters() {
		withTerminalSized(3, 2).enterString("\u{1B}[0;38;2;255;255;255;48;2;0;0;0;1;2;3;4;5;7;8;9mabc").assertLinesAre("abc", "   ");
	}

	func testRepeat() {
		withTerminalSized(3, 2).enterString("a\u{1B}[b").assertLinesAre("aa ", "   ");
		withTerminalSized(3, 2).enterString("a\u{1B}[2b").assertLinesAre("aaa", "   ");
		withTerminalSized(3, 2).enterString("\u{1B}[b").assertLinesAre("   ", "   ");
		withTerminalSized(5, 2).enterString("abcde\u{1B}[2G\u{1B}[2b\n").assertLinesAre("aeede", "     ");
	}

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
        b += "4:0m";
        withTerminalSized(3, 3)
            .enterString(b)
            .assertLinesAre("   ", "   ", "   ");
        assertEquals(TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, mTerminal.effect);
    }

}

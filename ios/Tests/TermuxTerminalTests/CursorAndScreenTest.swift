import XCTest
@testable import TermuxTerminal

final class CursorAndScreenTest: TerminalTestCase {

	func testDeleteLinesKeepsStyles() {
		let cols = 5, rows = 5;
		withTerminalSized(cols, rows);
		for row in 0..<5 {
			for col in 0..<5 {
				enterString("\u{1B}[38;5;" + col + "m");
				enterString("\u{1B}[48;5;" + row + "m");
				enterString(stringFromCodePoint(c("A") + col + row * 5));
			}
		}
		assertLinesAre("ABCDE", "FGHIJ", "KLMNO", "PQRST", "UVWXY");
		for row in 0..<5 {
			for col in 0..<5 {
				let s = getStyleAt(row, col);
				assertEquals(col, TextStyle.decodeForeColor(s));
				assertEquals(row, TextStyle.decodeBackColor(s));
			}
		}
		enterString("\u{1B}[H\u{1B}[2M");
		assertLinesAre("KLMNO", "PQRST", "UVWXY", "     ", "     ");
		for row in 0..<3 {
			for col in 0..<5 {
				let s = getStyleAt(row, col);
				assertEquals(col, TextStyle.decodeForeColor(s));
				assertEquals(row + 2, TextStyle.decodeBackColor(s));
			}
		}
		enterString("\u{1B}[38;5;98m");
		enterString("\u{1B}[48;5;99m");
		enterString("\u{1B}[B\u{1B}[2L");
		assertLinesAre("KLMNO", "     ", "     ", "PQRST", "UVWXY");
		for row in 0..<5 {
			for col in 0..<5 {
				let wantedForeground = (row == 1 || row == 2) ? 98 : col;
				let wantedBackground = (row == 1 || row == 2) ? 99 : (row == 0 ? 2 : row);
				let s = getStyleAt(row, col);
				assertEquals(wantedForeground, TextStyle.decodeForeColor(s));
				assertEquals(wantedBackground, TextStyle.decodeBackColor(s));
			}
		}
	}

	func testDeleteCharacters() {
		withTerminalSized(5, 2).enterString("枝ce").assertLinesAre("枝ce ", "     ");
		withTerminalSized(5, 2).enterString("a枝ce").assertLinesAre("a枝ce", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[G\u{1B}[P").assertLinesAre("ice  ", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[G\u{1B}[2P").assertLinesAre("ce   ", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[2G\u{1B}[2P").assertLinesAre("ne   ", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[G\u{1B}[99P").assertLinesAre("     ", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ice").enterString("\u{1B}[G\u{1B}[2P").assertLinesAre("ce   ", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ice").enterString("\u{1B}[G\u{1B}[P").assertLinesAre("ice  ", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ice").enterString("\u{1B}[2G\u{1B}[2P").assertLinesAre("n\u{302}e   ", "     ");
		withTerminalSized(5, 2).enterString("枝ce").enterString("\u{1B}[Ga").assertLinesAre("a ce ", "     ");
		withTerminalSized(5, 2).enterString("枝ce").enterString("\u{1B}[2Ga").assertLinesAre(" ace ", "     ");
		withTerminalSized(5, 2).enterString("枝ce").enterString("\u{1B}[G\u{1B}[P").assertLinesAre(" ce  ", "     ");
		withTerminalSized(5, 2).enterString("枝ce").enterString("\u{1B}[2G\u{1B}[P").assertLinesAre(" ce  ", "     ");
		withTerminalSized(5, 2).enterString("枝ce").enterString("\u{1B}[2G\u{1B}[2P").assertLinesAre(" e   ", "     ");
		withTerminalSized(5, 2).enterString("枝ce").enterString("\u{1B}[G\u{1B}[2P").assertLinesAre("ce   ", "     ");
		withTerminalSized(5, 2).enterString("a枝ce").enterString("\u{1B}[G\u{1B}[P").assertLinesAre("枝ce ", "     ");
	}

	func testInsertMode() {
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[G\u{1B}[4hA").assertLinesAre("Anice", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[2G\u{1B}[4hA").assertLinesAre("nAice", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[G\u{1B}[4hABC").assertLinesAre("ABCni", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ice").enterString("\u{1B}[G\u{1B}[4hA").assertLinesAre("An\u{302}ice", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ice").enterString("\u{1B}[G\u{1B}[4hAB").assertLinesAre("ABn\u{302}ic", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ic\u{302}e").enterString("\u{1B}[2G\u{1B}[4hA").assertLinesAre("n\u{302}Aic\u{302}e", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}ice").enterString("\u{1B}[GA").assertLinesAre("Aice ", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}\u{302}i\u{302}ce").enterString("\u{1B}[GA").assertLinesAre("Ai\u{302}ce ", "     ");
		withTerminalSized(5, 2).enterString("n\u{302}\u{302}ice!\u{302}").enterString("\u{1B}[5GA").assertLinesAre("n\u{302}\u{302}iceA", "     ");
		withTerminalSized(5, 2).enterString("nic\u{302}e!\u{302}").enterString("\u{1B}[4G枝").assertLinesAre("nic\u{302}枝", "     ");
		withTerminalSized(5, 2).enterString("nic枝\u{302}").enterString("\u{1B}[3GA").assertLinesAre("niA枝\u{302}", "     ");
		withTerminalSized(5, 2).enterString("nic枝\u{302}").enterString("\u{1B}[3GA").assertLinesAre("niA枝\u{302}", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[G\u{1B}[4h枝").assertLinesAre("枝nic", "     ");
		withTerminalSized(5, 2).enterString("nice").enterString("\u{1B}[2G\u{1B}[4h枝").assertLinesAre("n枝ic", "     ");
		withTerminalSized(5, 2).enterString("n枝ce").enterString("\u{1B}[G\u{1B}[4ha").assertLinesAre("an枝c", "     ");
	}

	func testCursorHorizontalPositionAbsolute() {
		withTerminalSized(4, 4).enterString("ABC\u{1B}[`").assertCursorAt(0, 0);
		enterString("\u{1B}[1`").assertCursorAt(0, 0).enterString("\u{1B}[2`").assertCursorAt(0, 1);
		enterString("\r\n\u{1B}[3`").assertCursorAt(1, 2).enterString("\u{1B}[22`").assertCursorAt(1, 3);
		enterString("\u{1B}[?69h\u{1B}[2;3s\u{1B}[`").assertCursorAt(0, 0).enterString("\u{1B}[22`").assertCursorAt(0, 3);
		enterString("\u{1B}[?6h\u{1B}[`").assertCursorAt(0, 1).enterString("\u{1B}[22`").assertCursorAt(0, 2);
	}

	func testCursorForward() {
		withTerminalSized(6, 2).enterString("A\u{1B}[CB\u{1B}[2CC").assertLinesAre("A B  C", "      ");
		withTerminalSized(6, 2).enterString("A\u{1B}[44CB").assertLinesAre("A    B", "      ");
		withTerminalSized(6, 2).enterString("\u{1B}[?69h\u{1B}[1;3s\u{1B}[44CAB").assertLinesAre("  A   ", "B     ");
	}

	func testCursorBack() {
		withTerminalSized(3, 2).enterString("A\u{1B}[DB").assertLinesAre("B  ", "   ");
		withTerminalSized(3, 2).enterString("AB\u{1B}[2DC").assertLinesAre("CB ", "   ");
		withTerminalSized(3, 2).enterString("AB\u{1B}[44DC").assertLinesAre("CB ", "   ");
		withTerminalSized(6, 2).enterString("ABCD\u{1B}[?69h\u{1B}[2;6s\u{1B}[44DE").assertLinesAre("AECD  ", "      ");
	}

	func testCursorUp() {
		withTerminalSized(3, 3).enterString("ABCDEFG\u{1B}[AH").assertLinesAre("ABC", "DHF", "G  ");
		withTerminalSized(3, 3).enterString("ABCDEFG\u{1B}[2AH").assertLinesAre("AHC", "DEF", "G  ");
		withTerminalSized(3, 3).enterString("ABCDEFG\u{1B}[44AH").assertLinesAre("AHC", "DEF", "G  ");
	}

	func testCursorDown() {
		withTerminalSized(3, 3).enterString("AB\u{1B}[BC").assertLinesAre("AB ", "  C", "   ");
		withTerminalSized(3, 3).enterString("AB\u{1B}[2BC").assertLinesAre("AB ", "   ", "  C");
		withTerminalSized(3, 3).enterString("AB\u{1B}[44BC").assertLinesAre("AB ", "   ", "  C");
	}

	func testReportCursorPosition() {
		withTerminalSized(10, 10);
		for i in 0..<10 {
			for j in 0..<10 {
				enterString("\u{1B}[" + (i + 1) + ";" + (j + 1) + "H");
				assertCursorAt(i, j);
				assertEnteringStringGivesResponse("\u{1B}[6n", "\u{1B}[" + (i + 1) + ";" + (j + 1) + "R");
				assertEnteringStringGivesResponse("\u{1B}[?6n", "\u{1B}[?" + (i + 1) + ";" + (j + 1) + ";1R");
			}
		}
	}

	func DISABLED_testHorizontalTabColorsBackground() {
		withTerminalSized(10, 3).enterString("\u{1B}[48;5;15m").enterString("\t");
		assertCursorAt(0, 8);
		for i in 0..<10 {
			let expectedColor = i < 8 ? 15 : TextStyle.COLOR_INDEX_BACKGROUND;
			assertEquals(expectedColor, TextStyle.decodeBackColor(getStyleAt(0, i)));
		}
	}

	func testClearingOfAutowrap() {
		withTerminalSized(15, 6);

		enterString("-----  1  ----X");
		enterString("\u{1B}[K-");

		enterString("-----  2  ----X");
		enterString("\u{1B}[J-");

		enterString("-----  3  ----X");
		enterString("\u{1B}[@-");

		enterString("-----  4  ----X");
		enterString("\u{1B}[P-");

		enterString("-----  5  ----X");
		enterString("\u{1B}[X-");

		enterString("XXXXXXXXXXXXXXX");
		enterString("\u{1B}[M-");

		assertLinesAre(
				"-----  1  -----",
				"-----  2  -----",
				"-----  3  -----",
				"-----  4  -----",
				"-----  5  -----",
				"              -");
	}

	func testBackspaceAcrossWrappedLines() {
		withTerminalSized(3, 3).enterString("hi\r\n\u{8}\u{8}you").assertLinesAre("hi ", "you", "   ");
		withTerminalSized(3, 3).enterString("hi y").assertLinesAre("hi ", "y  ", "   ").enterString("\u{8}\u{8}#").assertLinesAre("hi#", "y  ", "   ");
		withTerminalSized(3, 3).enterString("\u{8}\u{8}\u{8}\u{8}hi").assertLinesAre("hi ", "   ", "   ");
	}

	func testCursorSaveRestoreLocation() {
		withTerminalSized(4, 2).enterString("t\u{1B}7est\r\nme\u{1B}8ry ").assertLinesAre("try ", "me  ");
		withTerminalSized(4, 2).enterString("t\u{1B}[sest\r\nme\u{1B}[ury ").assertLinesAre("try ", "me  ");
		withTerminalSized(4, 2).enterString("t\u{1B}[?1049h\u{1B}[Hest\r\nme").assertLinesAre("est ", "me  ").enterString("\u{1B}[?1049lry").assertLinesAre("try ", "    ");
	}

	func testCursorSaveRestoreTextStyle() {
		var s: Int64

		withTerminalSized(4, 2).enterString("\u{1B}[31;42;4m..\u{1B}7\u{1B}[36;47;24m\u{1B}8..");
		s = getStyleAt(0, 3);
		assertEquals(1, TextStyle.decodeForeColor(s));
		assertEquals(2, TextStyle.decodeBackColor(s));
		assertEquals(TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, TextStyle.decodeEffect(s));

		withTerminalSized(4, 2).enterString("\u{1B}[31;42;4m..\u{1B}[s\u{1B}[36;47;24m\u{1B}[u..");
		s = getStyleAt(0, 3);
		assertEquals(1, TextStyle.decodeForeColor(s));
		assertEquals(2, TextStyle.decodeBackColor(s));
		assertEquals(TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, TextStyle.decodeEffect(s));

		withTerminalSized(4, 2);
		enterString("\u{1B}[31;42;4m..\u{1B}[?1049h\u{1B}[H\u{1B}[36;47;24m.");
		s = getStyleAt(0, 0);
		assertEquals(6, TextStyle.decodeForeColor(s));
		assertEquals(7, TextStyle.decodeBackColor(s));
		assertEquals(0, TextStyle.decodeEffect(s));
		enterString("\u{1B}[?1049l..");
		s = getStyleAt(0, 3);
		assertEquals(1, TextStyle.decodeForeColor(s));
		assertEquals(2, TextStyle.decodeBackColor(s));
		assertEquals(TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, TextStyle.decodeEffect(s));
	}

}

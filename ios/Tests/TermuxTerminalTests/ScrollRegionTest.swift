import XCTest
@testable import TermuxTerminal

final class ScrollRegionTest: TerminalTestCase {

	func testScrollRegionTop() {
		withTerminalSized(3, 4).enterString("111222333444").assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[2r").assertCursorAt(0, 0);
		enterString("\r\n\r\n\r\n\r\nCDEFGH").assertLinesAre("111", "444", "CDE", "FGH").assertHistoryStartsWith("333");
		enterString("IJK").assertLinesAre("111", "CDE", "FGH", "IJK").assertHistoryStartsWith("444");
		enterString("\u{1B}[r").enterString("\r\n\r\n\r\n").enterString("LMNOPQ").assertLinesAre("CDE", "FGH", "LMN", "OPQ");
	}

	func testScrollRegionBottom() {
		withTerminalSized(3, 4).enterString("111222333444");
		assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[1;3r").assertCursorAt(0, 0);
		enterString("\r\n\r\nCDEFGH").assertLinesAre("222", "CDE", "FGH", "444").assertHistoryStartsWith("111");
		enterString("\u{1B}[r").enterString("\r\n\r\n\r\n").enterString("IJKLMN").assertLinesAre("CDE", "FGH", "IJK", "LMN");
	}

	func testScrollRegionResetWithOriginMode() {
		withTerminalSized(3, 4).enterString("111222333444");
		assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[?6h\u{1B}[2r").assertCursorAt(1, 0);
	}

	func testScrollRegionLeft() {
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABCDEFG").assertLinesAre("ABC", " DE", " FG");
		enterString("HI").assertLinesAre("ADE", " FG", " HI").enterString("JK").assertLinesAre("AFG", " HI", " JK");
		enterString("\n").assertLinesAre("AHI", " JK", "   ");
	}

	func testScrollRegionRight() {
		withTerminalSized(3, 3).enterString("YYY\u{1B}[?69h\u{1B}[1;2sABCDEF").assertLinesAre("ABY", "CD ", "EF ");
		enterString("GH").assertLinesAre("CDY", "EF ", "GH ").enterString("IJ").assertLinesAre("EFY", "GH ", "IJ ");
		enterString("\n").assertLinesAre("GHY", "IJ ", "   ");
	}

	func testScrollRegionOnAllSides() {
		withTerminalSized(4, 4).enterString("ABCDEFGHIJKLMNOP").assertLinesAre("ABCD", "EFGH", "IJKL", "MNOP");
		enterString("\u{1B}[?6h\u{1B}[2;3r").assertCursorAt(1, 0);
		enterString("\u{1B}[?69h\u{1B}[2;3s").assertCursorAt(1, 1);
		enterString("QRST").assertLinesAre("ABCD", "EQRH", "ISTL", "MNOP");
		enterString("UV").assertLinesAre("ABCD", "ESTH", "IUVL", "MNOP");
	}

	func testDECCOLMResetsScrollMargin() {
		withTerminalSized(3, 4).enterString("111222333444").assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[2r\u{1B}[?3h\r\nABCDEFGHIJKL").assertLinesAre("ABC", "DEF", "GHI", "JKL");
	}

	func testScrollOutsideVerticalRegion() {
		withTerminalSized(3, 4).enterString("\u{1B}[0;2rhi\u{1B}[4;0Hyou").assertLinesAre("hi ", "   ", "   ", "you");
	}

	func testNELRespectsLeftMargin() {
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABC\u{1B}ED").assertLinesAre("ABC", "D  ", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABC\u{1B}[?6h\u{1B}ED").assertLinesAre("ABC", " D ", "   ");
	}

	func testRiRespectsLeftMargin() {
		withTerminalSized(4, 3).enterString("ABCD\u{1B}[?69h\u{1B}[2;3s\u{1B}[?6h\u{1B}M").assertLinesAre("A  D", " BC ", "    ");
	}

	func testSdRespectsLeftMargin() {
		withTerminalSized(4, 3).enterString("ABCD\u{1B}[?69h\u{1B}[2;3s\u{1B}[?6h\u{1B}[2T").assertLinesAre("A  D", "    ", " BC ");
	}

	func testBackwardIndex() {
		withTerminalSized(3, 3).enterString("ABCDEF\u{1B}6H").assertLinesAre("ABC", "DHF", "   ");
		enterString("\u{1B}6\u{1B}6I").assertLinesAre("ABC", "IHF", "   ");
		enterString("\u{1B}6\u{1B}6").assertLinesAre(" AB", " IH", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABCDEF\u{1B}6\u{1B}6").assertLinesAre("A B", "  D", "  F");
	}

	func testForwardIndex() {
		withTerminalSized(3, 3).enterString("ABCD\u{1B}9E").assertLinesAre("ABC", "D E", "   ");
		enterString("\u{1B}9").assertLinesAre("BC ", " E ", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[0;2sABCD\u{1B}9").assertLinesAre("B  ", "D  ", "   ");
	}

	func testScrollDownWithScrollRegion() {
		withTerminalSized(2, 5).enterString("1\r\n2\r\n3\r\n4\r\n5").assertLinesAre("1 ", "2 ", "3 ", "4 ", "5 ");
		enterString("\u{1B}[3r").enterString("\u{1B}[2T").assertLinesAre("1 ", "2 ", "  ", "  ", "3 ");
	}

	func testScrollDownBelowScrollRegion() {
		withTerminalSized(2, 5).enterString("1\r\n2\r\n3\r\n4\r\n5").assertLinesAre("1 ", "2 ", "3 ", "4 ", "5 ");
		enterString("\u{1B}[1;3r");
		enterString("\u{1B}[4;1H");
		enterString("QQ\r\nRR\r\n\r\n\r\nYY");
		assertLinesAre("1 ", "2 ", "3 ", "QQ", "YY");
	}

	func testScrollRegionDoesNotLimitCursorMovement() {
		withTerminalSized(6, 4)
			.enterString("\u{1B}[4;7r\u{1B}[3;1Haaa\u{1B}[Axxx")
			.assertLinesAre(
				"      ",
				"   xxx",
				"aaa   ",
				"      "
			);

		withTerminalSized(6, 4)
			.enterString("\u{1B}[1;3r\u{1B}[3;1Haaa\u{1B}[Bxxx")
			.assertLinesAre(
				"      ",
				"      ",
				"aaa   ",
				"   xxx"
			);
	}

	func testClearingWhenScrollingWithMargins() {
		let newForeground = 2;
		let newBackground = 3;
		let size = 3;
		let terminal = withTerminalSized(size, size)
			.enterString("\u{1B}[?69h\u{1B}[2s")
			.enterString("\u{1B}[" + (30 + newForeground) + ";" + (40 + newBackground) + "m")
			.enterString("\r\n\r\n\r\n\r\n\r\n");
		for row in 0..<size {
			for col in 0..<size {
				let expectedForeground = col == 0 ? TextStyle.COLOR_INDEX_FOREGROUND : newForeground;
				let expectedBackground = col == 0 ? TextStyle.COLOR_INDEX_BACKGROUND : newBackground;
				terminal.assertForegroundColorAt(row, col, expectedForeground);
				terminal.assertBackgroundColorAt(row, col, expectedBackground);
			}
		}
	}

}

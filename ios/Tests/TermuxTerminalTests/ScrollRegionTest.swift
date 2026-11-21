import XCTest
@testable import TermuxTerminal

/**
 * ${CSI}${top};${bottom}r" - set Scrolling Region [top;bottom] (default = full size of window) (DECSTBM).
 * <p/>
 * "DECSTBM moves the cursor to column 1, line 1 of the page" (http://www.vt100.net/docs/vt510-rm/DECSTBM).
 */
final class ScrollRegionTest: TerminalTestCase {

	func testScrollRegionTop() {
		withTerminalSized(3, 4).enterString("111222333444").assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[2r").assertCursorAt(0, 0);
		enterString("\r\n\r\n\r\n\r\nCDEFGH").assertLinesAre("111", "444", "CDE", "FGH").assertHistoryStartsWith("333");
		enterString("IJK").assertLinesAre("111", "CDE", "FGH", "IJK").assertHistoryStartsWith("444");
		// Reset scroll region and enter line:
		enterString("\u{1B}[r").enterString("\r\n\r\n\r\n").enterString("LMNOPQ").assertLinesAre("CDE", "FGH", "LMN", "OPQ");
	}

	func testScrollRegionBottom() {
		withTerminalSized(3, 4).enterString("111222333444");
		assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[1;3r").assertCursorAt(0, 0);
		enterString("\r\n\r\nCDEFGH").assertLinesAre("222", "CDE", "FGH", "444").assertHistoryStartsWith("111");
		// Reset scroll region and enter line:
		enterString("\u{1B}[r").enterString("\r\n\r\n\r\n").enterString("IJKLMN").assertLinesAre("CDE", "FGH", "IJK", "LMN");
	}

	func testScrollRegionResetWithOriginMode() {
		withTerminalSized(3, 4).enterString("111222333444");
		assertLinesAre("111", "222", "333", "444");
		// "\033[?6h" sets origin mode, so that the later DECSTBM resets cursor to below margin:
		enterString("\u{1B}[?6h\u{1B}[2r").assertCursorAt(1, 0);
	}

	func testScrollRegionLeft() {
		// ${CSI}?69h for DECLRMM enabling, ${CSI}${LEFTMARGIN};${RIGHTMARGIN}s for DECSLRM margin setting.
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABCDEFG").assertLinesAre("ABC", " DE", " FG");
		enterString("HI").assertLinesAre("ADE", " FG", " HI").enterString("JK").assertLinesAre("AFG", " HI", " JK");
		enterString("\n").assertLinesAre("AHI", " JK", "   ");
	}

	func testScrollRegionRight() {
		// ${CSI}?69h for DECLRMM enabling, ${CSI}${LEFTMARGIN};${RIGHTMARGIN}s for DECSLRM margin setting.
		withTerminalSized(3, 3).enterString("YYY\u{1B}[?69h\u{1B}[1;2sABCDEF").assertLinesAre("ABY", "CD ", "EF ");
		enterString("GH").assertLinesAre("CDY", "EF ", "GH ").enterString("IJ").assertLinesAre("EFY", "GH ", "IJ ");
		enterString("\n").assertLinesAre("GHY", "IJ ", "   ");
	}

	func testScrollRegionOnAllSides() {
		// ${CSI}?69h for DECLRMM enabling, ${CSI}${LEFTMARGIN};${RIGHTMARGIN}s for DECSLRM margin setting.
		withTerminalSized(4, 4).enterString("ABCDEFGHIJKLMNOP").assertLinesAre("ABCD", "EFGH", "IJKL", "MNOP");
		// http://www.vt100.net/docs/vt510-rm/DECOM
		enterString("\u{1B}[?6h\u{1B}[2;3r").assertCursorAt(1, 0);
		enterString("\u{1B}[?69h\u{1B}[2;3s").assertCursorAt(1, 1);
		enterString("QRST").assertLinesAre("ABCD", "EQRH", "ISTL", "MNOP");
		enterString("UV").assertLinesAre("ABCD", "ESTH", "IUVL", "MNOP");
	}

	func testDECCOLMResetsScrollMargin() {
		// DECCOLM — Select 80 or 132 Columns per Page (http://www.vt100.net/docs/vt510-rm/DECCOLM) has the important
		// side effect to clear scroll margins, which is useful for e.g. the "reset" utility to clear scroll margins.
		withTerminalSized(3, 4).enterString("111222333444").assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[2r\u{1B}[?3h\r\nABCDEFGHIJKL").assertLinesAre("ABC", "DEF", "GHI", "JKL");
	}

	func testScrollOutsideVerticalRegion() {
		withTerminalSized(3, 4).enterString("\u{1B}[0;2rhi\u{1B}[4;0Hyou").assertLinesAre("hi ", "   ", "   ", "you");
		//enterString("see").assertLinesAre("hi ", "   ", "   ", "see");
	}

	func testNELRespectsLeftMargin() {
		// vttest "Menu 11.3.2: VT420 Cursor-Movement Test", select "10. Test other movement (CR/HT/LF/FF) within margins".
		// The NEL (ESC E) sequence moves cursor to first position on next line, where first position depends on origin mode and margin.
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABC\u{1B}ED").assertLinesAre("ABC", "D  ", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABC\u{1B}[?6h\u{1B}ED").assertLinesAre("ABC", " D ", "   ");
	}

	func testRiRespectsLeftMargin() {
		// Reverse Index (RI), ${ESC}M, should respect horizontal margins:
		withTerminalSized(4, 3).enterString("ABCD\u{1B}[?69h\u{1B}[2;3s\u{1B}[?6h\u{1B}M").assertLinesAre("A  D", " BC ", "    ");
	}

	func testSdRespectsLeftMargin() {
		// Scroll Down (SD), ${CSI}${N}T, should respect horizontal margins:
		withTerminalSized(4, 3).enterString("ABCD\u{1B}[?69h\u{1B}[2;3s\u{1B}[?6h\u{1B}[2T").assertLinesAre("A  D", "    ", " BC ");
	}

	func testBackwardIndex() {
		// vttest "Menu 11.3.2: VT420 Cursor-Movement Test", test 7.
		// Without margins:
		withTerminalSized(3, 3).enterString("ABCDEF\u{1B}6H").assertLinesAre("ABC", "DHF", "   ");
		enterString("\u{1B}6\u{1B}6I").assertLinesAre("ABC", "IHF", "   ");
		enterString("\u{1B}6\u{1B}6").assertLinesAre(" AB", " IH", "   ");
		// With left margin:
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[2sABCDEF\u{1B}6\u{1B}6").assertLinesAre("A B", "  D", "  F");
	}

	func testForwardIndex() {
		// vttest "Menu 11.3.2: VT420 Cursor-Movement Test", test 8.
		// Without margins:
		withTerminalSized(3, 3).enterString("ABCD\u{1B}9E").assertLinesAre("ABC", "D E", "   ");
		enterString("\u{1B}9").assertLinesAre("BC ", " E ", "   ");
		// With right margin:
		withTerminalSized(3, 3).enterString("\u{1B}[?69h\u{1B}[0;2sABCD\u{1B}9").assertLinesAre("B  ", "D  ", "   ");
	}

	func testScrollDownWithScrollRegion() {
		withTerminalSized(2, 5).enterString("1\r\n2\r\n3\r\n4\r\n5").assertLinesAre("1 ", "2 ", "3 ", "4 ", "5 ");
		enterString("\u{1B}[3r").enterString("\u{1B}[2T").assertLinesAre("1 ", "2 ", "  ", "  ", "3 ");
	}

	func testScrollDownBelowScrollRegion() {
		withTerminalSized(2, 5).enterString("1\r\n2\r\n3\r\n4\r\n5").assertLinesAre("1 ", "2 ", "3 ", "4 ", "5 ");
		enterString("\u{1B}[1;3r"); // DECSTBM margins.
		enterString("\u{1B}[4;1H"); // Place cursor just below bottom margin.
		enterString("QQ\r\nRR\r\n\r\n\r\nYY");
		assertLinesAre("1 ", "2 ", "3 ", "QQ", "YY");
	}

	/** See https://github.com/termux/termux-app/issues/1340 */
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

	/**
	 * See <a href="https://github.com/termux/termux-packages/issues/12556">reported issue</a>.
	 */
	func testClearingWhenScrollingWithMargins() {
		let newForeground = 2;
		let newBackground = 3;
		let size = 3;
		let terminal = withTerminalSized(size, size)
			// Enable horizontal margin and set left margin to 1:
			.enterString("\u{1B}[?69h\u{1B}[2s")
			// Set foreground and background color:
			.enterString("\u{1B}[" + (30 + newForeground) + ";" + (40 + newBackground) + "m")
			// Enter newlines to scroll down:
			.enterString("\r\n\r\n\r\n\r\n\r\n");
		for row in 0..<size {
			for col in 0..<size {
				// The first column (outside of the scrolling area, due to us setting a left scroll
				// margin of 1) should be unmodified, the others should use the current style:
				let expectedForeground = col == 0 ? TextStyle.COLOR_INDEX_FOREGROUND : newForeground;
				let expectedBackground = col == 0 ? TextStyle.COLOR_INDEX_BACKGROUND : newBackground;
				terminal.assertForegroundColorAt(row, col, expectedForeground);
				terminal.assertBackgroundColorAt(row, col, expectedBackground);
			}
		}
	}

}

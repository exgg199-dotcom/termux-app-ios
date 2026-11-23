import XCTest
@testable import TermuxTerminal

final class ScreenBufferTest: TerminalTestCase {

	func testBasics() {
		let screen = TerminalBuffer(columns: 5, totalRows: 3, screenRows: 3);
		assertEquals("", screen.transcriptText);
		screen.setChar(0, 0, c("a"), 0);
		assertEquals("a", screen.transcriptText);
		screen.setChar(0, 0, c("b"), 0);
		assertEquals("b", screen.transcriptText);
		screen.setChar(2, 0, c("c"), 0);
		assertEquals("b c", screen.transcriptText);
		screen.setChar(2, 2, c("f"), 0);
		assertEquals("b c\n\n  f", screen.transcriptText);
		screen.blockSet(0, 0, 2, 2, c("X"), 0);
	}

	func testBlockSet() {
		let screen = TerminalBuffer(columns: 5, totalRows: 3, screenRows: 3);
		screen.blockSet(0, 0, 2, 2, c("X"), 0);
		assertEquals("XX\nXX", screen.transcriptText);
		screen.blockSet(1, 1, 2, 2, c("Y"), 0);
		assertEquals("XX\nXYY\n YY", screen.transcriptText);
	}

	func testGetSelectedText() {
		withTerminalSized(5, 3).enterString("ABCDEFGHIJ").assertLinesAre("ABCDE", "FGHIJ", "     ");
		assertEquals("AB", mTerminal.getSelectedText(0, 0, 1, 0));
		assertEquals("BC", mTerminal.getSelectedText(1, 0, 2, 0));
		assertEquals("CDE", mTerminal.getSelectedText(2, 0, 4, 0));
		assertEquals("FG", mTerminal.getSelectedText(0, 1, 1, 1));
		assertEquals("GH", mTerminal.getSelectedText(1, 1, 2, 1));
		assertEquals("HIJ", mTerminal.getSelectedText(2, 1, 4, 1));

		assertEquals("ABCDEFG", mTerminal.getSelectedText(0, 0, 1, 1));
		withTerminalSized(5, 3).enterString("ABCDE\r\nFGHIJ").assertLinesAre("ABCDE", "FGHIJ", "     ");
		assertEquals("ABCDE\nFG", mTerminal.getSelectedText(0, 0, 1, 1));
	}

	func testGetSelectedTextJoinFullLines() {
		withTerminalSized(5, 3).enterString("ABCDE\r\nFG");
		assertEquals("ABCDEFG", mTerminal.screen.getSelectedText(0, 0, 1, 1, true, true));

		withTerminalSized(5, 3).enterString("ABC\r\nFG");
		assertEquals("ABC\nFG", mTerminal.screen.getSelectedText(0, 0, 1, 1, true, true));
	}

	func testGetWordAtLocation() {
		withTerminalSized(5, 3).enterString("ABCDEFGHIJ\r\nKLMNO");
		assertEquals("ABCDEFGHIJKLMNO", mTerminal.screen.getWordAtLocation(0, 0));
		assertEquals("ABCDEFGHIJKLMNO", mTerminal.screen.getWordAtLocation(4, 1));
		assertEquals("ABCDEFGHIJKLMNO", mTerminal.screen.getWordAtLocation(4, 2));

		withTerminalSized(5, 3).enterString("ABC DEF GHI ");
		assertEquals("ABC", mTerminal.screen.getWordAtLocation(0, 0));
		assertEquals("", mTerminal.screen.getWordAtLocation(3, 0));
		assertEquals("DEF", mTerminal.screen.getWordAtLocation(4, 0));
		assertEquals("DEF", mTerminal.screen.getWordAtLocation(0, 1));
		assertEquals("DEF", mTerminal.screen.getWordAtLocation(1, 1));
		assertEquals("GHI", mTerminal.screen.getWordAtLocation(0, 2));
		assertEquals("", mTerminal.screen.getWordAtLocation(1, 2));
		assertEquals("", mTerminal.screen.getWordAtLocation(2, 2));
	}
}

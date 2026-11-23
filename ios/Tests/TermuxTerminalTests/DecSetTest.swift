import XCTest
@testable import TermuxTerminal

final class DecSetTest: TerminalTestCase {

	func testEnableDisableCursor() {
		withTerminalSized(3, 3);
		assertTrue("Initially the cursor should be enabled", mTerminal.isCursorEnabled);
		enterString("\u{1B}[?25l");
		assertFalse(mTerminal.isCursorEnabled);
		enterString("\u{1B}[?25h");
		assertTrue(mTerminal.isCursorEnabled);

		enterString("\u{1B}[?25l");
		assertFalse(mTerminal.isCursorEnabled);
		mTerminal.reset();
		assertTrue("Resetting the terminal should enable the cursor", mTerminal.isCursorEnabled);

		enterString("\u{1B}[?25l");
		assertFalse(mTerminal.isCursorEnabled);
		enterString("\u{1B}c");
		assertTrue(mTerminal.isCursorEnabled);
	}

	func testBracketedPasteMode() {
		withTerminalSized(3, 3);

		mTerminal.paste("a");
		assertEquals("Pasting 'a' should output 'a' when bracketed paste mode is disabled", "a", mOutput.getOutputAndClear());

		enterString("\u{1B}[?2004h");
		mTerminal.paste("a");
		assertEquals("Pasting when in bracketed paste mode should be bracketed", "\u{1B}[200~a\u{1B}[201~", mOutput.getOutputAndClear());

		enterString("\u{1B}[?2004l");
		mTerminal.paste("a");
		assertEquals("Pasting 'a' should output 'a' when bracketed paste mode is disabled", "a", mOutput.getOutputAndClear());

		enterString("\u{1B}[?2004h");
		mTerminal.paste("a");
		assertEquals("Pasting when in bracketed paste mode again should be bracketed", "\u{1B}[200~a\u{1B}[201~", mOutput.getOutputAndClear());

		mTerminal.paste("\u{1B}ab\u{1B}cd\u{1B}");
		assertEquals("Pasting an escape character should not input it", "\u{1B}[200~abcd\u{1B}[201~", mOutput.getOutputAndClear());
		mTerminal.paste("\u{81}ab\u{81}cd\u{9F}");
		assertEquals("Pasting C1 control codes should not input it", "\u{1B}[200~abcd\u{1B}[201~", mOutput.getOutputAndClear());

		mTerminal.reset();
		mTerminal.paste("a");
		assertEquals("Terminal reset() should disable bracketed paste mode", "a", mOutput.getOutputAndClear());
	}

	func testWrapAroundMode() {
		withTerminalSized(3, 3).enterString("abcd").assertLinesAre("abc", "d  ", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[?7labcd").assertLinesAre("abd", "   ", "   ");
		enterString("efg").assertLinesAre("abg", "   ", "   ");
		enterString("\u{1B}[?7hhij").assertLinesAre("abh", "ij ", "   ");
	}

}

import XCTest
@testable import TermuxTerminal

final class HistoryTest: TerminalTestCase {

	func testHistory() {
		let rows = 3;
		let cols = 3;
		withTerminalSized(cols, rows).enterString("111222333444555666777888999");
		assertCursorAt(2, 2);
		assertLinesAre("777", "888", "999");
		assertHistoryStartsWith("666", "555");

		resize(cols, 2);
		assertHistoryStartsWith("777", "666", "555");

		resize(cols, 3);
		assertHistoryStartsWith("666", "555");
	}

	func testHistoryWithScrollRegion() {
		withTerminalSized(3, 4).enterString("111222333444");
		assertLinesAre("111", "222", "333", "444");
		enterString("\u{1B}[2;3r");
		assertCursorAt(0, 0);
		enterString("\nCDEFGH").assertLinesAre("111", "CDE", "FGH", "444");
		enterString("IJK").assertLinesAre("111", "FGH", "IJK", "444").assertHistoryStartsWith("CDE");
		enterString("LMN").assertLinesAre("111", "IJK", "LMN", "444").assertHistoryStartsWith("FGH", "CDE");
	}

}

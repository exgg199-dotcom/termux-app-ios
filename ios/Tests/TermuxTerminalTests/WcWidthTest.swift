import XCTest
@testable import TermuxTerminal

final class WcWidthTest: JUnitTestCase {

	private func assertWidthIs(_ expectedWidth: Int, _ codePoint: Int, file: StaticString = #filePath, line: UInt = #line) {
		let wcWidth = WcWidth.width(codePoint);
		XCTAssertEqual(expectedWidth, wcWidth, file: file, line: line);
	}

	func testPrintableAscii() {
		for i in 0x20...0x7E {
			assertWidthIs(1, i);
		}
	}

	func testSomeWidthOne() {
		assertWidthIs(1, c("å"));
		assertWidthIs(1, c("ä"));
		assertWidthIs(1, c("ö"));
		assertWidthIs(1, 0x23F2);
	}

	func testSomeWide() {
		assertWidthIs(2, c("Ａ"));
		assertWidthIs(2, c("Ｂ"));
		assertWidthIs(2, c("Ｃ"));
		assertWidthIs(2, c("中"));
		assertWidthIs(2, c("文"));

		assertWidthIs(2, 0x679C);
		assertWidthIs(2, 0x679D);

		assertWidthIs(2, 0x2070E);
		assertWidthIs(2, 0x20731);

		assertWidthIs(1, 0x1F781);
	}

	func testSomeNonWide() {
		assertWidthIs(1, 0x1D11E);
		assertWidthIs(1, 0x1D11F);
	}

	func testCombining() {
		assertWidthIs(0, 0x0302);
		assertWidthIs(0, 0x0308);
		assertWidthIs(0, 0xFE0F);
	}

	func testWordJoiner() {
		assertWidthIs(0, 0x2060);
	}

	func testSofthyphen() {
		assertWidthIs(1, 0x00AD);
	}

	func testHangul() {
		assertWidthIs(1, 0x11A3);
	}

	func testEmojis() {
		assertWidthIs(2, 0x1F428);
		assertWidthIs(2, 0x231a);
		assertWidthIs(2, 0x1F643);
	}

}

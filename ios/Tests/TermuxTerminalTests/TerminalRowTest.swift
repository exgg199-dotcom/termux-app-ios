import XCTest
@testable import TermuxTerminal

final class TerminalRowTest: JUnitTestCase {

	private static let ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1 = 0x679C;
	private static let ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2 = 0x679D;
	private static let TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_1 = 0x2070E;
	private static let TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2 = 0x20731;

	static let TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1 = 0x1D11E;
	private static let TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_2 = 0x1D11F;

	private let COLUMNS = 80;

	private static let DIARESIS_CODEPOINT = 0x0308;

	private var row: TerminalRow!

	override func setUp() {
		super.setUp();
		row = TerminalRow(COLUMNS, TextStyle.NORMAL);
	}

	private func assertLineStartsWith(_ codePoints: Int..., file: StaticString = #filePath, line: UInt = #line) {
		let chars = row.text;
		var charIndex = 0;
		for i in 0..<codePoints.count {
			var lineCodePoint = Int(chars[charIndex]); charIndex += 1
			if UTF16Util.isHighSurrogate(UInt16(lineCodePoint)) {
				lineCodePoint = UTF16Util.toCodePoint(UInt16(lineCodePoint), chars[charIndex]); charIndex += 1
			}
			XCTAssertEqual(codePoints[i], lineCodePoint, "Differing a code point index=" + i, file: file, line: line);
		}
	}

	private func assertColumnCharIndicesStartsWith(_ indices: Int..., file: StaticString = #filePath, line: UInt = #line) {
		for i in 0..<indices.count {
			let expected = indices[i];
			let actual = row.findStartOfColumn(i);
			assertEquals("At index=" + i, expected, actual);
		}
	}

	func testSimpleDiaresis() {
		row.setChar(0, Self.DIARESIS_CODEPOINT, 0);
		assertEquals(81, row.spaceUsed);
		row.setChar(0, Self.DIARESIS_CODEPOINT, 0);
		assertEquals(82, row.spaceUsed);
		assertLineStartsWith(c(" "), Self.DIARESIS_CODEPOINT, Self.DIARESIS_CODEPOINT, c(" "));
	}

	func testStaticConstants() {
		assertEquals(1, UTF16Util.charCount(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1));
		assertEquals(1, UTF16Util.charCount(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2));
		assertEquals(2, WcWidth.width(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1));
		assertEquals(2, WcWidth.width(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2));

		assertEquals(2, UTF16Util.charCount(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1));
		assertEquals(2, UTF16Util.charCount(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_2));
		assertEquals(1, WcWidth.width(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1));
		assertEquals(1, WcWidth.width(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_2));

		assertEquals(2, UTF16Util.charCount(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_1));
		assertEquals(2, UTF16Util.charCount(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2));
		assertEquals(2, WcWidth.width(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_1));
		assertEquals(2, WcWidth.width(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2));

		assertEquals(1, UTF16Util.charCount(Self.DIARESIS_CODEPOINT));
		assertEquals(0, WcWidth.width(Self.DIARESIS_CODEPOINT));
	}

	func testOneColumn() {
		assertEquals(0, row.findStartOfColumn(0));
		row.setChar(0, c("a"), 0);
		assertEquals(0, row.findStartOfColumn(0));
	}

	func testAscii() {
		assertEquals(0, row.findStartOfColumn(0));
		row.setChar(0, c("a"), 0);
		assertLineStartsWith(c("a"), c(" "), c(" "));
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(80, row.spaceUsed);
		row.setChar(0, c("b"), 0);
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(2, row.findStartOfColumn(2));
		assertEquals(80, row.spaceUsed);
		assertColumnCharIndicesStartsWith(0, 1, 2, 3);

		let someChars = [c("a"), c("c"), c("e"), c("4"), c("5"), c("6"), c("7"), c("8")];

		var rawLine = [Int](repeating: c(" "), count: 80);
		for _ in 0..<1000 {
			let lineIndex = Int.random(in: 0..<rawLine.count);
			let charIndex = Int.random(in: 0..<someChars.count);
			rawLine[lineIndex] = someChars[charIndex];
			row.setChar(lineIndex, someChars[charIndex], 0);
		}
		let lineChars = row.text;
		for i in 0..<rawLine.count {
			assertEquals(rawLine[i], lineChars[i]);
		}
	}

	func testUnicode() {
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(80, row.spaceUsed);

		row.setChar(0, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1, 0);
		assertEquals(81, row.spaceUsed);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(2, row.findStartOfColumn(1));
		assertLineStartsWith(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1, c(" "), c(" "));
		assertColumnCharIndicesStartsWith(0, 2, 3, 4);

		row.setChar(0, c("a"), 0);
		assertEquals(80, row.spaceUsed);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(1, row.findStartOfColumn(1));
		assertLineStartsWith(c("a"), c(" "), c(" "));
		assertColumnCharIndicesStartsWith(0, 1, 2, 3);

		row.setChar(0, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1, 0);
		row.setChar(1, c("a"), 0);
		assertLineStartsWith(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1, c("a"), c(" "));

		row.setChar(0, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1, 0);
		row.setChar(1, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_2, 0);
		assertLineStartsWith(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_1, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_ONE_2, c(" "));
		assertColumnCharIndicesStartsWith(0, 2, 4, 5);
		assertEquals(82, row.spaceUsed);
	}

	func testDoubleWidth() {
		row.setChar(0, c("a"), 0);
		row.setChar(1, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, 0);
		assertLineStartsWith(c("a"), Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, c(" "));
		assertColumnCharIndicesStartsWith(0, 1, 1, 2);
		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		assertLineStartsWith(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, c(" "), c(" "));
		assertColumnCharIndicesStartsWith(0, 0, 1, 2);

		row.setChar(0, c(" "), 0);
		assertLineStartsWith(c(" "), c(" "), c(" "), c(" "));
		assertColumnCharIndicesStartsWith(0, 1, 2, 3, 4);
		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		row.setChar(2, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, 0);
		assertLineStartsWith(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2);
		assertColumnCharIndicesStartsWith(0, 0, 1, 1, 2);
		row.setChar(0, c("a"), 0);
		assertLineStartsWith(c("a"), c(" "), Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, c(" "));
	}

	func testDoubleWidthSurrogage() {
		row.setChar(0, c("a"), 0);
		assertColumnCharIndicesStartsWith(0, 1, 2, 3, 4);

		row.setChar(1, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2, 0);
		assertColumnCharIndicesStartsWith(0, 1, 1, 3, 4);
		assertLineStartsWith(c("a"), Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2, c(" "));
		row.setChar(0, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_1, 0);
		assertColumnCharIndicesStartsWith(0, 0, 2, 3, 4);
		assertLineStartsWith(Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_1, c(" "), c(" "), c(" "));

		row.setChar(0, c(" "), 0);
		assertLineStartsWith(c(" "), c(" "), c(" "), c(" "));
		row.setChar(0, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_1, 0);
		row.setChar(1, Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2, 0);
		assertLineStartsWith(c(" "), Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2, c(" "));
		row.setChar(0, c("a"), 0);
		assertLineStartsWith(c("a"), Self.TWO_JAVA_CHARS_DISPLAY_WIDTH_TWO_2, c(" "));
	}

	func testReplacementChar() {
		row.setChar(0, TerminalEmulator.UNICODE_REPLACEMENT_CHAR, 0);
		row.setChar(1, c("Y"), 0);
		assertLineStartsWith(TerminalEmulator.UNICODE_REPLACEMENT_CHAR, c("Y"), c(" "), c(" "));
	}

	func testSurrogateCharsWithNormalDisplayWidth() {
		let first = 0x1D306;
		let second = 0x1D307;
		assertEquals(2, UTF16Util.charCount(first));
		assertEquals(2, UTF16Util.charCount(second));

		row.setChar(0, second, 0);
		assertEquals(second, UTF16Util.toCodePoint(row.text[0], row.text[1]));
		assertEquals(c(" "), row.text[2]);
		assertEquals(2, row.findStartOfColumn(1));

		row.setChar(0, first, 0);
		assertEquals(first, UTF16Util.toCodePoint(row.text[0], row.text[1]));
		assertEquals(c(" "), row.text[2]);
		assertEquals(2, row.findStartOfColumn(1));

		row.setChar(1, second, 0);
		row.setChar(2, c("a"), 0);
		assertEquals(first, UTF16Util.toCodePoint(row.text[0], row.text[1]));
		assertEquals(second, UTF16Util.toCodePoint(row.text[2], row.text[3]));
		assertEquals(c("a"), row.text[4]);
		assertEquals(c(" "), row.text[5]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(2, row.findStartOfColumn(1));
		assertEquals(4, row.findStartOfColumn(2));
		assertEquals(5, row.findStartOfColumn(3));
		assertEquals(6, row.findStartOfColumn(4));

		row.setChar(0, c(" "), 0);
		assertEquals(c(" "), row.text[0]);
		assertEquals(second, UTF16Util.toCodePoint(row.text[1], row.text[2]));
		assertEquals(c("a"), row.text[3]);
		assertEquals(c(" "), row.text[4]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(3, row.findStartOfColumn(2));
		assertEquals(4, row.findStartOfColumn(3));
		assertEquals(5, row.findStartOfColumn(4));

		for i in 0..<80 {
			row.setChar(i, i % 2 == 0 ? first : second, 0);
		}
		for i in 0..<80 {
			let idx = row.findStartOfColumn(i);
			assertEquals(i % 2 == 0 ? first : second, UTF16Util.toCodePoint(row.text[idx], row.text[idx + 1]));
		}
		for i in 0..<80 {
			row.setChar(i, i % 2 == 0 ? c("a") : c("b"), 0);
		}
		for i in 0..<80 {
			let idx = row.findStartOfColumn(i);
			assertEquals(i, idx);
			assertEquals(i % 2 == 0 ? c("a") : c("b"), row.text[i]);
		}
	}

	func testOverwritingDoubleDisplayWidthWithNormalDisplayWidth() {
		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(c(" "), row.text[1]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(0, row.findStartOfColumn(1));
		assertEquals(1, row.findStartOfColumn(2));

		row.setChar(0, c("a"), 0);
		assertEquals(c("a"), row.text[0]);
		assertEquals(c(" "), row.text[1]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(2, row.findStartOfColumn(2));

		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(c(" "), row.text[1]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(0, row.findStartOfColumn(1));
		assertEquals(1, row.findStartOfColumn(2));

		row.setChar(1, c("a"), 0);
		assertEquals(c(" "), row.text[0]);
		assertEquals(c("a"), row.text[1]);
		assertEquals(c(" "), row.text[2]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(2, row.findStartOfColumn(2));
	}

	func testOverwritingDoubleDisplayWidthWithSelf() {
		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(c(" "), row.text[1]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(0, row.findStartOfColumn(1));
		assertEquals(1, row.findStartOfColumn(2));
	}

	func testNormalCharsWithDoubleDisplayWidth() {
		assertTrue(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1 != Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2);
		assertEquals(1, UTF16Util.charCount(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1));
		assertEquals(1, UTF16Util.charCount(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2));
		assertEquals(2, WcWidth.width(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1));
		assertEquals(2, WcWidth.width(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2));

		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(0, row.findStartOfColumn(1));
		assertEquals(c(" "), row.text[1]);

		row.setChar(0, c("a"), 0);
		assertEquals(c("a"), row.text[0]);
		assertEquals(c(" "), row.text[1]);
		assertEquals(1, row.findStartOfColumn(1));

		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(0, row.findStartOfColumn(1));
		row.setChar(2, c("a"), 0);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(c("a"), row.text[1]);
		assertEquals(1, row.findStartOfColumn(2));

		row.setChar(0, c("c"), 0);
		assertEquals(c("c"), row.text[0]);
		assertEquals(c(" "), row.text[1]);
		assertEquals(c("a"), row.text[2]);
		assertEquals(c(" "), row.text[3]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(2, row.findStartOfColumn(2));
	}

	func testNormalCharsWithDoubleDisplayWidthOverlapping() {
		row.setChar(0, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, 0);
		row.setChar(2, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, 0);
		row.setChar(4, c("a"), 0);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(0, row.findStartOfColumn(1));
		assertEquals(1, row.findStartOfColumn(2));
		assertEquals(1, row.findStartOfColumn(3));
		assertEquals(2, row.findStartOfColumn(4));
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_1, row.text[0]);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, row.text[1]);
		assertEquals(c("a"), row.text[2]);
		assertEquals(c(" "), row.text[3]);

		row.setChar(1, Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, 0);
		assertEquals(c(" "), row.text[0]);
		assertEquals(Self.ONE_JAVA_CHAR_DISPLAY_WIDTH_TWO_2, row.text[1]);
		assertEquals(c(" "), row.text[2]);
		assertEquals(c("a"), row.text[3]);
		assertEquals(c(" "), row.text[4]);
		assertEquals(0, row.findStartOfColumn(0));
		assertEquals(1, row.findStartOfColumn(1));
		assertEquals(1, row.findStartOfColumn(2));
		assertEquals(2, row.findStartOfColumn(3));
		assertEquals(3, row.findStartOfColumn(4));
	}

	func testCrashATE145() {
		assertEquals(2, UTF16Util.charCount(0xC2541));

		assertEquals(2, WcWidth.width(0x73EE));
		assertEquals(1, UTF16Util.charCount(0x73EE));

		assertEquals(0, WcWidth.width(0x009F));
		assertEquals(1, UTF16Util.charCount(0x009F));

		let points = [0xC2541, c("a"), c("8"), 0x73EE, 0x009F, 0x881F, 0x8324, 0xD4C9, 0xFFFD, c("B"), 0x009B, 0x61C9, c("Z")];
		var currentColumn = 0;
		for point in points {
			row.setChar(currentColumn, point, 0);
			currentColumn += WcWidth.width(point);
		}
	}

	func testNormalization() {
		row.setChar(0, 0x006E, 0);
		assertEquals(80, row.spaceUsed);
		row.setChar(0, 0x0303, 0);
		assertEquals(81, row.spaceUsed);
		assertLineStartsWith(0x006E, 0x0303, c(" "));
	}

	func testInsertWideAtLastColumn() {
		row.setChar(COLUMNS - 2, c("Z"), 0);
		row.setChar(COLUMNS - 1, c("a"), 0);
		assertEquals(c("Z"), row.text[row.findStartOfColumn(COLUMNS - 2)]);
		assertEquals(c("a"), row.text[row.findStartOfColumn(COLUMNS - 1)]);
		row.setChar(COLUMNS - 1, c("ö"), 0);
		assertEquals(c("Z"), row.text[row.findStartOfColumn(COLUMNS - 2)]);
		assertEquals(c("ö"), row.text[row.findStartOfColumn(COLUMNS - 1)]);
	}

}

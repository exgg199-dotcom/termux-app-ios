import XCTest
@testable import TermuxTerminal

final class TextStyleTest: JUnitTestCase {

	private static let ALL_EFFECTS = [0, TextStyle.CHARACTER_ATTRIBUTE_BOLD, TextStyle.CHARACTER_ATTRIBUTE_ITALIC,
			TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE, TextStyle.CHARACTER_ATTRIBUTE_BLINK, TextStyle.CHARACTER_ATTRIBUTE_INVERSE,
			TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE, TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH, TextStyle.CHARACTER_ATTRIBUTE_PROTECTED,
			TextStyle.CHARACTER_ATTRIBUTE_DIM];

	func testEncodingSingle() {
		for fx in Self.ALL_EFFECTS {
			for fg in 0..<TextStyle.NUM_INDEXED_COLORS {
				for bg in 0..<TextStyle.NUM_INDEXED_COLORS {
					let encoded = TextStyle.encode(fg, bg, fx);
					assertEquals(fg, TextStyle.decodeForeColor(encoded));
					assertEquals(bg, TextStyle.decodeBackColor(encoded));
					assertEquals(fx, TextStyle.decodeEffect(encoded));
				}
			}
		}
	}

	func testEncoding24Bit() {
		let values = [255, 240, 127, 1, 0];
		for red in values {
			for green in values {
				for blue in values {
					let argb = 0xFF000000 | (red << 16) | (green << 8) | blue;
					var encoded = TextStyle.encode(argb, 0, 0);
					assertEquals(argb, TextStyle.decodeForeColor(encoded));
					encoded = TextStyle.encode(0, argb, 0);
					assertEquals(argb, TextStyle.decodeBackColor(encoded));
				}
			}
		}
	}

	func testEncodingCombinations() {
		for f1 in Self.ALL_EFFECTS {
			for f2 in Self.ALL_EFFECTS {
				let combined = f1 | f2;
				assertEquals(combined, TextStyle.decodeEffect(TextStyle.encode(0, 0, combined)));
			}
		}
	}

	func testEncodingStrikeThrough() {
		let encoded = TextStyle.encode(TextStyle.COLOR_INDEX_FOREGROUND, TextStyle.COLOR_INDEX_BACKGROUND,
				TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH);
		assertTrue((TextStyle.decodeEffect(encoded) & TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH) != 0);
	}

	func testEncodingProtected() {
		var encoded = TextStyle.encode(TextStyle.COLOR_INDEX_FOREGROUND, TextStyle.COLOR_INDEX_BACKGROUND,
				TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH);
		assertEquals(0, (TextStyle.decodeEffect(encoded) & TextStyle.CHARACTER_ATTRIBUTE_PROTECTED));
		encoded = TextStyle.encode(TextStyle.COLOR_INDEX_FOREGROUND, TextStyle.COLOR_INDEX_BACKGROUND,
				TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH | TextStyle.CHARACTER_ATTRIBUTE_PROTECTED);
		assertTrue((TextStyle.decodeEffect(encoded) & TextStyle.CHARACTER_ATTRIBUTE_PROTECTED) != 0);
	}

}

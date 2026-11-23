import XCTest
@testable import TermuxTerminal

final class RectangularAreasTest: TerminalTestCase {

	func testFillRectangularArea() {
		withTerminalSized(3, 3).enterString("\u{1B}[88$x").assertLinesAre("XXX", "XXX", "XXX");
		withTerminalSized(3, 3).enterString("\u{1B}[88;1;1;2;10$x").assertLinesAre("XXX", "XXX", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[88;2;1;3;10$x").assertLinesAre("   ", "XXX", "XXX");
		withTerminalSized(3, 3).enterString("\u{1B}[88;1;1;100;1$x").assertLinesAre("X  ", "X  ", "X  ");
		withTerminalSized(3, 3).enterString("\u{1B}[88;1;1;100;2$x").assertLinesAre("XX ", "XX ", "XX ");
		withTerminalSized(3, 3).enterString("\u{1B}[88;100;1;100;2$x").assertLinesAre("   ", "   ", "   ");
	}

	func testEraseRectangularArea() {
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[$z").assertLinesAre("   ", "   ", "   ");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;2;10$z").assertLinesAre("   ", "   ", "GHI");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[2;1;3;10$z").assertLinesAre("ABC", "   ", "   ");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;100;1$z").assertLinesAre(" BC", " EF", " HI");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;100;2$z").assertLinesAre("  C", "  F", "  I");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[100;1;100;2$z").assertLinesAre("ABC", "DEF", "GHI");

		withTerminalSized(3, 3).enterString("A\u{1B}[$zBC").assertLinesAre(" BC", "   ", "   ");
	}

	func testSelectiveEraseInDisplay() {
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[?2J").assertLinesAre("   ", "   ", "   ");
		withTerminalSized(3, 3).enterString("ABC\u{1B}[1\"qDE\u{1B}[0\"qFGHI\u{1B}[?2J").assertLinesAre("   ", "DE ", "   ");
		withTerminalSized(3, 3).enterString("\u{1B}[1\"qABCDE\u{1B}[0\"qFGHI\u{1B}[?2J").assertLinesAre("ABC", "DE ", "   ");
	}

	func testSelectiveEraseInLine() {
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[?2K").assertLinesAre("ABC", "DEF", "   ");
		withTerminalSized(3, 3).enterString("ABCDE\u{1B}[?0KFGHI").assertLinesAre("ABC", "DEF", "GHI");
		withTerminalSized(3, 3).enterString("ABCDE\u{1B}[?1KFGHI").assertLinesAre("ABC", "  F", "GHI");
		withTerminalSized(3, 3).enterString("ABCDE\u{1B}[?2KFGHI").assertLinesAre("ABC", "  F", "GHI");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[2;2H\u{1B}[?0K").assertLinesAre("ABC", "D  ", "GHI");
		withTerminalSized(3, 3).enterString("ABC\u{1B}[1\"qD\u{1B}[0\"qE\u{1B}[?2KFGHI").assertLinesAre("ABC", "D F", "GHI");
	}

	func testSelectiveEraseInRectangle() {
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[${").assertLinesAre("   ", "   ", "   ");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;2;10${").assertLinesAre("   ", "   ", "GHI");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[2;1;3;10${").assertLinesAre("ABC", "   ", "   ");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;100;1${").assertLinesAre(" BC", " EF", " HI");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;100;2${").assertLinesAre("  C", "  F", "  I");
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[100;1;100;2${").assertLinesAre("ABC", "DEF", "GHI");

		withTerminalSized(3, 3).enterString("ABCD\u{1B}[1\"qE\u{1B}[0\"qFGHI\u{1B}[${").assertLinesAre("   ", " E ", "   ");
		withTerminalSized(3, 3).enterString("ABCD\u{1B}[1\"qE\u{1B}[0\"qFGHI\u{1B}[1;1;2;10${").assertLinesAre("   ", " E ", "GHI");
	}

	func testRectangularCopy() {
		withTerminalSized(7, 3).enterString("ABC\r\nDEF\r\nGHI\u{1B}[1;1;2;2;1;2;5;1$v").assertLinesAre("ABC    ", "DEF AB ", "GHI DE ");
		withTerminalSized(7, 3).enterString("ABC\r\nDEF\r\nGHI\u{1B}[1;1;3;3;1;1;4;1$v").assertLinesAre("ABCABC ", "DEFDEF ", "GHIGHI ");
		withTerminalSized(7, 3).enterString("ABC\r\nDEF\r\nGHI\u{1B}[1;1;3;3;1;1;3;1$v").assertLinesAre("ABABC  ", "DEDEF  ", "GHGHI  ");
		withTerminalSized(7, 3).enterString("   ABC\r\n   DEF\r\n   GHI\u{1B}[1;4;3;6;1;1;1;1$v").assertLinesAre("ABCABC ", "DEFDEF ",
				"GHIGHI ");
		withTerminalSized(7, 3).enterString("   ABC\r\n   DEF\r\n   GHI\u{1B}[1;4;3;6;1;1;2;1$v").assertLinesAre(" ABCBC ", " DEFEF ",
				" GHIHI ");
		withTerminalSized(3, 3).enterString("ABC\r\nDEF\r\nGHI\u{1B}[1;1;2;2;1;2;2;1$v").assertLinesAre("ABC", "DAB", "GDE");

		withTerminalSized(5, 5).enterString("\u{1B}[?6h\u{1B}[?69h\u{1B}[2;4s");
		enterString("ABCDEFGHIJK").assertLinesAre(" ABC ", " DEF ", " GHI ", " JK  ", "     ");
		enterString("\u{1B}[1;1;2;2;1;2;2;1$v").assertLinesAre(" ABC ", " DAB ", " GDE ", " JK  ", "     ");
	}

	func testChangeAttributesInRectangularArea() {
		let b = TextStyle.CHARACTER_ATTRIBUTE_BOLD;
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;2;2;1$r").assertLinesAre("ABC", "DEF", "GHI");
		assertEffectAttributesSet(effectLine(b, b, b), effectLine(b, b, 0), effectLine(0, 0, 0));

		withTerminalSized(3, 3).enterString("\u{1B}[2*xABCDEFGHI\u{1B}[1;1;2;2;1$r").assertLinesAre("ABC", "DEF", "GHI");
		assertEffectAttributesSet(effectLine(b, b, 0), effectLine(b, b, 0), effectLine(0, 0, 0));
	}

	func testReverseAttributesInRectangularArea() {
		let b = TextStyle.CHARACTER_ATTRIBUTE_BOLD;
		let u = TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE;
		let bu = TextStyle.CHARACTER_ATTRIBUTE_BOLD | TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE;
		withTerminalSized(3, 3).enterString("ABCDEFGHI\u{1B}[1;1;2;2;1$t").assertLinesAre("ABC", "DEF", "GHI");
		assertEffectAttributesSet(effectLine(b, b, b), effectLine(b, b, 0), effectLine(0, 0, 0));

		withTerminalSized(3, 3).enterString("\u{1B}[2*xABCDEFGHI\u{1B}[1;1;2;2;1$t").assertLinesAre("ABC", "DEF", "GHI");
		assertEffectAttributesSet(effectLine(b, b, 0), effectLine(b, b, 0), effectLine(0, 0, 0));

		withTerminalSized(3, 3).enterString("\u{1B}[2*xA\u{1B}[1mB\u{1B}[0mCDEFGHI\u{1B}[1;1;2;2;1$t").assertLinesAre("ABC", "DEF", "GHI");
		assertEffectAttributesSet(effectLine(b, 0, 0), effectLine(b, b, 0), effectLine(0, 0, 0));

		withTerminalSized(3, 3).enterString("\u{1B}[2*x\u{1B}[4mA\u{1B}[0m\u{1B}[1mB\u{1B}[0mCDEFGHI\u{1B}[1;1;2;2;1;4$t").assertLinesAre("ABC", "DEF",
				"GHI");
		assertEffectAttributesSet(effectLine(b, u, 0), effectLine(bu, bu, 0), effectLine(0, 0, 0));
	}

}

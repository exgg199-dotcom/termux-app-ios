import XCTest
@testable import TermuxTerminal

final class OperatingSystemControlTest: TerminalTestCase {

	func testSetTitle() {
		var expectedTitleChanges = [ChangedTitle]();

		withTerminalSized(10, 10);
		enterString("\u{1B}]0;Hello, world\u{7}");
		assertEquals("Hello, world", mTerminal.title);
		expectedTitleChanges.append(ChangedTitle(nil, "Hello, world"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}]0;Goodbye, world\u{7}");
		assertEquals("Goodbye, world", mTerminal.title);
		expectedTitleChanges.append(ChangedTitle("Hello, world", "Goodbye, world"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}]0;Goodbye, \u{F1} world\u{7}");
		assertEquals("Goodbye, \u{F1} world", mTerminal.title);
		expectedTitleChanges.append(ChangedTitle("Goodbye, world", "Goodbye, \u{F1} world"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}]2;Updated\u{7}");
		assertEquals("Updated", mTerminal.title);
		expectedTitleChanges.append(ChangedTitle("Goodbye, \u{F1} world", "Updated"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}[22;0t");
		enterString("\u{1B}]0;FIRST\u{7}");
		expectedTitleChanges.append(ChangedTitle("Updated", "FIRST"));
		assertEquals("FIRST", mTerminal.title);
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}[22;0t");
		enterString("\u{1B}]0;SECOND\u{7}");
		assertEquals("SECOND", mTerminal.title);

		expectedTitleChanges.append(ChangedTitle("FIRST", "SECOND"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}[23;0t");
		assertEquals("FIRST", mTerminal.title);

		expectedTitleChanges.append(ChangedTitle("SECOND", "FIRST"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}[23;0t");
		expectedTitleChanges.append(ChangedTitle("FIRST", "Updated"));
		assertEquals(expectedTitleChanges, mOutput.titleChanges);

		enterString("\u{1B}[22;0t");
		enterString("\u{1B}[22;0t");
		enterString("\u{1B}[22;0t");
		enterString("\u{1B}[23;0t");
		enterString("\u{1B}[23;0t");
		enterString("\u{1B}[23;0t");
		assertEquals(expectedTitleChanges, mOutput.titleChanges);
	}

	func testTitleStack() {

		withTerminalSized(10, 10);
		enterString("\u{1B}]0;InitialTitle\u{7}");
		assertEquals("InitialTitle", mTerminal.title);
		enterString("\u{1B}[22t");
		assertEquals("InitialTitle", mTerminal.title);
		enterString("\u{1B}]0;UpdatedTitle\u{7}");
		assertEquals("UpdatedTitle", mTerminal.title);
		enterString("\u{1B}[23t");
		assertEquals("InitialTitle", mTerminal.title);
		enterString("\u{1B}[23t\u{1B}[23t\u{1B}[23t");
		assertEquals("InitialTitle", mTerminal.title);
	}

	func testSetColor() {
		withTerminalSized(4, 4).enterString("\u{1B}]4;5;#00FF00\u{7}");
		assertEquals(String(0xFF00FF00, radix: 16), String(mTerminal.colors.currentColors[5], radix: 16));
		enterString("\u{1B}]4;5;#00FFAB\u{7}");
		assertEquals(mTerminal.colors.currentColors[5], 0xFF00FFAB);
		enterString("\u{1B}]4;255;#ABFFAB\u{7}");
		assertEquals(mTerminal.colors.currentColors[255], 0xFFABFFAB);
		enterString("\u{1B}]4;7;#00FF00;8;#0000FF\u{7}");
		assertEquals(mTerminal.colors.currentColors[7], 0xFF00FF00);
		assertEquals(mTerminal.colors.currentColors[8], 0xFF0000FF);
	}

	func assertIndexColorsMatch(_ expected: [UInt32], file: StaticString = #filePath, line: UInt = #line) {
		for i in 0..<255 {
			XCTAssertEqual(expected[i], mTerminal.colors.currentColors[i], "index=" + i, file: file, line: line)
		}
	}

	func testResetColor() {
		withTerminalSized(4, 4);
		var expectedColors = mTerminal.colors.currentColors
		for endType in 0..<3 {
			let ender = (endType == 0) ? "\u{7}" : "\u{1B}\\";
			for i in 0..<255 {
				expectedColors[i] = 0xFF000000 + (UInt32.random(in: 0...UInt32.max) & 0xFFFFFF);
				let r = (expectedColors[i] >> 16) & 0xFF;
				let g = (expectedColors[i] >> 8) & 0xFF;
				let b = expectedColors[i] & 0xFF;
				let rgbHex = hex2(r) + hex2(g) + hex2(b);
				enterString("\u{1B}]4;" + i + ";#" + rgbHex + ender);
				assertEquals(expectedColors[i], mTerminal.colors.currentColors[i]);
			}
		}

		enterString("\u{1B}]104;0\u{7}");
		expectedColors[0] = TerminalColors.colorScheme.defaultColors[0];
		assertIndexColorsMatch(expectedColors);
		enterString("\u{1B}]104;1;2\u{7}");
		expectedColors[1] = TerminalColors.colorScheme.defaultColors[1];
		expectedColors[2] = TerminalColors.colorScheme.defaultColors[2];
		assertIndexColorsMatch(expectedColors);
		enterString("\u{1B}]104\u{7}");
		assertIndexColorsMatch(TerminalColors.colorScheme.defaultColors);
	}

	func testSetClipboard() {
		withTerminalSized(4, 4)
		enterString("\u{1B}]52;c;" + Data("Hello, world".utf8).base64EncodedString() + "\u{7}")
		XCTAssertEqual(["Hello, world"], mOutput.clipboardPuts)
		enterString("\u{1B}]52;;SGk\u{1B}\\")
		XCTAssertEqual(["Hello, world", "Hi"], mOutput.clipboardPuts)
	}

	private func hex2(_ v: UInt32) -> String {
		let s = String(v, radix: 16)
		return s.count < 2 ? "0" + s : s
	}

	func testResettingTerminalResetsColor() {
		withTerminalSized(4, 4).enterString("\u{1B}]4;5;#00FF00\u{7}");
		enterString("\u{1B}]4;5;#00FFAB\u{7}").assertColor(5, 0xFF00FFAB);
		enterString("\u{1B}]4;255;#ABFFAB\u{7}").assertColor(255, 0xFFABFFAB);
		mTerminal.reset();
		assertIndexColorsMatch(TerminalColors.colorScheme.defaultColors);
	}

	func testSettingDynamicColors() {
		withTerminalSized(3, 3).enterString("\u{1B}]10;#ABCD00\u{7}").assertColor(TextStyle.COLOR_INDEX_FOREGROUND, 0xFFABCD00);
		enterString("\u{1B}]11;#0ABCD0\u{7}").assertColor(TextStyle.COLOR_INDEX_BACKGROUND, 0xFF0ABCD0);
		enterString("\u{1B}]12;#00ABCD\u{7}").assertColor(TextStyle.COLOR_INDEX_CURSOR, 0xFF00ABCD);
		enterString("\u{1B}]10;#FF0000;#00FF00\u{7}").assertColor(TextStyle.COLOR_INDEX_FOREGROUND, 0xFFFF0000);
		assertColor(TextStyle.COLOR_INDEX_BACKGROUND, 0xFF00FF00);
		enterString("\u{1B}]10;#0000FF;#00FF00;#FF0000\u{7}").assertColor(TextStyle.COLOR_INDEX_FOREGROUND, 0xFF0000FF);
		assertColor(TextStyle.COLOR_INDEX_BACKGROUND, 0xFF00FF00).assertColor(TextStyle.COLOR_INDEX_CURSOR, 0xFFFF0000);

		enterString("\u{1B}]10;#FF0000\u{7}").assertColor(TextStyle.COLOR_INDEX_FOREGROUND, 0xFFFF0000);
		enterString("\u{1B}]11;#FFFF00;\u{7}").assertColor(TextStyle.COLOR_INDEX_BACKGROUND, 0xFFFFFF00);
		enterString("\u{1B}]12;#00FFFF;\u{7}").assertColor(TextStyle.COLOR_INDEX_CURSOR, 0xFF00FFFF);

		let stringTerminator = "\u{1B}\\";
		enterString("\u{1B}]10;#FF0000" + stringTerminator).assertColor(TextStyle.COLOR_INDEX_FOREGROUND, 0xFFFF0000);
		enterString("\u{1B}]11;#FFFF00;" + stringTerminator).assertColor(TextStyle.COLOR_INDEX_BACKGROUND, 0xFFFFFF00);
		enterString("\u{1B}]12;#00FFFF;" + stringTerminator).assertColor(TextStyle.COLOR_INDEX_CURSOR, 0xFF00FFFF);
	}

	func testReportSpecialColors() {
		withTerminalSized(3, 3).enterString("\u{1B}]10;#ABCD00\u{7}").assertColor(TextStyle.COLOR_INDEX_FOREGROUND, 0xFFABCD00);
		assertEnteringStringGivesResponse("\u{1B}]10;?\u{7}", "\u{1B}]10;rgb:abab/cdcd/0000\u{7}");
		assertEnteringStringGivesResponse("\u{1B}]10;?\u{1B}\\", "\u{1B}]10;rgb:abab/cdcd/0000\u{1B}\\");
	}

}

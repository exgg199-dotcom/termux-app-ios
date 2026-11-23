import XCTest

final class KeyMappingTests: XCTestCase {
    func testHIDToAndroidKeyCodes() {
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x52), AndroidKeyEvent.KEYCODE_DPAD_UP)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x51), AndroidKeyEvent.KEYCODE_DPAD_DOWN)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x50), AndroidKeyEvent.KEYCODE_DPAD_LEFT)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x4F), AndroidKeyEvent.KEYCODE_DPAD_RIGHT)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x29), AndroidKeyEvent.KEYCODE_ESCAPE)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x2B), AndroidKeyEvent.KEYCODE_TAB)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x28), AndroidKeyEvent.KEYCODE_ENTER)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x2A), AndroidKeyEvent.KEYCODE_DEL)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x4C), AndroidKeyEvent.KEYCODE_FORWARD_DEL)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x4A), AndroidKeyEvent.KEYCODE_MOVE_HOME)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x4D), AndroidKeyEvent.KEYCODE_MOVE_END)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x4B), AndroidKeyEvent.KEYCODE_PAGE_UP)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x4E), AndroidKeyEvent.KEYCODE_PAGE_DOWN)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x3A), AndroidKeyEvent.KEYCODE_F1)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x45), AndroidKeyEvent.KEYCODE_F12)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x59), AndroidKeyEvent.KEYCODE_NUMPAD_1)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x62), AndroidKeyEvent.KEYCODE_NUMPAD_0)
        XCTAssertEqual(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x58), AndroidKeyEvent.KEYCODE_NUMPAD_ENTER)
        XCTAssertNil(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x04))
        XCTAssertNil(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x1E))
        XCTAssertNil(HardwareKeyMapper.androidKeyCode(forHIDUsage: 0x2C))
        XCTAssertTrue(HardwareKeyMapper.isModifierKey(0xE0))
        XCTAssertTrue(HardwareKeyMapper.isModifierKey(0xE7))
        XCTAssertFalse(HardwareKeyMapper.isModifierKey(0x04))
    }

    func testAndroidKeyCodeValues() {
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_DPAD_UP, 19)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_ENTER, 66)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_DEL, 67)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_ESCAPE, 111)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_MOVE_HOME, 122)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_F1, 131)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_NUMPAD_0, 144)
        XCTAssertEqual(AndroidKeyEvent.KEYCODE_NUMPAD_EQUALS, 161)
    }

    func testFallbackCodePoints() {
        XCTAssertEqual(HardwareKeyMapper.fallbackCodePoint(forKeyCode: AndroidKeyEvent.KEYCODE_SPACE), 32)
        XCTAssertEqual(HardwareKeyMapper.fallbackCodePoint(forKeyCode: AndroidKeyEvent.KEYCODE_NUMPAD_7), 55)
        XCTAssertNil(HardwareKeyMapper.fallbackCodePoint(forKeyCode: AndroidKeyEvent.KEYCODE_DPAD_UP))
    }

    func testControlMapping() {
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("c").value)), 3)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("C").value)), 3)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("a").value)), 1)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("z").value)), 26)
        XCTAssertEqual(TerminalInput.applyControl(32), 0)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("2").value)), 0)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("[").value)), 27)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("\\").value)), 28)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("]").value)), 29)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("^").value)), 30)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("/").value)), 31)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("_").value)), 31)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("8").value)), 127)
        XCTAssertEqual(TerminalInput.applyControl(Int(UnicodeScalar("é").value)), Int(UnicodeScalar("é").value))
    }

    func testTransformCodePoint() {
        XCTAssertEqual(TerminalInput.transformCodePoint(Int(UnicodeScalar("d").value), controlDown: true, source: .softKeyboard), 4)
        XCTAssertEqual(TerminalInput.transformCodePoint(0x02DC, controlDown: false, source: .hardwareKeyboard), 0x7E)
        XCTAssertEqual(TerminalInput.transformCodePoint(0x02DC, controlDown: false, source: .softKeyboard), 0x02DC)
        XCTAssertNil(TerminalInput.transformCodePoint(-1, controlDown: false, source: .softKeyboard))
    }

    func testSoftKeyboardCodePoint() {
        let enter = TerminalInput.softKeyboardCodePoint(10)
        XCTAssertEqual(enter.codePoint, Int(UnicodeScalar("m").value))
        XCTAssertTrue(enter.controlHeld)
        XCTAssertEqual(TerminalInput.applyControl(enter.codePoint), 13)

        let tab = TerminalInput.softKeyboardCodePoint(9)
        XCTAssertEqual(tab.codePoint, Int(UnicodeScalar("i").value))
        XCTAssertEqual(TerminalInput.applyControl(tab.codePoint), 9)

        XCTAssertEqual(TerminalInput.softKeyboardCodePoint(31).codePoint, Int(UnicodeScalar("_").value))
        XCTAssertEqual(TerminalInput.softKeyboardCodePoint(28).codePoint, Int(UnicodeScalar("\\").value))

        let escape = TerminalInput.softKeyboardCodePoint(27)
        XCTAssertEqual(escape.codePoint, 27)
        XCTAssertFalse(escape.controlHeld)

        let letter = TerminalInput.softKeyboardCodePoint(Int(UnicodeScalar("x").value))
        XCTAssertEqual(letter.codePoint, Int(UnicodeScalar("x").value))
        XCTAssertFalse(letter.controlHeld)
    }

    func testUpperCaseAndCodePoints() {
        XCTAssertEqual(TerminalInput.toUpperCase(Int(UnicodeScalar("a").value)), Int(UnicodeScalar("A").value))
        XCTAssertEqual(TerminalInput.toUpperCase(Int(UnicodeScalar("é").value)), Int(UnicodeScalar("É").value))
        XCTAssertEqual(TerminalInput.toUpperCase(Int(UnicodeScalar("1").value)), Int(UnicodeScalar("1").value))
        XCTAssertEqual(TerminalInput.toUpperCase(0xDF), 0xDF)
        XCTAssertEqual(TerminalInput.codePoints("a😀"), [0x61, 0x1F600])
    }

    func testVirtualFnKeys() {
        func virtualFunctionKey(_ character: String) -> VirtualFunctionKeyResult {
            return TerminalInput.virtualFunctionKey(Int(UnicodeScalar(character)!.value))
        }
        XCTAssertEqual(virtualFunctionKey("w"), .keyCode(AndroidKeyEvent.KEYCODE_DPAD_UP))
        XCTAssertEqual(virtualFunctionKey("W"), .keyCode(AndroidKeyEvent.KEYCODE_DPAD_UP))
        XCTAssertEqual(virtualFunctionKey("a"), .keyCode(AndroidKeyEvent.KEYCODE_DPAD_LEFT))
        XCTAssertEqual(virtualFunctionKey("1"), .keyCode(AndroidKeyEvent.KEYCODE_F1))
        XCTAssertEqual(virtualFunctionKey("9"), .keyCode(AndroidKeyEvent.KEYCODE_F9))
        XCTAssertEqual(virtualFunctionKey("0"), .keyCode(AndroidKeyEvent.KEYCODE_F10))
        XCTAssertEqual(virtualFunctionKey("e"), .codePoint(27, altDown: false))
        XCTAssertEqual(virtualFunctionKey("b"), .codePoint(Int(UnicodeScalar("b").value), altDown: true))
        XCTAssertEqual(virtualFunctionKey("u"), .codePoint(Int(UnicodeScalar("_").value), altDown: false))
        XCTAssertEqual(virtualFunctionKey("k"), .toggleKeyboard)
        XCTAssertEqual(virtualFunctionKey("v"), .consumed)
        XCTAssertEqual(virtualFunctionKey("z"), .none)
    }
}

import XCTest

final class ExtraKeysTests: XCTestCase {
    func testDefaultExtraKeys() throws {
        let info = try ExtraKeysInfo(propertiesInfo: ExtraKeysInfo.DEFAULT_EXTRA_KEYS, style: "default")
        XCTAssertEqual(info.matrix.count, 2)
        XCTAssertEqual(info.matrix[0].map { $0.key }, ["ESC", "/", "-", "HOME", "UP", "END", "PGUP"])
        XCTAssertEqual(info.matrix[1].map { $0.key }, ["TAB", "CTRL", "ALT", "LEFT", "DOWN", "RIGHT", "PGDN"])
        XCTAssertEqual(info.maximumRowLength, 7)

        XCTAssertEqual(info.matrix[0][4].display, "↑")
        XCTAssertEqual(info.matrix[0][2].display, "―")
        XCTAssertEqual(info.matrix[0][0].display, "ESC")
        XCTAssertEqual(info.matrix[1][0].display, "↹")

        XCTAssertEqual(info.matrix[0][2].popup?.key, "|")
        XCTAssertNil(info.matrix[0][0].popup)
        XCTAssertFalse(info.matrix[0][0].isMacro)
    }

    func testTaskDefaultWithoutPopup() throws {
        let value = "[['ESC','/','-','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]"
        let info = try ExtraKeysInfo(propertiesInfo: value, style: "default")
        XCTAssertEqual(info.matrix.map { $0.count }, [7, 7])
        XCTAssertNil(info.matrix[0][2].popup)
    }

    func testUnquotedAndDoubleQuotedKeys() throws {
        let info = try ExtraKeysInfo(propertiesInfo: "[[ESC, TAB, CTRL, ALT, {key: '-', popup: '|'}, DOWN, UP], [\"a\", 'b']]", style: "default")
        XCTAssertEqual(info.matrix[0].map { $0.key }, ["ESC", "TAB", "CTRL", "ALT", "-", "DOWN", "UP"])
        XCTAssertEqual(info.matrix[1].map { $0.key }, ["a", "b"])
    }

    func testAliases() throws {
        let info = try ExtraKeysInfo(propertiesInfo: "[[ESCAPE, CONTROL, LT, 'PAGE UP', BACKSLASH, QUOTE, APOSTROPHE, RETURN]]", style: "none")
        XCTAssertEqual(info.matrix[0].map { $0.key }, ["ESC", "CTRL", "LEFT", "PGUP", "\\", "\"", "'", "ENTER"])
        XCTAssertEqual(info.matrix[0][2].display, "LEFT")
    }

    func testMacroAndDisplay() throws {
        let info = try ExtraKeysInfo(propertiesInfo: "[[{macro: 'CTRL f d', display: 'tmux exit'}, {macro: \"ALT a\"}, {key: KEYBOARD, popup: {macro: 'CTRL d', display: exit}}]]", style: "default")
        let row = info.matrix[0]
        XCTAssertTrue(row[0].isMacro)
        XCTAssertEqual(row[0].key, "CTRL f d")
        XCTAssertEqual(row[0].display, "tmux exit")
        XCTAssertEqual(row[1].key, "ALT a")
        XCTAssertEqual(row[1].display, "ALT a")
        XCTAssertEqual(row[2].display, "⌨")
        XCTAssertEqual(row[2].popup?.key, "CTRL d")
        XCTAssertEqual(row[2].popup?.isMacro, true)
        XCTAssertEqual(row[2].popup?.display, "exit")
    }

    func testMacroAliasAndDisplayMapping() throws {
        let info = try ExtraKeysInfo(propertiesInfo: "[[{macro: 'ESCAPE LEFT'}]]", style: "default")
        XCTAssertEqual(info.matrix[0][0].key, "ESC LEFT")
        XCTAssertEqual(info.matrix[0][0].display, "ESC ←")
    }

    func testKeyAndMacroIsAnError() {
        XCTAssertThrowsError(try ExtraKeysInfo(propertiesInfo: "[[{key: a, macro: 'b c'}]]", style: "default"))
        XCTAssertThrowsError(try ExtraKeysInfo(propertiesInfo: "[[{display: a}]]", style: "default"))
    }

    func testInvalidSyntax() {
        XCTAssertThrowsError(try ExtraKeysInfo(propertiesInfo: "[[ESC, TAB", style: "default"))
        XCTAssertThrowsError(try ExtraKeysInfo(propertiesInfo: "ESC", style: "default"))
        XCTAssertThrowsError(try ExtraKeysInfo(propertiesInfo: "[ESC]", style: "default"))
        XCTAssertThrowsError(try ExtraKeysInfo(propertiesInfo: "[['unterminated]]", style: "default"))
    }

    func testCommentsAndWhitespace() throws {
        let value = """
        [ # first row
          ['ESC', /* tab */ 'TAB'], // second row
          ['UP';'DOWN']
        ]
        """
        let info = try ExtraKeysInfo(propertiesInfo: value, style: "default")
        XCTAssertEqual(info.matrix.map { $0.map { $0.key } }, [["ESC", "TAB"], ["UP", "DOWN"]])
    }

    func testTrailingCommaIsTolerated() throws {
        let info = try ExtraKeysInfo(propertiesInfo: "[['ESC','TAB',]]", style: "default")
        XCTAssertEqual(info.matrix[0].map { $0.key }, ["ESC", "TAB"])
    }

    func testEscapesInStrings() throws {
        let info = try ExtraKeysInfo(propertiesInfo: "[['\\u2192', '\\'', \"\\\\\"]]", style: "none")
        XCTAssertEqual(info.matrix[0].map { $0.key }, ["→", "'", "\\"])
    }

    func testStyles() {
        XCTAssertEqual(ExtraKeysInfo.getCharDisplayMapForStyle("arrows-only")["UP"], "↑")
        XCTAssertNil(ExtraKeysInfo.getCharDisplayMapForStyle("arrows-only")["TAB"])
        XCTAssertEqual(ExtraKeysInfo.getCharDisplayMapForStyle("all")["CTRL"], "⎈")
        XCTAssertEqual(ExtraKeysInfo.getCharDisplayMapForStyle("arrows-all")["PGUP"], "⇑")
        XCTAssertTrue(ExtraKeysInfo.getCharDisplayMapForStyle("none").isEmpty)
        XCTAssertEqual(ExtraKeysInfo.getCharDisplayMapForStyle("unknown"), ExtraKeysConstants.EXTRA_KEY_DISPLAY_MAPS.DEFAULT_CHAR_DISPLAY)
    }

    func testLoadWithFallback() {
        let invalid = ExtraKeysInfo.loadWithFallback(extraKeys: "[[", style: "default")
        XCTAssertNotNil(invalid.error)
        XCTAssertEqual(invalid.info?.matrix.count, 2)

        let badStyle = ExtraKeysInfo.loadWithFallback(extraKeys: "[[ESC]]", style: "fancy")
        XCTAssertNotNil(badStyle.error)
        XCTAssertEqual(badStyle.info?.matrix[0].map { $0.key }, ["ESC"])

        let empty = ExtraKeysInfo.loadWithFallback(extraKeys: nil, style: nil)
        XCTAssertNil(empty.error)
        XCTAssertEqual(empty.info?.matrix.count, 2)
    }

    func testPrimaryKeyCodes() {
        XCTAssertEqual(ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS["UP"], AndroidKeyEvent.KEYCODE_DPAD_UP)
        XCTAssertEqual(ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS["ESC"], 111)
        XCTAssertEqual(ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS["F12"], 142)
        XCTAssertEqual(ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS["BKSP"], 67)
        XCTAssertNil(ExtraKeysConstants.PRIMARY_KEY_CODES_FOR_STRINGS["CTRL"])
    }
}

final class SpecialButtonTests: XCTestCase {
    private func makeMachine() -> SpecialButtonsStateMachine {
        let machine = SpecialButtonsStateMachine()
        for button in SpecialButton.defaultButtons {
            machine.setCreated(button)
        }
        return machine
    }

    func testOneShot() {
        let machine = makeMachine()
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), false)
        machine.tap(.CTRL, at: 0)
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), true)
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), false)
    }

    func testReadWithoutAutoSetInactive() {
        let machine = makeMachine()
        machine.tap(.ALT, at: 0)
        XCTAssertEqual(machine.read(.ALT, autoSetInactive: false), true)
        XCTAssertEqual(machine.read(.ALT, autoSetInactive: false), true)
    }

    func testTapTwiceSlowlyDeactivates() {
        let machine = makeMachine()
        machine.tap(.CTRL, at: 0)
        machine.tap(.CTRL, at: 1)
        XCTAssertEqual(machine.state(for: .CTRL)?.isActive, false)
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), false)
    }

    func testDoubleTapLocks() {
        let machine = makeMachine()
        machine.tap(.CTRL, at: 0)
        machine.tap(.CTRL, at: 0.2)
        XCTAssertEqual(machine.state(for: .CTRL)?.isLocked, true)
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), true)
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), true)
        machine.tap(.CTRL, at: 5)
        XCTAssertEqual(machine.state(for: .CTRL)?.isLocked, false)
        XCTAssertEqual(machine.read(.CTRL, autoSetInactive: true), false)
    }

    func testLongPressLocks() {
        let machine = makeMachine()
        machine.longPress(.SHIFT)
        XCTAssertEqual(machine.state(for: .SHIFT)?.isActive, true)
        XCTAssertEqual(machine.state(for: .SHIFT)?.isLocked, true)
        XCTAssertEqual(machine.read(.SHIFT, autoSetInactive: true), true)
        XCTAssertEqual(machine.read(.SHIFT, autoSetInactive: true), true)
        machine.longPress(.SHIFT)
        XCTAssertEqual(machine.state(for: .SHIFT)?.isActive, false)
        XCTAssertEqual(machine.state(for: .SHIFT)?.isLocked, false)
    }

    func testNotCreatedReadsFalse() {
        let machine = SpecialButtonsStateMachine()
        machine.tap(.FN, at: 0)
        XCTAssertEqual(machine.read(.FN, autoSetInactive: true), false)
        XCTAssertNil(machine.read(SpecialButton("META"), autoSetInactive: true))
    }

    func testIsSpecialButton() throws {
        let machine = makeMachine()
        let info = try ExtraKeysInfo(propertiesInfo: "[[CTRL, ESC, FUNCTION]]", style: "default")
        XCTAssertTrue(machine.isSpecialButton(info.matrix[0][0]))
        XCTAssertFalse(machine.isSpecialButton(info.matrix[0][1]))
        XCTAssertTrue(machine.isSpecialButton(info.matrix[0][2]))
    }

    func testStateChangeCallback() {
        let machine = makeMachine()
        var changes: [String] = []
        machine.onStateChanged = { button, state in
            changes.append("\(button.key)=\(state.isActive)")
        }
        machine.tap(.CTRL, at: 0)
        _ = machine.read(.CTRL, autoSetInactive: true)
        XCTAssertEqual(changes, ["CTRL=true", "CTRL=false"])
    }
}

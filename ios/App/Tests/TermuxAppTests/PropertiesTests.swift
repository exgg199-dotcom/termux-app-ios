import XCTest

final class JavaPropertiesParserTests: XCTestCase {
    func testSeparatorsAndComments() {
        let text = """
        # comment
        ! also a comment
        a=1
        b = 2
        c:3
        d 4
          e  =  5
        f
        g=
        key\\ with\\ spaces = value
        """
        let properties = JavaPropertiesParser.parse(text)
        XCTAssertEqual(properties["a"], "1")
        XCTAssertEqual(properties["b"], "2")
        XCTAssertEqual(properties["c"], "3")
        XCTAssertEqual(properties["d"], "4")
        XCTAssertEqual(properties["e"], "5")
        XCTAssertEqual(JavaPropertiesParser.parse("  e  =  5  ")["e"], "5  ")
        XCTAssertEqual(properties["f"], "")
        XCTAssertEqual(properties["g"], "")
        XCTAssertEqual(properties["key with spaces"], "value")
        XCTAssertNil(properties["# comment"])
        XCTAssertEqual(properties.count, 8)
    }

    func testLineContinuation() {
        let text = "extra-keys = [['ESC','/'], \\\n      ['TAB','CTRL']]\nnext=1\n"
        let properties = JavaPropertiesParser.parse(text)
        XCTAssertEqual(properties["extra-keys"], "[['ESC','/'], ['TAB','CTRL']]")
        XCTAssertEqual(properties["next"], "1")
    }

    func testEvenBackslashesDoNotContinue() {
        let properties = JavaPropertiesParser.parse("a=x\\\\\nb=y")
        XCTAssertEqual(properties["a"], "x\\")
        XCTAssertEqual(properties["b"], "y")
    }

    func testEscapes() {
        let properties = JavaPropertiesParser.parse("a=tab\\there\nb=\\u0041\\u00e9\nc=\\:\\=\\#")
        XCTAssertEqual(properties["a"], "tab\there")
        XCTAssertEqual(properties["b"], "Aé")
        XCTAssertEqual(properties["c"], ":=#")
    }

    func testCRLFAndLaterKeysWin() {
        let properties = JavaPropertiesParser.parse("a=1\r\nb=2\ra=3")
        XCTAssertEqual(properties["a"], "3")
        XCTAssertEqual(properties["b"], "2")
    }
}

final class TermuxPropertiesTests: XCTestCase {
    func testDefaults() {
        let properties = TermuxProperties()
        XCTAssertEqual(properties.extraKeys, ExtraKeysInfo.DEFAULT_EXTRA_KEYS)
        XCTAssertEqual(properties.extraKeysStyle, "default")
        XCTAssertTrue(properties.extraKeysTextAllCaps)
        XCTAssertEqual(properties.bellBehaviour, .vibrate)
        XCTAssertEqual(properties.terminalTranscriptRows, 2000)
        XCTAssertEqual(properties.terminalCursorStyle, TermuxProperties.TERMINAL_CURSOR_STYLE_BLOCK)
        XCTAssertEqual(properties.terminalCursorBlinkRate, 0)
        XCTAssertEqual(properties.terminalMarginHorizontal, 3)
        XCTAssertEqual(properties.terminalMarginVertical, 0)
        XCTAssertEqual(properties.terminalToolbarHeightScaleFactor, 1.0)
        XCTAssertEqual(properties.nightMode, "system")
        XCTAssertFalse(properties.fullscreen)
        XCTAssertFalse(properties.hideSoftKeyboardOnStartup)
        XCTAssertFalse(properties.terminalOnclickUrlOpen)
        XCTAssertEqual(properties.softKeyboardToggleBehaviour, .showHide)
        XCTAssertTrue(properties.sessionShortcuts.isEmpty)
        XCTAssertTrue(properties.warnings.isEmpty)
    }

    func testDefaultPropertiesFileIsAllCommentedOut() {
        let parsed = JavaPropertiesParser.parse(Bootstrap.defaultTermuxProperties)
        XCTAssertTrue(parsed.isEmpty, "Unexpected active properties: \(parsed)")
    }

    func testParsedValues() {
        let text = """
        extra-keys = [['ESC','TAB'], \\
                      ['CTRL','ALT']]
        extra-keys-style = arrows-only
        extra-keys-text-all-caps = false
        bell-character = Ignore
        terminal-transcript-rows = 10000
        terminal-cursor-style = bar
        terminal-cursor-blink-rate = 600
        terminal-margin-horizontal = 10
        terminal-toolbar-height = 1.5
        use-black-ui = true
        fullscreen = TRUE
        hide-soft-keyboard-on-startup = true
        terminal-onclick-url-open = true
        soft-keyboard-toggle-behaviour = enable/disable
        shortcut.create-session = ctrl + t
        shortcut.next-session = ctrl+2
        """
        let properties = TermuxProperties(properties: JavaPropertiesParser.parse(text))
        XCTAssertEqual(properties.extraKeys, "[['ESC','TAB'], ['CTRL','ALT']]")
        XCTAssertEqual(properties.extraKeysStyle, "arrows-only")
        XCTAssertFalse(properties.extraKeysTextAllCaps)
        XCTAssertEqual(properties.bellBehaviour, .ignore)
        XCTAssertEqual(properties.terminalTranscriptRows, 10000)
        XCTAssertEqual(properties.terminalCursorStyle, TermuxProperties.TERMINAL_CURSOR_STYLE_BAR)
        XCTAssertEqual(properties.terminalCursorBlinkRate, 600)
        XCTAssertEqual(properties.terminalMarginHorizontal, 10)
        XCTAssertEqual(properties.terminalToolbarHeightScaleFactor, 1.5)
        XCTAssertEqual(properties.nightMode, "true")
        XCTAssertTrue(properties.fullscreen)
        XCTAssertTrue(properties.hideSoftKeyboardOnStartup)
        XCTAssertTrue(properties.terminalOnclickUrlOpen)
        XCTAssertEqual(properties.softKeyboardToggleBehaviour, .enableDisable)
        XCTAssertEqual(properties.sessionShortcuts, [
            SessionShortcut(codePoint: Int(UnicodeScalar("t").value), action: .createSession),
            SessionShortcut(codePoint: Int(UnicodeScalar("2").value), action: .nextSession),
        ])
        XCTAssertEqual(properties.sessionShortcutAction(forCodePoint: Int(UnicodeScalar("T").value)), .createSession)
        XCTAssertNil(properties.sessionShortcutAction(forCodePoint: Int(UnicodeScalar("x").value)))
        XCTAssertTrue(properties.warnings.isEmpty, "\(properties.warnings)")

        let info = ExtraKeysInfo.loadWithFallback(extraKeys: properties.extraKeys, style: properties.extraKeysStyle)
        XCTAssertNil(info.error)
        XCTAssertEqual(info.info?.matrix.map { $0.map { $0.key } }, [["ESC", "TAB"], ["CTRL", "ALT"]])
    }

    func testInvalidValuesFallBackToDefaults() {
        let text = """
        bell-character = ring
        terminal-transcript-rows = 10
        terminal-cursor-style = triangle
        terminal-cursor-blink-rate = 50
        terminal-margin-horizontal = abc
        terminal-toolbar-height = 10
        fullscreen = yes
        night-mode = maybe
        shortcut.rename-session = alt + r
        """
        let properties = TermuxProperties(properties: JavaPropertiesParser.parse(text))
        XCTAssertEqual(properties.bellBehaviour, .vibrate)
        XCTAssertEqual(properties.terminalTranscriptRows, 2000)
        XCTAssertEqual(properties.terminalCursorStyle, 0)
        XCTAssertEqual(properties.terminalCursorBlinkRate, 0)
        XCTAssertEqual(properties.terminalMarginHorizontal, 3)
        XCTAssertEqual(properties.terminalToolbarHeightScaleFactor, 1.0)
        XCTAssertFalse(properties.fullscreen)
        XCTAssertEqual(properties.nightMode, "system")
        XCTAssertTrue(properties.sessionShortcuts.isEmpty)
        XCTAssertEqual(properties.warnings.count, 9)
    }

    func testNightModeWinsOverUseBlackUI() {
        let properties = TermuxProperties(properties: ["night-mode": "false", "use-black-ui": "true"])
        XCTAssertEqual(properties.nightMode, "false")
    }

    func testEmptyExtraKeysUsesDefault() {
        let properties = TermuxProperties(properties: ["extra-keys": "", "extra-keys-style": ""])
        XCTAssertEqual(properties.extraKeys, TermuxProperties.DEFAULT_IVALUE_EXTRA_KEYS)
        XCTAssertEqual(properties.extraKeysStyle, "default")
    }

    func testShortcutParsing() {
        XCTAssertEqual(TermuxProperties.getCodePointForSessionShortcuts("ctrl + t"), 116)
        XCTAssertEqual(TermuxProperties.getCodePointForSessionShortcuts(" CTRL+N "), 110)
        XCTAssertNil(TermuxProperties.getCodePointForSessionShortcuts("ctrl + tt"))
        XCTAssertNil(TermuxProperties.getCodePointForSessionShortcuts("t"))
        XCTAssertNil(TermuxProperties.getCodePointForSessionShortcuts("ctrl + "))
    }

    func testLoadFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("termux.properties")
        try Data("terminal-cursor-style=underline\n".utf8).write(to: file)
        XCTAssertEqual(TermuxProperties.load(from: file).terminalCursorStyle, TermuxProperties.TERMINAL_CURSOR_STYLE_UNDERLINE)
        XCTAssertEqual(TermuxProperties.load(from: dir.appendingPathComponent("missing")).terminalCursorStyle, 0)
    }
}

final class BootstrapTests: XCTestCase {
    private var documents: URL!

    override func setUpWithError() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: documents)
    }

    func testBootstrapCreatesHomeAndProperties() throws {
        let paths = TermuxPaths(documentsDirectory: documents)
        try Bootstrap.run(paths: paths)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.homeDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.primaryPropertiesFile.path))
        XCTAssertEqual(paths.propertiesFile, paths.primaryPropertiesFile)
        XCTAssertEqual(paths.displayPath(paths.primaryPropertiesFile), "~/.termux/termux.properties")
    }

    func testBootstrapDoesNotOverwrite() throws {
        let paths = TermuxPaths(documentsDirectory: documents)
        try FileManager.default.createDirectory(at: paths.termuxConfigDirectory, withIntermediateDirectories: true)
        try Data("fullscreen=true\n".utf8).write(to: paths.primaryPropertiesFile)
        try Bootstrap.run(paths: paths)
        XCTAssertEqual(try String(contentsOf: paths.primaryPropertiesFile, encoding: .utf8), "fullscreen=true\n")
    }

    func testSecondaryPropertiesFile() throws {
        let paths = TermuxPaths(documentsDirectory: documents)
        try FileManager.default.createDirectory(at: paths.termuxConfigDirectory2, withIntermediateDirectories: true)
        try Data("fullscreen=true\n".utf8).write(to: paths.secondaryPropertiesFile)
        try Bootstrap.run(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.primaryPropertiesFile.path))
        XCTAssertEqual(paths.propertiesFile, paths.secondaryPropertiesFile)
    }

    func testMotd() throws {
        let paths = TermuxPaths(documentsDirectory: documents)
        try Bootstrap.run(paths: paths)
        XCTAssertEqual(Bootstrap.motd(paths: paths), Bootstrap.defaultMotd)
        try Data("custom".utf8).write(to: paths.motdFile)
        XCTAssertEqual(Bootstrap.motd(paths: paths), "custom")
        try Data().write(to: paths.hushLoginFile)
        XCTAssertNil(Bootstrap.motd(paths: paths))
    }

    func testTerminalText() {
        XCTAssertEqual(Bootstrap.terminalText("a\nb\r\nc"), "a\r\nb\r\nc")
    }
}

final class AppPreferencesTests: XCTestCase {
    func testFontSize() {
        let suite = "TermuxAppTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.fontSize, AppPreferences.DEFAULT_FONT_SIZE)
        preferences.changeFontSize(increase: true)
        XCTAssertEqual(preferences.fontSize, AppPreferences.DEFAULT_FONT_SIZE + 1)
        preferences.fontSize = 1000
        XCTAssertEqual(preferences.fontSize, AppPreferences.MAX_FONT_SIZE)
        preferences.changeFontSize(increase: true)
        XCTAssertEqual(preferences.fontSize, AppPreferences.MAX_FONT_SIZE)
        preferences.fontSize = 0.5
        XCTAssertEqual(preferences.fontSize, AppPreferences.MIN_FONT_SIZE)
        XCTAssertEqual(preferences.theme, .system)
        preferences.theme = .black
        XCTAssertEqual(preferences.theme, .black)
        XCTAssertTrue(preferences.bellVibrate)
        XCTAssertTrue(preferences.softKeyboardEnabled)
    }
}

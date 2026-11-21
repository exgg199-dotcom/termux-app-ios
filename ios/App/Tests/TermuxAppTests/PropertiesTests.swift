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
        let props = JavaPropertiesParser.parse(text)
        XCTAssertEqual(props["a"], "1")
        XCTAssertEqual(props["b"], "2")
        XCTAssertEqual(props["c"], "3")
        XCTAssertEqual(props["d"], "4")
        XCTAssertEqual(props["e"], "5  ")
        XCTAssertEqual(props["f"], "")
        XCTAssertEqual(props["g"], "")
        XCTAssertEqual(props["key with spaces"], "value")
        XCTAssertNil(props["# comment"])
        XCTAssertEqual(props.count, 8)
    }

    func testLineContinuation() {
        let text = "extra-keys = [['ESC','/'], \\\n      ['TAB','CTRL']]\nnext=1\n"
        let props = JavaPropertiesParser.parse(text)
        XCTAssertEqual(props["extra-keys"], "[['ESC','/'], ['TAB','CTRL']]")
        XCTAssertEqual(props["next"], "1")
    }

    func testEvenBackslashesDoNotContinue() {
        let props = JavaPropertiesParser.parse("a=x\\\\\nb=y")
        XCTAssertEqual(props["a"], "x\\")
        XCTAssertEqual(props["b"], "y")
    }

    func testEscapes() {
        let props = JavaPropertiesParser.parse("a=tab\\there\nb=\\u0041\\u00e9\nc=\\:\\=\\#")
        XCTAssertEqual(props["a"], "tab\there")
        XCTAssertEqual(props["b"], "Aé")
        XCTAssertEqual(props["c"], ":=#")
    }

    func testCRLFAndLaterKeysWin() {
        let props = JavaPropertiesParser.parse("a=1\r\nb=2\ra=3")
        XCTAssertEqual(props["a"], "3")
        XCTAssertEqual(props["b"], "2")
    }
}

final class TermuxPropertiesTests: XCTestCase {

    func testDefaults() {
        let props = TermuxProperties()
        XCTAssertEqual(props.extraKeys, ExtraKeysInfo.DEFAULT_EXTRA_KEYS)
        XCTAssertEqual(props.extraKeysStyle, "default")
        XCTAssertTrue(props.extraKeysTextAllCaps)
        XCTAssertEqual(props.bellBehaviour, .vibrate)
        XCTAssertEqual(props.terminalTranscriptRows, 2000)
        XCTAssertEqual(props.terminalCursorStyle, TermuxProperties.TERMINAL_CURSOR_STYLE_BLOCK)
        XCTAssertEqual(props.terminalCursorBlinkRate, 0)
        XCTAssertEqual(props.terminalMarginHorizontal, 3)
        XCTAssertEqual(props.terminalMarginVertical, 0)
        XCTAssertEqual(props.terminalToolbarHeightScaleFactor, 1.0)
        XCTAssertEqual(props.nightMode, "system")
        XCTAssertFalse(props.fullscreen)
        XCTAssertFalse(props.hideSoftKeyboardOnStartup)
        XCTAssertFalse(props.terminalOnclickUrlOpen)
        XCTAssertEqual(props.softKeyboardToggleBehaviour, .showHide)
        XCTAssertTrue(props.sessionShortcuts.isEmpty)
        XCTAssertTrue(props.warnings.isEmpty)
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
        let props = TermuxProperties(properties: JavaPropertiesParser.parse(text))
        XCTAssertEqual(props.extraKeys, "[['ESC','TAB'], ['CTRL','ALT']]")
        XCTAssertEqual(props.extraKeysStyle, "arrows-only")
        XCTAssertFalse(props.extraKeysTextAllCaps)
        XCTAssertEqual(props.bellBehaviour, .ignore)
        XCTAssertEqual(props.terminalTranscriptRows, 10000)
        XCTAssertEqual(props.terminalCursorStyle, TermuxProperties.TERMINAL_CURSOR_STYLE_BAR)
        XCTAssertEqual(props.terminalCursorBlinkRate, 600)
        XCTAssertEqual(props.terminalMarginHorizontal, 10)
        XCTAssertEqual(props.terminalToolbarHeightScaleFactor, 1.5)
        XCTAssertEqual(props.nightMode, "true")
        XCTAssertTrue(props.fullscreen)
        XCTAssertTrue(props.hideSoftKeyboardOnStartup)
        XCTAssertTrue(props.terminalOnclickUrlOpen)
        XCTAssertEqual(props.softKeyboardToggleBehaviour, .enableDisable)
        XCTAssertEqual(props.sessionShortcuts, [
            SessionShortcut(codePoint: Int(UnicodeScalar("t").value), action: .createSession),
            SessionShortcut(codePoint: Int(UnicodeScalar("2").value), action: .nextSession),
        ])
        XCTAssertEqual(props.sessionShortcutAction(forCodePoint: Int(UnicodeScalar("T").value)), .createSession)
        XCTAssertNil(props.sessionShortcutAction(forCodePoint: Int(UnicodeScalar("x").value)))
        XCTAssertTrue(props.warnings.isEmpty, "\(props.warnings)")

        // The multi line extra-keys value is usable.
        let info = ExtraKeysInfo.loadWithFallback(extraKeys: props.extraKeys, style: props.extraKeysStyle)
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
        let props = TermuxProperties(properties: JavaPropertiesParser.parse(text))
        XCTAssertEqual(props.bellBehaviour, .vibrate)
        XCTAssertEqual(props.terminalTranscriptRows, 2000)
        XCTAssertEqual(props.terminalCursorStyle, 0)
        XCTAssertEqual(props.terminalCursorBlinkRate, 0)
        XCTAssertEqual(props.terminalMarginHorizontal, 3)
        XCTAssertEqual(props.terminalToolbarHeightScaleFactor, 1.0)
        XCTAssertFalse(props.fullscreen)
        XCTAssertEqual(props.nightMode, "system")
        XCTAssertTrue(props.sessionShortcuts.isEmpty)
        XCTAssertEqual(props.warnings.count, 9)
    }

    func testNightModeWinsOverUseBlackUI() {
        let props = TermuxProperties(properties: ["night-mode": "false", "use-black-ui": "true"])
        XCTAssertEqual(props.nightMode, "false")
    }

    func testEmptyExtraKeysUsesDefault() {
        let props = TermuxProperties(properties: ["extra-keys": "", "extra-keys-style": ""])
        XCTAssertEqual(props.extraKeys, TermuxProperties.DEFAULT_IVALUE_EXTRA_KEYS)
        XCTAssertEqual(props.extraKeysStyle, "default")
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
        // The secondary file exists, so no primary file is created and the secondary one is used.
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
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.fontSize, AppPreferences.DEFAULT_FONT_SIZE)
        prefs.changeFontSize(increase: true)
        XCTAssertEqual(prefs.fontSize, AppPreferences.DEFAULT_FONT_SIZE + 1)
        prefs.fontSize = 1000
        XCTAssertEqual(prefs.fontSize, AppPreferences.MAX_FONT_SIZE)
        prefs.changeFontSize(increase: true)
        XCTAssertEqual(prefs.fontSize, AppPreferences.MAX_FONT_SIZE)
        prefs.fontSize = 0.5
        XCTAssertEqual(prefs.fontSize, AppPreferences.MIN_FONT_SIZE)
        XCTAssertEqual(prefs.theme, .system)
        prefs.theme = .black
        XCTAssertEqual(prefs.theme, .black)
        XCTAssertTrue(prefs.bellVibrate)
        XCTAssertTrue(prefs.softKeyboardEnabled)
    }
}

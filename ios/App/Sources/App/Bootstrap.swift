import Foundation

public enum Bootstrap {
    public static let defaultPackageSource = "https://raw.githubusercontent.com/exgg199-dotcom/termux-app-ios/master/packages/index.json"

    public static let prefixSubdirectories = ["bin", "etc/pkg", "libexec/wasm", "var/lib/pkg/lists", "var/cache/pkg/archives", "tmp"]

    public static func run(paths: TermuxPaths, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: paths.homeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.termuxConfigDirectory, withIntermediateDirectories: true)
        try createPrefix(paths: paths, fileManager: fileManager)

        let propertiesExist = fileManager.fileExists(atPath: paths.primaryPropertiesFile.path)
            || fileManager.fileExists(atPath: paths.secondaryPropertiesFile.path)
        if !propertiesExist {
            try Data(defaultTermuxProperties.utf8).write(to: paths.primaryPropertiesFile, options: .atomic)
        }

        let readme = paths.documentsDirectory.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readme.path) {
            try? Data(documentsReadme.utf8).write(to: readme, options: .atomic)
        }
    }

    public static func createPrefix(paths: TermuxPaths, fileManager: FileManager = .default) throws {
        for subdirectory in prefixSubdirectories {
            let directory = paths.prefixDirectory.appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: paths.packageSourcesFile.path) {
            try Data((defaultPackageSource + "\n").utf8).write(to: paths.packageSourcesFile, options: .atomic)
        }
        var prefix = paths.prefixDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? prefix.setResourceValues(values)
    }

    public static func motd(paths: TermuxPaths, fileManager: FileManager = .default) -> String? {
        if fileManager.fileExists(atPath: paths.hushLoginFile.path) {
            return nil
        }
        if let data = fileManager.contents(atPath: paths.motdFile.path), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return defaultMotd
    }

    public static func terminalText(_ text: String) -> String {
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    public static let defaultMotd = """

    Welcome to Termux for iOS!

    This is a port of the Termux terminal to iOS. Since iOS does not
    allow apps to run other programs, commands are provided by a
    built-in shell. Type \u{1B}[1mhelp\u{1B}[0m to list them.

    Working with packages:

     * Search packages:   \u{1B}[1mpkg search <query>\u{1B}[0m
     * Install a package: \u{1B}[1mpkg install <package>\u{1B}[0m
     * Upgrade packages:  \u{1B}[1mpkg upgrade\u{1B}[0m

    Packages are WebAssembly programs; Android Termux packages cannot
    run on iOS.

    Your home directory is visible in the Files app under
    On My iPhone/iPad > Termux > home.

    Configure the terminal in ~/.termux/termux.properties
    (or via the Settings button in the sessions drawer).
    Swipe from the left edge for the sessions drawer.

    """

    public static let documentsReadme = """
    Termux for iOS
    ==============

    The "home" folder is the home directory ($HOME) of the Termux shell.

    Configuration files live in home/.termux, which the Files app hides
    because its name starts with a dot. Use the Settings screen of the
    app (sessions drawer > Settings) to edit termux.properties and
    colors.properties, or the built-in shell.

    """

    public static let defaultTermuxProperties = """
    ### This is the Termux for iOS configuration file.
    ### Lines starting with # are comments. Uncomment a property and change its value
    ### to change the behaviour of the app.
    ###
    ### After making changes and saving, the settings are reloaded automatically
    ### (they are also reloaded when the app returns to the foreground, or with the
    ### "Reload settings" button in Settings).

    ###############
    # Extra keys
    ###############

    ### Settings for choosing which set of symbols to use for illustrating keys.
    ### Choose between default, arrows-only, arrows-all, all and none
    # extra-keys-style = default

    ### Force capitalize all text in extra keys row button labels.
    # extra-keys-text-all-caps = true

    ### Default extra-key configuration
    # extra-keys = [[ESC, TAB, CTRL, ALT, {key: '-', popup: '|'}, DOWN, UP]]

    ### Two rows with more keys (the default)
    # extra-keys = [['ESC','/',{key: '-', popup: '|'},'HOME','UP','END','PGUP'], \\
    #               ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]

    ### Configuration with additional popup keys (swipe up from an extra key)
    # extra-keys = [[ \\
    #  {key: ESC, popup: {macro: "CTRL f d", display: "tmux exit"}}, \\
    #  {key: CTRL, popup: {macro: "CTRL f BKSP", display: "tmux ←"}}, \\
    #  {key: ALT, popup: {macro: "CTRL f TAB", display: "tmux →"}}, \\
    #  {key: TAB, popup: {macro: "ALT a", display: A-a}}, \\
    #  {key: LEFT, popup: HOME}, \\
    #  {key: DOWN, popup: PGDN}, \\
    #  {key: UP, popup: PGUP}, \\
    #  {key: RIGHT, popup: END}, \\
    #  {macro: "ALT j", display: A-j, popup: {macro: "ALT g", display: A-g}}, \\
    #  {key: KEYBOARD, popup: {macro: "CTRL d", display: exit}} \\
    # ]]

    ### Special keys: CTRL, ALT, SHIFT and FN are toggles (tap: one key, double tap or
    ### long press: lock). KEYBOARD toggles the keyboard, DRAWER opens the sessions
    ### drawer, PASTE pastes the clipboard and SCROLL toggles auto scrolling.

    ### Height of the extra keys rows relative to the default (0.4 - 3.0)
    # terminal-toolbar-height = 1.0

    ###############
    # Terminal
    ###############

    ### Number of lines kept in the scrollback (100 - 50000)
    # terminal-transcript-rows = 2000

    ### Cursor style: block, underline or bar
    # terminal-cursor-style = block

    ### Cursor blink rate in milliseconds (100 - 2000), 0 disables blinking
    # terminal-cursor-blink-rate = 0

    ### Horizontal and vertical margins of the terminal in points (0 - 100)
    # terminal-margin-horizontal = 3
    # terminal-margin-vertical = 0

    ### Open URLs when tapping on them
    # terminal-onclick-url-open = false

    ### What to do on the bell character: vibrate, beep or ignore
    # bell-character = vibrate

    ### Colors are configured in ~/.termux/colors.properties, e.g.:
    ###   background=#000000
    ###   foreground=#ffffff
    ###   color1=#cd0000
    ### A custom monospace font can be installed as ~/.termux/font.ttf

    ###############
    # App
    ###############

    ### Theme of the app: true (dark), false (light) or system
    # night-mode = system

    ### Use pure black backgrounds (deprecated alias of night-mode=true)
    # use-black-ui = false

    ### Hide the status bar
    # fullscreen = false

    ### Do not show the soft keyboard when the app starts
    # hide-soft-keyboard-on-startup = false

    ### Disable the session change toast
    # disable-terminal-session-change-toast = false

    ### Disable the built-in hardware keyboard shortcuts (Cmd+T, Cmd+W, ...)
    # disable-hardware-keyboard-shortcuts = false

    ### Session shortcuts (typed with ctrl on a hardware keyboard or the CTRL extra key)
    # shortcut.create-session = ctrl + t
    # shortcut.next-session = ctrl + 2
    # shortcut.previous-session = ctrl + 1
    # shortcut.rename-session = ctrl + n

    """
}

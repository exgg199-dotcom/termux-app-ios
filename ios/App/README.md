# Termux for iOS (app)

The iOS app of the Termux port: a SwiftUI application (iOS 15+) hosting a UIKit terminal surface.
It is the counterpart of the Android `app` and `terminal-view` modules and of the extra keys and
`termux.properties` handling of `termux-shared`. The terminal emulator (`TermuxTerminal`) and the
built-in shell (`TermuxShell`) live in the Swift package in `ios/`, see `ios/docs/ARCHITECTURE.md`.

## Layout

| Path | Contents | Android counterpart |
|------|----------|---------------------|
| `Sources/App/TermuxApplication.swift` | SwiftUI `App` entry point | `TermuxApplication` |
| `Sources/App/ContentView.swift`, `SessionsDrawerView.swift` | Root view, sessions drawer, toasts | `TermuxActivity` layout, `TermuxSessionsListViewController` |
| `Sources/App/TerminalController.swift` | Clients of the terminal view, extra keys and sessions | `TermuxActivity`, `TermuxTerminalViewClient`, `TermuxTerminalSessionActivityClient`, `TermuxTerminalExtraKeys` |
| `Sources/App/SessionManager.swift` | Sessions, each with a `BuiltinShellBackend` (`$HOME` = `Documents/home`) | `TermuxService` |
| `Sources/App/Bootstrap.swift` | First launch: home directory, default `termux.properties`, message of the day | `TermuxInstaller` |
| `Sources/TerminalView/` | `TerminalView` (UIKit, `UIKeyInput`), CoreText `TerminalRenderer`, text selection | `terminal-view` |
| `Sources/ExtraKeys/` | Extra keys parsing and `ExtraKeysView` keyboard accessory | `termux-shared/.../extrakeys` |
| `Sources/Settings/` | `termux.properties` parsing, preferences, SwiftUI settings | `TermuxSharedProperties`, `SettingsActivity` |
| `Tests/TermuxAppTests/` | Logic tests (no host app) | |

## Building

Requirements: macOS with Xcode 15 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd ios/App
xcodegen generate
open TermuxIOS.xcodeproj
```

The generated `TermuxIOS.xcodeproj` and `Info.plist` are not committed.

Unsigned device build (as done in CI):

```bash
cd ios/App
xcodegen generate
xcodebuild -project TermuxIOS.xcodeproj -scheme Termux -configuration Release -sdk iphoneos \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

Simulator build and logic tests:

```bash
xcodebuild -project TermuxIOS.xcodeproj -scheme Termux -destination 'generic/platform=iOS Simulator' build
xcodebuild -project TermuxIOS.xcodeproj -scheme Termux -destination 'platform=iOS Simulator,name=iPhone 15' test
```

The emulator and shell can be built and tested on Linux or macOS without Xcode:

```bash
cd ios
swift build && swift test
```

## Running on a device

1. Open `TermuxIOS.xcodeproj`, select the `Termux` target, *Signing & Capabilities*.
2. Enable *Automatically manage signing* and choose your (personal) team.
3. If the bundle identifier `com.nxteam.termux.test` is taken for your team, change it to a unique one.
4. Select your device and run. With a free personal team the app has to be re-signed every 7 days.

## Usage

* Tap the terminal to show the keyboard, pinch to change the font size, drag to scroll the
  scrollback (mouse wheel events are sent to programs that track the mouse), long press to select
  text and copy or paste.
* The extra keys row above the keyboard is configured with `extra-keys` in
  `~/.termux/termux.properties`. CTRL, ALT, SHIFT and FN are toggles: tap for the next key, double
  tap or long press to lock. Swipe up on a key to send its popup key.
* Swipe from the left edge (or tap the DRAWER extra key) for the sessions drawer: switch, rename
  and kill sessions, create new sessions (long press for a named session), toggle the keyboard and
  open the settings.
* Hardware keyboards: arrows, escape, tab, function keys, page up/down, home/end, ctrl and left
  option (as meta) combinations are sent to the terminal. Shortcuts: Cmd+T new session, Cmd+W close
  session, Cmd+Shift+] and Cmd+Shift+[ next and previous session, Cmd+1 to Cmd+9 switch session,
  Cmd+= and Cmd+- font size, Cmd+Shift+K keyboard, Cmd+Shift+D drawer, Cmd+, settings,
  Ctrl+Alt+arrows like on Android.
* Configuration files live in `~/.termux` (`termux.properties`, `colors.properties`, `font.ttf`,
  `motd`). The Files app shows the home directory under *On My iPhone > Termux > home*, but hides
  folders starting with a dot, so the properties files are edited from Settings or the shell.
  Changes are picked up automatically. `~/.hushlogin` disables the message of the day.

## Limitations compared to Android Termux

* iOS apps can not run other executables, so there is no package manager (`pkg`/`apt`) and no
  bootstrap: the shell is a built-in shell with a fixed set of commands (`help` lists them).
* Sessions only live while the app process lives; iOS suspends background apps.
* No `termux-api`, no `RUN_COMMAND` intent, no widgets, no `termux-am`, no floating window.
* Volume keys can not be used as virtual keys; the FN extra key provides the same combinations
  (FN+W/A/S/D arrows, FN+1..0 function keys, FN+E escape, ...).
* Sixel images are not rendered yet.

## Roadmap

* SSH backend (for example with SwiftNIO SSH) as a `TerminalBackend`, to use real remote shells.
* More commands via WebAssembly (WASI) or `ios_system`-style in-process command ports.
* iSH-style x86 user mode emulation to run an Alpine Linux userland.
* Sixel graphics, URL selection dialog, multiple windows on iPad.

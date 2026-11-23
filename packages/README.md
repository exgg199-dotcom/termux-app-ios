# Termux for iOS package index

`index.json` is the package list that `pkg` and `apt` in Termux for iOS read. The app fetches it from

    https://raw.githubusercontent.com/exgg199-dotcom/termux-app-ios/master/packages/index.json

and also ships a copy as a bundle resource, which is used when the download fails and no list has been cached yet.
The sources can be changed in `$PREFIX/etc/pkg/sources.list` (one index URL per line, `#` starts a comment; `file://` URLs work).

## Why WebAssembly

Real Termux packages (packages.termux.dev) are Android/Linux aarch64 programs. iOS does not allow an app to run
downloaded native code, so they cannot run on iOS. Packages for Termux for iOS are WASI preview 1 WebAssembly
programs (architecture `wasm32`) that the app runs in its built-in interpreter (WasmKit). They are slower than native
programs, they cannot start other programs, they have no network sockets and no threads, input is line based, and they
can only reach files under `$HOME`, `$PREFIX`, `$TMPDIR` and the current directory.

## Format

```json
{
  "format": 1,
  "name": "termux-ios-wasm",
  "packages": [
    {
      "name": "quickjs",
      "version": "0.18.0",
      "architecture": "wasm32",
      "description": "QuickJS-ng JavaScript engine (qjs)",
      "homepage": "https://github.com/quickjs-ng/quickjs",
      "license": "MIT",
      "depends": [],
      "provides": ["qjs"],
      "files": [
        {
          "path": "libexec/wasm/quickjs/qjs.wasm",
          "urls": ["https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/qjs-wasi.wasm"],
          "sha256": "2c218412cb8b17e46ee91bea7556ec38f5b9b6bd6312fddd3ceeed14aa71eaaa",
          "size": 1571399,
          "mode": "0755"
        }
      ],
      "commands": {"qjs": "libexec/wasm/quickjs/qjs.wasm"},
      "notes": "Optional text printed after installation."
    }
  ]
}
```

* `path` is relative to `$PREFIX`; it must not start with `/` or contain `.` or `..` components.
* A file either has `urls` (downloaded, `sha256` is required, `size` is checked when present; further URLs are mirrors)
  or inline `text` (for example a small shell script).
* `mode` is an octal string. Files referenced by `commands` default to `0755`, other files to `0644`.
* `commands` maps a command name to a file of the package. Installation creates the relative symlink
  `$PREFIX/bin/<command>`, which is on `PATH`. A command keeps the name it was started with as `argv[0]`.
* `depends` lists package names that are installed first. `provides` lists extra names that `pkg install` accepts.
* Versions are compared with a simplified Debian ordering (`1.10` > `1.9`, `1.0~rc1` < `1.0`).

## Adding a package

1. Find a WASI preview 1 core module (not a component) that only imports `wasi_snapshot_preview1`.
   Functions that the runtime does not know are replaced by stubs that fail, which is enough for the a-Shell builds.
2. Add an entry with the release URL, its size and `sha256sum`.
3. Run `python3 packages/verify_index.py packages/index.json`.
4. Add a check to `ios/Tests/TermuxWasmTests/RealPackageTests.swift` and run
   `cd ios && TERMUX_NETWORK_TESTS=1 swift test -c release --filter RealPackageTests`.
   Packages that fail are not added.

## Packages and licences

| Package | Version | Commands | Upstream | Licence |
|---|---|---|---|---|
| quickjs | 0.18.0 | qjs | quickjs-ng | MIT |
| python | 3.12.0 | python, python3 | VMware Wasm Labs | PSF-2.0 |
| ruby | 3.2.2 | ruby | VMware Wasm Labs | Ruby/BSD-2-Clause |
| php | 8.2.6 | php-cgi | VMware Wasm Labs | PHP-3.01 |
| xz-utils | 5.2 | xz, unxz, xzcat, lzmadec | a-Shell commands | 0BSD/public domain/LGPL-2.1 |
| unzip | 6.0 | unzip | a-Shell commands | Info-ZIP |
| zip | 3.0 | zip | a-Shell commands | Info-ZIP |
| sqlite | 3 | sqlite3 | a-Shell commands | public domain |

The binaries are downloaded from their upstream release pages and are not redistributed by this repository.

## Network test results

`TERMUX_NETWORK_TESTS=1 swift test --filter RealPackageTests` on Linux (Swift 6.0.3, WasmKit 0.2.2), debug and release builds:

| Package | Check | Result |
|---|---|---|
| quickjs | `qjs -e 'console.log(6*7)'` prints 42 | passed |
| python | `python3 -c 'print(6*7)'`, `python3 -` from stdin, writing a file in the current directory | passed |
| ruby | `ruby -e 'puts 6*7'` prints 42 | passed |
| php | `php-cgi -q answer.php` prints 42 | passed |
| xz-utils | `xz --version`, `xz file && unxz file.xz` round trip | passed |
| sqlite | `printf 'select 6*7;' \| sqlite3` prints 42 | passed |
| zip, unzip | `zip archive.zip note.txt`, then `unzip archive.zip` restores the file | passed |

No package was dropped. `file.wasm` (a-Shell) is not included yet because it needs a magic database.

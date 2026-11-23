import XCTest
@testable import TermuxShell

final class FakePackageFetcher: PackageFetcher {
    var responses: [URL: [UInt8]] = [:]
    var failures: [URL: PackageFetchError] = [:]
    var requested: [URL] = []

    func fetch(_ url: URL, to destination: String, cancellation: CancellationToken,
               progress: @escaping (Int64, Int64?) -> Void) -> Result<Int64, PackageFetchError> {
        requested.append(url)
        if let failure = failures[url] { return .failure(failure) }
        guard let bytes = responses[url] else { return .failure(.httpStatus(404)) }
        FileManager.default.createFile(atPath: destination, contents: Data(bytes))
        progress(Int64(bytes.count), Int64(bytes.count))
        return .success(Int64(bytes.count))
    }
}

final class PackageManagerTests: ShellTestCase {
    let indexURL = URL(string: "https://packages.example.invalid/index.json")!
    var fetcher: FakePackageFetcher!
    var prefix: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        prefix = home + "/usr"
        shell.setVariable("PREFIX", prefix)
        shell.setVariable("PATH", prefix + "/bin:" + home + "/bin")
        fetcher = FakePackageFetcher()
        let current = fetcher!
        PackageCommands.fetcherFactory = { current }
        let layout = PackageLayout(prefix: prefix)
        try layout.createDirectories()
        try Data((indexURL.absoluteString + "\n").utf8).write(to: URL(fileURLWithPath: layout.sourcesFile))
    }

    override func tearDownWithError() throws {
        PackageCommands.fetcherFactory = { URLSessionPackageFetcher() }
        PackageManager.bundledIndexURL = nil
        try super.tearDownWithError()
    }

    var layout: PackageLayout { PackageLayout(prefix: prefix) }

    func publish(_ records: [PackageRecord]) throws {
        let data = try JSONEncoder().encode(PackageIndex(name: "test", packages: records))
        fetcher.responses[indexURL] = [UInt8](data)
    }

    func scriptPackage(_ name: String, version: String = "1.0", text: String? = nil, depends: [String]? = nil,
                       description: String? = nil) -> PackageRecord {
        let path = "libexec/\(name)/\(name).sh"
        return PackageRecord(name: name, version: version, description: description ?? "The \(name) test package",
                             depends: depends, files: [PackageFile(path: path, text: text ?? "#!/bin/sh\necho hello-from-\(name)\n", mode: "0755")],
                             commands: [name: path])
    }

    func downloadedPackage(_ name: String, bytes: [UInt8], hash: String) -> PackageRecord {
        let url = "https://downloads.example.invalid/\(name).bin"
        fetcher.responses[URL(string: url)!] = bytes
        let path = "libexec/wasm/\(name)/\(name).sh"
        return PackageRecord(name: name, version: "2.0", description: "Downloaded package",
                             files: [PackageFile(path: path, urls: [url], sha256: hash, size: Int64(bytes.count))],
                             commands: [name: path])
    }

    func combined(_ result: (status: Int32, stdout: String, stderr: String)) -> String { result.stdout + result.stderr }

    func testUpdateWritesList() throws {
        try publish([scriptPackage("hello")])
        let result = run("pkg update")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stdout.contains("Get:1 \(indexURL.absoluteString) ["), result.stdout)
        XCTAssertTrue(result.stdout.contains("Reading package lists... Done"))
        XCTAssertTrue(result.stdout.contains("All packages are up to date."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.listFile(for: indexURL)))
        XCTAssertTrue(layout.listFile(for: indexURL).hasSuffix("/lists/https___packages_example_invalid_index_json.json"))
    }

    func testFailedUpdateWithoutCache() throws {
        fetcher.failures[indexURL] = .failed("Could not resolve host")
        let result = run("apt update")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stdout.contains("Err:1 \(indexURL.absoluteString)\n  Could not resolve host"), result.stdout)
        XCTAssertTrue(result.stderr.contains("W: Some index files failed to download."), result.stderr)
    }

    func testFailedUpdateFallsBackToBundledIndex() throws {
        fetcher.failures[indexURL] = .failed("offline")
        let bundled = home + "/bundled.json"
        try JSONEncoder().encode(PackageIndex(name: "bundled", packages: [scriptPackage("hello")])).write(to: URL(fileURLWithPath: bundled))
        PackageManager.bundledIndexURL = URL(fileURLWithPath: bundled)
        let result = run("pkg update")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stderr.contains("W: Using the package list bundled with the app."), result.stderr)
        XCTAssertTrue(out("pkg list-all").contains("hello/stable 1.0 wasm32"))
        let install = run("pkg install hello")
        XCTAssertEqual(install.status, 0, combined(install))
        XCTAssertEqual(out("hello"), "hello-from-hello\n")
    }

    func testInstallScriptPackage() throws {
        try publish([scriptPackage("hello")])
        let result = run("pkg install -y hello")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stdout.contains("The following NEW packages will be installed:\n  hello\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded."))
        XCTAssertTrue(result.stdout.contains("Selecting previously unselected package hello."))
        XCTAssertTrue(result.stdout.contains("Unpacking hello (1.0) ..."))
        XCTAssertTrue(result.stdout.contains("Setting up hello (1.0) ..."))
        XCTAssertEqual(out("hello"), "hello-from-hello\n")
        XCTAssertEqual(out("which hello"), prefix + "/bin/hello\n")
        XCTAssertTrue(out("pkg list-installed").contains("hello/stable 1.0 wasm32 [installed]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.statusFile))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: prefix + "/bin/hello"), "../libexec/hello/hello.sh")
        let again = run("pkg install hello")
        XCTAssertEqual(again.status, 0)
        XCTAssertTrue(again.stdout.contains("hello is already the newest version (1.0)."), again.stdout)
        let reinstall = run("pkg reinstall hello")
        XCTAssertEqual(reinstall.status, 0, combined(reinstall))
        XCTAssertTrue(reinstall.stdout.contains("1 reinstalled"), reinstall.stdout)
        XCTAssertEqual(out("hello"), "hello-from-hello\n")
    }

    func testInstallDownloadedFileWithChecksum() throws {
        let bytes = Array("#!/bin/sh\necho downloaded\n".utf8)
        try publish([downloadedPackage("tool", bytes: bytes, hash: Hashing.hex(Hashing.sha256(bytes)))])
        let result = run("apt install tool")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stdout.contains("Need to get 26 B of archives."), result.stdout)
        XCTAssertTrue(result.stdout.contains("Get:1 https://downloads.example.invalid/tool.bin tool wasm32 2.0 [26 B]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Fetched 26 B in "), result.stdout)
        XCTAssertEqual(out("tool"), "downloaded\n")
    }

    func testHashMismatchInstallsNothing() throws {
        let bytes = Array("#!/bin/sh\necho downloaded\n".utf8)
        try publish([downloadedPackage("tool", bytes: bytes, hash: String(repeating: "0", count: 64))])
        let result = run("pkg install tool")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("Hash Sum mismatch"), result.stderr)
        XCTAssertTrue(result.stderr.contains("SHA256:" + Hashing.hex(Hashing.sha256(bytes))), result.stderr)
        XCTAssertNil(FileInfo(path: prefix + "/bin/tool"))
        XCTAssertNil(PackageDatabase(layout: layout).load().packages["tool"])
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: layout.archivesDirectory)).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers, [])
    }

    func testMissingChecksumIsRejected() throws {
        var record = downloadedPackage("tool", bytes: [1, 2, 3], hash: "")
        record.files[0].sha256 = nil
        try publish([record])
        let result = run("pkg install tool")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("E: tool: file has no checksum"), result.stderr)
    }

    func testUnknownPackage() throws {
        try publish([scriptPackage("hello")])
        let result = run("pkg install git")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("E: Unable to locate package git"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Android Termux packages cannot run on iOS"), result.stderr)
    }

    func testDependenciesAreInstalledFirst() throws {
        try publish([scriptPackage("app", depends: ["library"]), scriptPackage("library")])
        let result = run("pkg install app")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stdout.contains("The following NEW packages will be installed:\n  library app\n"), result.stdout)
        let libraryIndex = result.stdout.range(of: "Unpacking library")!.lowerBound
        let appIndex = result.stdout.range(of: "Unpacking app")!.lowerBound
        XCTAssertLessThan(libraryIndex, appIndex)
        XCTAssertEqual(Set(PackageDatabase(layout: layout).load().packages.keys), ["app", "library"])
    }

    func testMissingDependency() throws {
        try publish([scriptPackage("app", depends: ["missing"])])
        let result = run("pkg install app")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stdout.contains("app : Depends: missing but it is not installable"), result.stdout)
        XCTAssertNil(FileInfo(path: prefix + "/bin/app"))
    }

    func testDependencyCycle() throws {
        try publish([scriptPackage("first", depends: ["second"]), scriptPackage("second", depends: ["first"])])
        let result = run("pkg install first")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("Dependency cycle"), result.stderr)
    }

    func testUpgradeReplacesFilesAndRemovesObsoleteOnes() throws {
        var old = scriptPackage("hello", text: "#!/bin/sh\necho old\n")
        old.files.append(PackageFile(path: "share/hello/extra.txt", text: "extra\n"))
        try publish([old])
        XCTAssertEqual(run("pkg install hello").status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix + "/share/hello/extra.txt"))
        try publish([scriptPackage("hello", version: "1.1", text: "#!/bin/sh\necho new\n")])
        XCTAssertEqual(run("pkg update").stdout.contains("1 package can be upgraded. Run 'apt list --upgradable' to see it."), true)
        XCTAssertTrue(out("apt list --upgradable").contains("hello/stable 1.1 wasm32 [upgradable from: 1.0]"))
        let result = run("pkg upgrade")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stdout.contains("The following packages will be upgraded:\n  hello\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Unpacking hello (1.1) over (1.0) ..."), result.stdout)
        XCTAssertEqual(out("hello"), "new\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix + "/share/hello/extra.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix + "/share/hello"))
        XCTAssertEqual(PackageDatabase(layout: layout).load().packages["hello"]?.version, "1.1")
        XCTAssertTrue(run("pkg upgrade").stdout.contains("0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."))
    }

    func testRemove() throws {
        try publish([scriptPackage("app", depends: ["library"]), scriptPackage("library")])
        XCTAssertEqual(run("pkg install app").status, 0)
        let refused = run("pkg uninstall library")
        XCTAssertEqual(refused.status, 100)
        XCTAssertTrue(refused.stderr.contains("E: library is needed by app"), refused.stderr)
        let result = run("apt remove app")
        XCTAssertEqual(result.status, 0, combined(result))
        XCTAssertTrue(result.stdout.contains("The following packages will be REMOVED:\n  app\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Removing app (1.0) ..."), result.stdout)
        XCTAssertNil(FileInfo(path: prefix + "/bin/app"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix + "/libexec/app"))
        XCTAssertEqual(run("app").status, 127)
        XCTAssertEqual(run("pkg remove library").status, 0)
        XCTAssertTrue(run("pkg remove library").stdout.contains("Package 'library' is not installed, so not removed"))
        XCTAssertEqual(PackageDatabase(layout: layout).load().packages, [:])
    }

    func testSearchShowAndFiles() throws {
        try publish([scriptPackage("python", description: "Python programming language"), scriptPackage("ruby", description: "Ruby interpreter")])
        XCTAssertEqual(run("pkg update").status, 0)
        let search = out("pkg search 'PYTH.N'")
        XCTAssertTrue(search.hasPrefix("Sorting... Done\nFull Text Search... Done\n"), search)
        XCTAssertTrue(search.contains("python/stable 1.0 wasm32\n  Python programming language\n\n"), search)
        XCTAssertFalse(search.contains("ruby"))
        XCTAssertTrue(out("apt search interpreter").contains("ruby/stable"))
        let show = out("apt show ruby")
        for field in ["Package: ruby", "Version: 1.0", "Architecture: wasm32", "Download-Size: 0 B", "Installed-Size: ", "Description: Ruby interpreter"] {
            XCTAssertTrue(show.contains(field), show)
        }
        XCTAssertEqual(run("pkg show nothing").status, 100)
        XCTAssertEqual(run("pkg install ruby").status, 0)
        XCTAssertEqual(out("pkg files ruby"), prefix + "/bin/ruby\n" + prefix + "/libexec/ruby/ruby.sh\n")
        XCTAssertEqual(out("dpkg -L ruby"), out("pkg files ruby"))
        XCTAssertTrue(out("dpkg -l").contains("ii  ruby "))
        XCTAssertTrue(out("pkg search ruby").contains("ruby/stable 1.0 wasm32 [installed]"))
    }

    func testUsageAndUnknownSubcommand() throws {
        let help = run("pkg help")
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("list-installed"))
        XCTAssertTrue(help.stdout.contains("Packages for Termux for iOS are WebAssembly (wasm32) programs."))
        XCTAssertEqual(run("pkg frobnicate").status, 1)
        XCTAssertEqual(run("apt frobnicate").status, 100)
        XCTAssertEqual(out("apt autoremove"), "Reading package lists... Done\nBuilding dependency tree... Done\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n")
    }

    func testBuiltinNameClashWarns() throws {
        try publish([scriptPackage("ls")])
        let result = run("pkg install ls")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("W: 'ls' is also a built-in command; run the package version as \(prefix!)/bin/ls"), result.stderr)
    }

    func testVersionComparison() {
        XCTAssertEqual(PackageVersion.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(PackageVersion.compare("1.0~rc1", "1.0"), .orderedAscending)
        XCTAssertEqual(PackageVersion.compare("3.12.0", "3.12.0"), .orderedSame)
        XCTAssertEqual(PackageVersion.compare("1.0", "1.0a"), .orderedAscending)
        XCTAssertEqual(PackageVersion.compare("2", "10"), .orderedAscending)
    }

    func testUnsafePathIsRejected() throws {
        let record = PackageRecord(name: "evil", version: "1.0", description: "Escapes the prefix",
                                   files: [PackageFile(path: "../../escape.sh", text: "echo\n")])
        try publish([record])
        let result = run("pkg install evil")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("invalid file path '../../escape.sh'"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/escape.sh"))
        XCTAssertFalse(PackageFile.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(PackageFile.isSafeRelativePath("a/./b"))
        XCTAssertTrue(PackageFile.isSafeRelativePath("libexec/wasm/a.wasm"))
    }

    func testReservedPathAndUnsafeVersionAreRejected() throws {
        let reserved = PackageRecord(name: "sources", version: "1.0", description: "Replaces the sources",
                                     files: [PackageFile(path: "etc/pkg/sources.list", text: "file:///evil\n")])
        let traversal = PackageRecord(name: "traversal", version: "1/../../../escape", description: "Escapes the archives",
                                      files: [PackageFile(path: "share/traversal.txt", text: "x\n")])
        try publish([reserved, traversal])
        let result = run("pkg install sources")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("invalid file path 'etc/pkg/sources.list'"), result.stderr)
        XCTAssertEqual(try String(contentsOfFile: layout.sourcesFile, encoding: .utf8), indexURL.absoluteString + "\n")
        let version = run("pkg install traversal")
        XCTAssertEqual(version.status, 100)
        XCTAssertTrue(version.stderr.contains("invalid version"), version.stderr)
    }

    func testFileOwnedByAnotherPackageIsNotOverwritten() throws {
        let first = scriptPackage("first")
        var second = scriptPackage("second")
        second.commands = ["first": second.files[0].path]
        try publish([first, second])
        XCTAssertEqual(run("pkg install first").status, 0)
        let result = run("pkg install second")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("trying to overwrite '\(prefix!)/bin/first', which is also in package first"), result.stderr)
        XCTAssertEqual(out("first"), "hello-from-first\n")
        XCTAssertNil(PackageDatabase(layout: layout).load().packages["second"])
    }

    func testLockIsExclusive() throws {
        let path = layout.lockFile
        let first = PackageLock(path: path)
        XCTAssertNotNil(first)
        XCTAssertNil(PackageLock(path: path))
        let result = run("pkg update")
        XCTAssertEqual(result.status, 100)
        XCTAssertTrue(result.stderr.contains("E: Could not get lock \(path). It is held by another session."), result.stderr)
        withExtendedLifetime(first) {}
    }

    func testCancelledDownload() throws {
        try publish([downloadedPackage("tool", bytes: [1, 2, 3], hash: Hashing.hex(Hashing.sha256([1, 2, 3])))])
        fetcher.failures[URL(string: "https://downloads.example.invalid/tool.bin")!] = .cancelled
        let result = run("pkg install tool")
        XCTAssertEqual(result.status, 130)
        XCTAssertTrue(result.stderr.contains("E: Interrupted"), result.stderr)
        XCTAssertNil(FileInfo(path: prefix + "/bin/tool"))
    }

    func testFormat() {
        XCTAssertEqual(PackageFormat.size(512), "512 B")
        XCTAssertEqual(PackageFormat.size(12_300), "12.3 kB")
        XCTAssertEqual(PackageFormat.size(1_404_090), "1,404 kB")
        XCTAssertEqual(PackageFormat.size(26_267_204), "26.3 MB")
        XCTAssertEqual(PackageFormat.rate(bytes: 3_283_000, seconds: 1), "3,283 kB/s")
    }

    func testApplicationBootstrapMatchesLayout() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../App/Sources/App/Bootstrap.swift").standardizedFileURL
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("\"" + PackageLayout.defaultSource + "\""))
        let layout = PackageLayout(prefix: "/prefix")
        for directory in layout.directories {
            XCTAssertTrue(source.contains("\"" + String(directory.dropFirst("/prefix/".count)) + "\""), directory)
        }
    }

    func testListWithoutPackageLists() throws {
        let result = run("pkg list-all")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Run 'pkg update'"), result.stderr)
    }

    func testRepositoryIndexDecodes() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../packages/index.json").standardizedFileURL
        let index = try PackageIndex.decode(Data(contentsOf: path))
        XCTAssertFalse(index.packages.isEmpty)
        for record in index.packages {
            XCTAssertNil(record.validationError(), record.name)
            for file in record.files {
                XCTAssertNotNil(file.sha256, record.name)
                XCTAssertEqual(file.sha256?.count, 64, record.name)
            }
        }
    }
}

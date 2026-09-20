import XCTest
@testable import SwiftImmich

final class UpdateInstallerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A minimal signed app bundle, like the one inside a release zip.
    private func makeApp(named name: String = "SwiftImmich", identifier: String = "dev.local.swiftimmich", version: String = "9.9.9") throws -> URL {
        let app = folder.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: macOS.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent(name).path)
        let plist: [String: Any] = [
            "CFBundleExecutable": name, "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version, "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
        ]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateInstallerCore.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], what: "signing the test app")
        return app
    }

    private func zip(_ app: URL) throws -> URL {
        let zip = folder.appendingPathComponent("release.zip")
        try UpdateInstallerCore.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path], what: "zipping")
        return zip
    }

    func testChecksumsAreComputedAndLookedUp() throws {
        let file = folder.appendingPathComponent("abc.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try UpdateInstallerCore.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let sums = """
        AAA111  SwiftImmich-1.0.1.dmg
        BBB222 *SwiftImmich-1.0.1.zip
        """
        XCTAssertEqual(UpdateInstallerCore.expectedHash(for: "SwiftImmich-1.0.1.zip", in: sums), "bbb222")
        XCTAssertEqual(UpdateInstallerCore.expectedHash(for: "SwiftImmich-1.0.1.dmg", in: sums), "aaa111")
        XCTAssertNil(UpdateInstallerCore.expectedHash(for: "other.zip", in: sums))
    }

    func testAGoodReleaseZipIsExtractedAndAccepted() throws {
        let app = try makeApp()
        let zip = try zip(app)
        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let extracted = try UpdateInstallerCore.extractApp(from: zip, into: out)
        XCTAssertEqual(extracted.lastPathComponent, "SwiftImmich.app")
        XCTAssertNoThrow(try UpdateInstallerCore.validate(app: extracted, bundleIdentifier: "dev.local.swiftimmich", expectedVersion: AppVersion("9.9.9")))
    }

    func testTheWrongAppOrVersionIsRejected() throws {
        let app = try makeApp()
        XCTAssertThrowsError(try UpdateInstallerCore.validate(app: app, bundleIdentifier: "com.other.app", expectedVersion: nil))
        XCTAssertThrowsError(try UpdateInstallerCore.validate(app: app, bundleIdentifier: "dev.local.swiftimmich", expectedVersion: AppVersion("1.0.0")))
    }

    func testATamperedAppFailsTheSignatureCheck() throws {
        let app = try makeApp()
        try "#!/bin/sh\necho tampered\n".write(to: app.appendingPathComponent("Contents/MacOS/SwiftImmich"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UpdateInstallerCore.validate(app: app, bundleIdentifier: "dev.local.swiftimmich", expectedVersion: nil))
    }

    func testAnArchiveWithoutAnAppIsRejected() throws {
        let empty = folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "hi".write(to: empty.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("empty.zip")
        try UpdateInstallerCore.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", empty.path, zip.path], what: "zipping")
        let out = folder.appendingPathComponent("out2")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateInstallerCore.extractApp(from: zip, into: out))
    }

    private func marker(_ name: String, contents: String) throws -> URL {
        let dir = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        return dir
    }

    func testTheReplacementScriptSwapsTheNewCopyIn() throws {
        let destination = try marker("Dest.app", contents: "old")
        let newApp = try marker("New.app", contents: "new")
        // A process id that's already gone, so the script doesn't wait.
        let process = try UpdateInstallerCore.startReplacement(pid: 999_999, newApp: newApp, destination: destination, relaunch: false, in: folder)
        process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".previous"), "the backup is removed after a good swap")
    }

    func testAFailedSwapPutsTheOldCopyBack() throws {
        let destination = try marker("Dest2.app", contents: "old")
        let missing = folder.appendingPathComponent("Nope.app")
        let process = try UpdateInstallerCore.startReplacement(pid: 999_999, newApp: missing, destination: destination, relaunch: false, in: folder)
        process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version")), "old")
    }
}

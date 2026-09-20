import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Downloads a new version from a GitHub release and swaps it in for the running app.
///
/// A file this app downloads itself isn't marked as quarantined, so the new copy opens
/// without the "Open Anyway" step that a browser download needs. Before anything is
/// replaced the download's checksum is compared with the release's `SHA256SUMS.txt` and the
/// app inside is checked (same bundle identifier, expected version, intact signature).
enum UpdateInstallerCore {
    enum Failure: LocalizedError {
        case checksumMismatch
        case noAppInArchive
        case wrongApp(String)
        case badSignature
        case notWritable(String)
        case notAnAppBundle
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch: return "The download doesn't match its checksum, so it wasn't installed."
            case .noAppInArchive: return "The download didn't contain the app."
            case .wrongApp(let why): return "The download isn't the expected app (\(why))."
            case .badSignature: return "The downloaded app's signature is damaged."
            case .notWritable(let folder): return "SwiftImmich can't replace itself in \(folder). Install the update by hand instead."
            case .notAnAppBundle: return "Updates can only be installed into the packaged app."
            case .commandFailed(let what): return "\(what) failed."
            }
        }
    }

    /// SHA-256 of a file, read in chunks so a large download isn't held in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The hash listed for `filename` in a `shasum` style file ("<hash>  <name>" per line).
    static func expectedHash(for filename: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields.last.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }) == filename else { continue }
            return String(fields[0]).lowercased()
        }
        return nil
    }

    /// Unzips the archive and returns the `.app` inside it.
    static func extractApp(from zip: URL, into folder: URL) throws -> URL {
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], what: "Unzipping the download")
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw Failure.noAppInArchive }
        return app
    }

    /// Checks the unpacked app is this app, at the version the release claims, and unmodified.
    static func validate(app: URL, bundleIdentifier: String, expectedVersion: AppVersion?) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plistURL) as? [String: Any] else { throw Failure.wrongApp("no Info.plist") }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw Failure.wrongApp("different app") }
        if let expectedVersion,
           let found = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
           found != expectedVersion {
            throw Failure.wrongApp("version \(found), expected \(expectedVersion)")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], what: "Checking the signature")
        } catch {
            throw Failure.badSignature
        }
    }

    /// A small script that waits for the running app to quit, swaps the new copy in (putting
    /// the old one back if that fails), clears any quarantine flag and starts the new one.
    static let replacementScript = """
    #!/bin/bash
    PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"
    for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.3; done
    BACKUP="${DEST}.previous"
    rm -rf "$BACKUP"
    mv "$DEST" "$BACKUP" 2>/dev/null
    if ditto "$NEW" "$DEST"; then
        xattr -cr "$DEST" 2>/dev/null
        rm -rf "$BACKUP"
    else
        rm -rf "$DEST"
        mv "$BACKUP" "$DEST"
    fi
    if [ "$RELAUNCH" = "1" ]; then open "$DEST"; fi
    """

    /// Starts the replacement script. It keeps running after this app quits.
    @discardableResult
    static func startReplacement(pid: Int32, newApp: URL, destination: URL, relaunch: Bool, in folder: URL) throws -> Process {
        let script = folder.appendingPathComponent("replace-app.sh")
        try replacementScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(pid), newApp.path, destination.path, relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], what: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.commandFailed(what) }
        return process.terminationStatus
    }
}

/// Drives an update from the release info to a relaunched app, showing progress in a small window.
@MainActor
final class UpdateInstaller: ObservableObject {
    @Published private(set) var message = "Starting…"
    @Published private(set) var failure: String?

    private var window: NSWindow?

    func install(_ release: ReleaseInfo) async {
        showWindow()
        do {
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw UpdateInstallerCore.Failure.notAnAppBundle }
            guard let zipURL = release.zipURL else { throw UpdateInstallerCore.Failure.wrongApp("the release has no zip") }
            let destination = Bundle.main.bundleURL
            let parent = destination.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateInstallerCore.Failure.notWritable(parent.path)
            }

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftImmich-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            message = "Downloading \(release.version)…"
            let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateInstallerCore.Failure.commandFailed("Downloading the update")
            }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            message = "Checking the download…"
            if let sumsURL = release.checksumsURL {
                let (data, _) = try await URLSession.shared.data(from: sumsURL)
                let sums = String(decoding: data, as: UTF8.self)
                let name = zipURL.lastPathComponent
                guard let expected = UpdateInstallerCore.expectedHash(for: name, in: sums),
                      expected == (try UpdateInstallerCore.sha256(of: zip))
                else { throw UpdateInstallerCore.Failure.checksumMismatch }
            }

            let unpacked = work.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let newApp = try UpdateInstallerCore.extractApp(from: zip, into: unpacked)
            try UpdateInstallerCore.validate(
                app: newApp,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                expectedVersion: release.version
            )

            message = "Restarting…"
            AppLog.info("installing update \(release.version) over \(AppInfo.version)")
            try UpdateInstallerCore.startReplacement(
                pid: ProcessInfo.processInfo.processIdentifier, newApp: newApp,
                destination: destination, relaunch: true, in: work
            )
            NSApp.terminate(nil)
        } catch {
            AppLog.error("update install", error)
            failure = error.localizedDescription
            message = "The update couldn't be installed."
        }
    }

    // MARK: - Window

    private func showWindow() {
        let view = UpdateProgressView(installer: self) { [weak self] in self?.window?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Updating SwiftImmich"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct UpdateProgressView: View {
    @ObservedObject var installer: UpdateInstaller
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(installer.message).font(.headline)
            if let failure = installer.failure {
                Text(failure).font(.callout).foregroundStyle(.red)
                HStack {
                    Spacer()
                    Button("Open Releases Page") { NSWorkspace.shared.open(AppInfo.releasesPage) }
                    Button("Close", action: onClose)
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

import AppKit
import Foundation

enum AppInfo {
    /// Where releases are published; the update check reads the latest one from here.
    static let repository = "newgotha/swiftimmich"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

/// A dotted version like 1.2.3, compared number by number (so 1.10 is newer than 1.9).
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]

    /// Accepts "1.2.3" or "v1.2.3"; anything after a "-" (a pre-release label) is ignored.
    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("v") { trimmed.removeFirst() }
        let core = trimmed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct ReleaseInfo: Equatable {
    let version: AppVersion
    let notes: String
    let pageURL: URL
    /// The disk image (or zip) attached to the release, if there is one.
    let downloadURL: URL?
}

enum UpdateResult: Equatable {
    case upToDate
    case noReleases
    case available(ReleaseInfo)
    case failed(String)
}

/// Looks for a newer release on GitHub and tells the user; installing is a normal download
/// (the app isn't notarized, so it can't replace itself).
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"

    private init() {}

    // MARK: - Fetching

    /// Turns GitHub's "latest release" reply into a `ReleaseInfo`. Drafts and pre-releases
    /// are never offered.
    nonisolated static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["draft"] as? Bool) != true, (json["prerelease"] as? Bool) != true,
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(ending suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        return ReleaseInfo(
            version: version,
            notes: (json["body"] as? String) ?? "",
            pageURL: page,
            downloadURL: asset(ending: ".dmg") ?? asset(ending: ".zip")
        )
    }

    nonisolated static func check(
        currentVersion: String = AppInfo.version,
        session: URLSession = .shared
    ) async -> UpdateResult {
        guard let current = AppVersion(currentVersion) else { return .failed("Unrecognised app version “\(currentVersion)”.") }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .noReleases }
            guard status == 200 else { return .failed("GitHub answered \(status).") }
            guard let release = parse(data) else { return .noReleases }
            return release.version > current ? .available(release) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Asking the user

    /// "Check for Updates…" — always answers, even when there's nothing new.
    func checkNow() async {
        let result = await Self.check()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        switch result {
        case .available(let release): present(release, allowSkip: false)
        case .upToDate: inform("You're up to date", "SwiftImmich \(AppInfo.version) is the latest version.")
        case .noReleases: inform("You're up to date", "SwiftImmich \(AppInfo.version) is the latest version (no newer release has been published).")
        case .failed(let reason): inform("Couldn't check for updates", reason)
        }
    }

    /// At launch: at most once a day, and silent unless there's something new the user hasn't skipped.
    func checkAtLaunchIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true else { return }
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        let result = await Self.check()
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        if case .available(let release) = result, defaults.string(forKey: Self.skippedKey) != release.version.description {
            present(release, allowSkip: true)
        }
    }

    private func present(_ release: ReleaseInfo, allowSkip: Bool) {
        let alert = NSAlert()
        alert.messageText = "SwiftImmich \(release.version) is available"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have \(AppInfo.version)." + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        if allowSkip { alert.addButton(withTitle: "Skip This Version") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
        default:
            break
        }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

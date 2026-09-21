import AppKit
import ImmichAPI
import SwiftUI
import UserNotifications

/// macOS notifications for things that finish while you're in another app.
enum Notifier {
    static let importsKey = "notifyImports"
    static let commentsKey = "notifyComments"

    /// Notifications only work for a real app bundle (not while running tests or from the command line).
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func isEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Posts a notification, unless it's switched off or you're already looking at the app.
    @MainActor
    static func post(title: String, body: String, setting key: String, id: String = UUID().uuidString) {
        guard isAvailable, isEnabled(key), !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

/// What to say when an import from Photos ends.
enum ImportNotice {
    static func make(uploaded: Int, failed: Int, stopReason: String?, wasCancelledByUser: Bool) -> (title: String, body: String)? {
        if wasCancelledByUser && stopReason == nil { return nil }
        if let stopReason {
            return ("Import stopped", stopReason)
        }
        if failed > 0 {
            let done = uploaded == 0 ? "" : "\(uploaded) uploaded, "
            return ("Import finished with problems", "\(done)\(failed) couldn't be imported. Open SwiftImmich to see which.")
        }
        if uploaded > 0 {
            return ("Import finished", uploaded == 1 ? "1 photo was added to your library." : "\(uploaded) photos were added to your library.")
        }
        return nil
    }
}

/// Finds comments other people have added to a shared album since you last looked.
enum CommentWatch {
    struct Comment: Equatable {
        let author: String
        let text: String
        let date: Date
        let isMine: Bool
    }

    static func newComments(_ comments: [Comment], since: Date) -> [Comment] {
        comments.filter { $0.date > since && !$0.isMine }.sorted { $0.date < $1.date }
    }

    static func notice(album: String, comments: [Comment]) -> (title: String, body: String)? {
        guard let latest = comments.last else { return nil }
        if comments.count == 1 {
            return ("\(latest.author) commented in “\(album)”", latest.text)
        }
        return ("\(comments.count) new comments in “\(album)”", "\(latest.author): \(latest.text)")
    }

    private static let seenKey = "commentLastSeen"

    static func lastSeen(_ albumId: String) -> Date? {
        let stored = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double]
        return stored?[albumId].map { Date(timeIntervalSince1970: $0) }
    }

    static func markSeen(_ albumId: String, at date: Date) {
        var stored = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        stored[albumId] = date.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: seenKey)
    }
}

/// Every few minutes, looks for new comments on your shared albums and notifies you.
struct ActivityWatcher: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content.task(id: service?.apiURL.absoluteString) { await run() }
    }

    private func run() async {
        guard let service else { return }
        try? await Task.sleep(for: .seconds(30))   // let the app settle after launch
        while !Task.isCancelled {
            await check(service)
            try? await Task.sleep(for: .seconds(300))
        }
    }

    @MainActor
    private func check(_ service: ImmichService) async {
        guard Notifier.isAvailable, Notifier.isEnabled(Notifier.commentsKey) else { return }
        let me = service.sharing.currentUserId
        for album in selection.albums where album.shared && album.isActivityEnabled {
            guard let activities = try? await service.fetchActivities(albumId: album.id, assetId: nil) else { continue }
            let comments = activities.filter { $0._type == .comment }.map {
                CommentWatch.Comment(author: $0.user.name, text: $0.comment ?? "", date: $0.createdAt, isMine: $0.user.id == me)
            }
            // The first look at an album only sets the starting point; older comments aren't news.
            guard let seen = CommentWatch.lastSeen(album.id) else {
                CommentWatch.markSeen(album.id, at: Date())
                continue
            }
            let fresh = CommentWatch.newComments(comments, since: seen)
            if let notice = CommentWatch.notice(album: album.albumName, comments: fresh) {
                Notifier.post(title: notice.title, body: notice.body, setting: Notifier.commentsKey, id: "comments-\(album.id)")
            }
            if let newest = comments.map(\.date).max(), newest > seen { CommentWatch.markSeen(album.id, at: newest) }
        }
    }
}

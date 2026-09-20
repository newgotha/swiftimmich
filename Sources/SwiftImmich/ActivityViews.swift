import ImmichAPI
import SwiftUI

/// What activity (comments and likes) is being shown: a whole album's, or one photo's in it.
struct ActivityRequest: Identifiable {
    let id = UUID()
    let albumId: String
    let albumName: String
    let assetId: String?
}

/// Comments and likes on a shared album or one of its photos.
struct ActivitySheet: View {
    let service: ImmichService
    let request: ActivityRequest
    var onClose: () -> Void

    @State private var activities: [ImmichService.Activity] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var text = ""
    @State private var errorMessage: String?

    private var me: String? { service.sharing.currentUserId }
    private var comments: [ImmichService.Activity] { activities.filter { $0._type == .comment } }
    private var likes: [ImmichService.Activity] { activities.filter { $0._type == .like } }
    private var myLike: ImmichService.Activity? { likes.first { $0.user.id == me } }

    private static let dateFormat: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.assetId == nil ? "Album activity" : "Photo activity")
                        .font(.headline)
                    Text(request.albumName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    Task { await toggleLike() }
                } label: {
                    Label(likes.isEmpty ? "Like" : "\(likes.count)", systemImage: myLike == nil ? "hand.thumbsup" : "hand.thumbsup.fill")
                }
                .disabled(isWorking)
                .help(likes.map(\.user.name).joined(separator: ", "))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if comments.isEmpty {
                        Text(isLoading ? "Loading…" : "No comments yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(comments, id: \.id) { comment in
                        HStack(alignment: .top, spacing: 10) {
                            UserBadge(name: comment.user.name, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(comment.user.name).font(.callout.weight(.semibold))
                                    Text(Self.dateFormat.localizedString(for: comment.createdAt, relativeTo: Date()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(comment.comment ?? "").font(.callout).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            if comment.user.id == me {
                                Button { Task { await remove(comment) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("Delete your comment")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 320)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                TextField("Add a comment", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await send() } }
                Button("Send") { Task { await send() } }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            activities = try await service.fetchActivities(albumId: request.albumId, assetId: request.assetId)
                .sorted { $0.createdAt < $1.createdAt }
        } catch {
            errorMessage = describe(error)
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
            await reload()
            NotificationCenter.default.post(name: .activityChanged, object: request.albumId)
        } catch {
            errorMessage = describe(error)
        }
    }

    private func send() async {
        let comment = text.trimmingCharacters(in: .whitespaces)
        guard !comment.isEmpty else { return }
        await run {
            try await service.createActivity(albumId: request.albumId, assetId: request.assetId, comment: comment)
            text = ""
        }
    }

    private func toggleLike() async {
        await run {
            if let myLike {
                try await service.deleteActivity(id: myLike.id)
            } else {
                try await service.createActivity(albumId: request.albumId, assetId: request.assetId, comment: nil)
            }
        }
    }

    private func remove(_ activity: ImmichService.Activity) async {
        await run { try await service.deleteActivity(id: activity.id) }
    }

    private func describe(_ error: Error) -> String {
        AppLog.error("activity", error)
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            return "The server said \(status)" + (message.map { ": \($0.prefix(140))" } ?? "")
        }
        return error.localizedDescription
    }
}

extension Notification.Name {
    /// Posted (object: album id) after a comment or like changed, so counts can refresh.
    static let activityChanged = Notification.Name("dev.local.swiftimmich.activityChanged")
}

/// Shows the activity sheet when the selection hub asks for it.
struct ActivityPresenter: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content.sheet(item: $selection.pendingActivity) { request in
            if let service {
                ActivitySheet(service: service, request: request) { selection.pendingActivity = nil }
            }
        }
    }
}

/// The "Activity" button beside an album's title, with its comment and like counts.
struct AlbumActivityButton: View {
    let service: ImmichService
    let album: Album
    @EnvironmentObject private var selection: GridSelection
    @State private var counts: (comments: Int, likes: Int)?

    var body: some View {
        Button {
            selection.pendingActivity = ActivityRequest(albumId: album.id, albumName: album.albumName, assetId: nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text(label)
            }
        }
        .buttonStyle(ToolbarPillStyle())
        .font(.callout)
        .task(id: album.id) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .activityChanged)) { note in
            if (note.object as? String) == album.id { Task { await refresh() } }
        }
    }

    private var label: String {
        guard let counts, counts.comments + counts.likes > 0 else { return "Activity" }
        return "\(counts.comments) · \(counts.likes) 👍"
    }

    private func refresh() async {
        counts = try? await service.activityCounts(albumId: album.id, assetId: nil)
    }
}

/// Remembers how many photos other people had added to each shared album when it was last
/// opened, so the sidebar can flag albums that have grown since.
enum AlbumSeen {
    static let key = "albumSeenOthers"

    static func load(_ json: String) -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8))) ?? [:]
    }

    static func save(_ counts: [String: Int]) -> String {
        (try? String(data: JSONEncoder().encode(counts), encoding: .utf8)) ?? ""
    }

    /// Photos in the album contributed by someone other than `me`.
    static func othersCount(_ album: Album, me: String?) -> Int {
        (album.contributorCounts ?? []).filter { $0.userId != me }.reduce(0) { $0 + $1.assetCount }
    }
}

import ImmichAPI
import SwiftUI

typealias Album = Components.Schemas.AlbumResponseDto
typealias ServerUser = Components.Schemas.UserResponseDto

extension Album {
    /// Your role in this album, or nil if it isn't listed (which is how your own,
    /// not-yet-shared albums look).
    func role(of userId: String?) -> Components.Schemas.AlbumUserRole? {
        guard let userId else { return nil }
        return albumUsers.first { $0.user.id == userId }?.role
    }

    func isOwned(by userId: String?) -> Bool {
        let role = role(of: userId)
        return role == nil || role == .owner
    }

    /// Owners and editors can add photos; viewers can't.
    func canAddPhotos(userId: String?) -> Bool { role(of: userId) != .viewer }
}

/// A round initial in place of a profile picture.
struct UserBadge: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        let hue = Double(abs(name.hashValue) % 360) / 360
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.5, brightness: 0.65), in: Circle())
    }
}

private func describe(_ error: Error) -> String {
    AppLog.error("sharing action failed", error)
    if case ImmichServiceError.requestFailed(let status, let message) = error {
        return "The server said \(status)" + (message.map { ": \($0.prefix(160))" } ?? "")
    }
    return error.localizedDescription
}

/// Who can see (and add to) an album, and a way to invite more people.
struct AlbumSharingSheet: View {
    let service: ImmichService
    let albumId: String
    var onChanged: (Album) -> Void
    var onClose: () -> Void

    @State private var album: Album?
    @State private var users: [ServerUser] = []
    @State private var newRole: Components.Schemas.AlbumUserRole = .viewer
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var me: String? { service.sharing.currentUserId }
    private var isOwner: Bool { album?.isOwned(by: me) ?? false }
    private var memberIds: Set<String> { Set(album?.albumUsers.map(\.user.id) ?? []) }
    private var candidates: [ServerUser] {
        users.filter { $0.id != me && !memberIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Share “\(album?.albumName ?? "Album")”")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }

            if let album {
                VStack(alignment: .leading, spacing: 6) {
                    Text("People with access")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let members = album.albumUsers.filter { $0.role != .owner }
                    if members.isEmpty {
                        Text("Only you, for now.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(members, id: \.user.id) { member in
                        memberRow(member)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Add people")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $newRole) {
                            Text("Can view").tag(Components.Schemas.AlbumUserRole.viewer)
                            Text("Can add photos").tag(Components.Schemas.AlbumUserRole.editor)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    if candidates.isEmpty {
                        Text(users.isEmpty ? "Loading people…" : "Everyone on this server already has access.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.id) { user in
                        HStack(spacing: 10) {
                            UserBadge(name: user.name)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(user.name).font(.callout)
                                Text(user.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { Task { await add(user) } }
                        }
                    }
                }
                .disabled(!isOwner)

                if !isOwner {
                    Text("Only the album's owner can change who it's shared with.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if errorMessage == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(HoverProminentStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            await reload()
            users = (try? await service.fetchUsers()) ?? []
        }
    }

    private func memberRow(_ member: Components.Schemas.AlbumUserResponseDto) -> some View {
        HStack(spacing: 10) {
            UserBadge(name: member.user.name)
            VStack(alignment: .leading, spacing: 0) {
                Text(member.user.name).font(.callout)
                Text(member.user.email).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isOwner {
                Menu {
                    Button("Can view") { Task { await setRole(.viewer, for: member.user) } }
                    Button("Can add photos") { Task { await setRole(.editor, for: member.user) } }
                    Divider()
                    Button("Remove", role: .destructive) { Task { await remove(member.user) } }
                } label: {
                    Text(member.role == .editor ? "Can add photos" : "Can view")
                }
                .fixedSize()
            } else {
                Text(member.role == .editor ? "Can add photos" : "Can view")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        do {
            let fresh = try await service.fetchAlbum(id: albumId)
            album = fresh
            onChanged(fresh)
        } catch {
            errorMessage = "Couldn't load the album: \(describe(error))"
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
            await reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func add(_ user: ServerUser) async {
        await run { try await service.addUsers([(id: user.id, role: newRole)], toAlbum: albumId) }
    }

    private func setRole(_ role: Components.Schemas.AlbumUserRole, for user: ServerUser) async {
        await run { try await service.setRole(role, forUser: user.id, inAlbum: albumId) }
    }

    private func remove(_ user: ServerUser) async {
        await run { try await service.removeUser(user.id, fromAlbum: albumId) }
    }
}

/// Presents the album sharing sheet when the selection hub asks for it.
struct AlbumSharingPresenter: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { selection.pendingShareAlbum != nil },
            set: { if !$0 { selection.pendingShareAlbum = nil } }
        )) {
            if let service, let album = selection.pendingShareAlbum {
                AlbumSharingSheet(service: service, albumId: album.id, onChanged: { selection.onAlbumUpdated?($0) }) {
                    selection.pendingShareAlbum = nil
                }
            }
        }
    }
}

/// "Sharing" page: who your whole library is shared with, and whose libraries are
/// shared with you (optionally mixed into your own Library).
struct SharingView: View {
    let service: ImmichService

    @State private var sharedByMe: [Components.Schemas.PartnerResponseDto] = []
    @State private var sharedWithMe: [Components.Schemas.PartnerResponseDto] = []
    @State private var users: [ServerUser] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var partnerToRemove: Components.Schemas.PartnerResponseDto?

    private let contentLeadingPadding: CGFloat = 20
    private var me: String? { service.sharing.currentUserId }
    private var candidates: [ServerUser] {
        let taken = Set(sharedByMe.map(\.id))
        return users.filter { $0.id != me && !taken.contains($0.id) }
    }

    var body: some View {
        CardPage(maxWidth: 620) {
            Text("Sharing")
                .font(.title2.weight(.bold))

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            section(
                title: "Shared with you",
                footer: "Turn on “Show in Library” to see their photos alongside yours. You can view and download them, but not change them."
            ) {
                if sharedWithMe.isEmpty {
                    Text(isLoading ? "Loading…" : "Nobody is sharing their library with you.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sharedWithMe, id: \.id) { partner in
                    HStack(spacing: 10) {
                        UserBadge(name: partner.name)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(partner.name).font(.callout)
                            Text(partner.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Show in Library", isOn: Binding(
                            get: { partner.inTimeline ?? false },
                            set: { value in Task { await setInTimeline(partner, value) } }
                        ))
                        .toggleStyle(.switch)
                    }
                }
            }

            Divider()

            section(
                title: "Your library is shared with",
                footer: "These people can see every photo in your library (not your archive or trash)."
            ) {
                if sharedByMe.isEmpty {
                    Text(isLoading ? "Loading…" : "You aren't sharing your library with anyone.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sharedByMe, id: \.id) { partner in
                    HStack(spacing: 10) {
                        UserBadge(name: partner.name)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(partner.name).font(.callout)
                            Text(partner.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop Sharing", role: .destructive) { partnerToRemove = partner }
                    }
                }
                Menu {
                    ForEach(candidates, id: \.id) { user in
                        Button("\(user.name) (\(user.email))") { Task { await addPartner(user) } }
                    }
                } label: {
                    Label("Share My Library With…", systemImage: "person.badge.plus")
                }
                .fixedSize()
                .disabled(candidates.isEmpty || isWorking)
            }

            Divider()

            SharedLinksSection(service: service)
        }
        .navigationTitle("")
        .task { await reload() }
        .confirmationDialog(
            "Stop sharing your library with \(partnerToRemove?.name ?? "them")?",
            isPresented: Binding(get: { partnerToRemove != nil }, set: { if !$0 { partnerToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                if let partner = partnerToRemove { Task { await removePartner(partner) } }
                partnerToRemove = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func section<Content: View>(title: String, footer: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let by = service.fetchPartners(sharedByMe: true)
            async let with = service.fetchPartners(sharedByMe: false)
            async let everyone = service.fetchUsers()
            (sharedByMe, sharedWithMe, users) = try await (by, with, everyone)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load sharing: \(describe(error))"
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
        await reload()
    }

    private func addPartner(_ user: ServerUser) async {
        await run { try await service.addPartner(userId: user.id) }
    }

    private func removePartner(_ partner: Components.Schemas.PartnerResponseDto) async {
        await run { try await service.removePartner(userId: partner.id) }
    }

    private func setInTimeline(_ partner: Components.Schemas.PartnerResponseDto, _ value: Bool) async {
        await run {
            try await service.setPartnerInTimeline(userId: partner.id, value)
            // Whether the Library includes partners is decided across all of them.
            var updated = sharedWithMe
            if let index = updated.firstIndex(where: { $0.id == partner.id }) { updated[index].inTimeline = value }
            service.sharing.includePartnerPhotos = updated.contains { $0.inTimeline == true }
            NotificationCenter.default.post(name: .gridNeedsReload, object: nil)
        }
    }
}

/// The two-person icon on a shared album. Hovering it shows who the album is shared with,
/// or who shared it with you.
struct SharedAlbumBadge: View {
    let album: Album
    let currentUserId: String?
    var size: Font = .callout

    @State private var isHovering = false

    private var owner: Components.Schemas.AlbumUserResponseDto? {
        album.albumUsers.first { $0.role == .owner }
    }

    private var iOwnIt: Bool { album.isOwned(by: currentUserId) }

    private var others: [Components.Schemas.AlbumUserResponseDto] {
        album.albumUsers.filter { $0.role != .owner }
    }

    private static func roleText(_ role: Components.Schemas.AlbumUserRole) -> String {
        switch role {
        case .owner: return "Owner"
        case .editor: return "Can add photos"
        case .viewer: return "Can view"
        }
    }

    var body: some View {
        Image(systemName: "person.2")
            .font(size)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) { details }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if iOwnIt {
                Text(others.isEmpty ? "Shared album" : "Shared with")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Shared by \(owner?.user.name ?? "someone")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // For an album shared with you, the owner comes first; for your own, just the guests.
            ForEach(iOwnIt ? others : (owner.map { [$0] } ?? []) + others, id: \.user.id) { member in
                HStack(spacing: 8) {
                    UserBadge(name: member.user.name, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(member.user.id == currentUserId ? "\(member.user.name) (you)" : member.user.name)
                            .font(.callout)
                            .lineLimit(1)
                        Text(Self.roleText(member.role)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 200, alignment: .leading)
    }
}

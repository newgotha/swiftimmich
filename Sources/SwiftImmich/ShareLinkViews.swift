import AppKit
import ImmichAPI
import SwiftUI

typealias SharedLink = Components.Schemas.SharedLinkResponseDto

/// What a share link is being made for: some photos, or one whole album.
struct ShareLinkRequest: Identifiable {
    let id = UUID()
    let title: String
    let assetIds: [String]?
    let albumId: String?
}

/// Options for a new public link, then the link itself to copy.
struct ShareLinkSheet: View {
    enum Expiry: String, CaseIterable, Identifiable {
        case never = "Never", hour = "1 hour", day = "1 day", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var date: Date? {
            let seconds: Double
            switch self {
            case .never: return nil
            case .hour: seconds = 3600
            case .day: seconds = 86400
            case .week: seconds = 7 * 86400
            case .month: seconds = 30 * 86400
            }
            return Date().addingTimeInterval(seconds)
        }
    }

    let service: ImmichService
    let request: ShareLinkRequest
    var onClose: () -> Void

    @State private var expiry: Expiry = .never
    @State private var password = ""
    @State private var allowDownload = true
    @State private var showMetadata = true
    @State private var allowUpload = false
    @State private var created: URL?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isAlbum: Bool { request.albumId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(created == nil ? "Create Share Link" : "Link Ready")
                .font(.headline)
            Text(request.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let created {
                Text(created.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Label("Copied to your clipboard. Anyone with this link can view it\(password.isEmpty ? "" : " (with the password)").", systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Copy Again") { copy(created) }
                    Button("Open in Browser") { NSWorkspace.shared.open(created) }
                    Spacer()
                    Button("Done", action: onClose)
                        .buttonStyle(HoverProminentStyle())
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Form {
                    Picker("Expires", selection: $expiry) {
                        ForEach(Expiry.allCases) { Text($0.rawValue).tag($0) }
                    }
                    SecureField("Password (optional)", text: $password)
                    Toggle("Allow downloads", isOn: $allowDownload)
                    Toggle("Show location and camera details", isOn: $showMetadata)
                    if isAlbum {
                        Toggle("Allow people to upload photos", isOn: $allowUpload)
                    }
                }
                .formStyle(.columns)

                Text("Anyone who has the link can see \(isAlbum ? "this album" : "these photos") — no account needed. You can turn a link off any time from Sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                    Button("Create Link") { Task { await create() } }
                        .buttonStyle(HoverProminentStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let link = try await service.createSharedLink(
                assetIds: request.assetIds,
                albumId: request.albumId,
                expiresAt: expiry.date,
                password: password,
                allowDownload: allowDownload,
                allowUpload: isAlbum && allowUpload,
                showMetadata: showMetadata
            )
            let url = service.sharedLinkURL(link)
            copy(url)
            created = url
        } catch {
            if case ImmichServiceError.requestFailed(let status, let message) = error {
                errorMessage = "The server said \(status)" + (message.map { ": \($0.prefix(160))" } ?? "")
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// Shows the link sheet when the selection hub asks for one.
struct ShareLinkPresenter: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content.sheet(item: $selection.pendingShareLink) { request in
            if let service {
                ShareLinkSheet(service: service, request: request) { selection.pendingShareLink = nil }
            }
        }
    }
}

/// The links you've made, with a way to copy or turn each one off. Sits on the Sharing page.
struct SharedLinksSection: View {
    let service: ImmichService
    @State private var links: [SharedLink] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var linkToRemove: SharedLink?

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared links").font(.headline)
            if links.isEmpty {
                Text(isLoading ? "Loading…" : "You haven't made any links. Right-click a photo or album and choose Create Share Link.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(links, id: \.id) { link in
                HStack(spacing: 10) {
                    Image(systemName: link.album != nil ? "rectangle.stack" : "photo.on.rectangle")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title(for: link)).font(.callout).lineLimit(1)
                        Text(detail(for: link)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { copy(link) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy link")
                    Button(role: .destructive) { linkToRemove = link } label: { Image(systemName: "trash") }
                        .help("Turn off this link")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Text("Turning a link off makes it stop working straight away. The photos themselves aren't affected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await reload() }
        .confirmationDialog(
            "Turn off this link?",
            isPresented: Binding(get: { linkToRemove != nil }, set: { if !$0 { linkToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Turn Off Link", role: .destructive) {
                if let link = linkToRemove { Task { await remove(link) } }
                linkToRemove = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func title(for link: SharedLink) -> String {
        if let album = link.album { return album.albumName }
        if let description = link.description, !description.isEmpty { return description }
        return "\(link.assets.count) \(link.assets.count == 1 ? "photo" : "photos")"
    }

    private func detail(for link: SharedLink) -> String {
        var parts = ["Created \(Self.dateFormat.string(from: link.createdAt))"]
        if let expires = link.expiresAt { parts.append("expires \(Self.dateFormat.string(from: expires))") }
        if link.password != nil { parts.append("password") }
        return parts.joined(separator: " · ")
    }

    private func copy(_ link: SharedLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.sharedLinkURL(link).absoluteString, forType: .string)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            links = try await service.fetchSharedLinks().sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load links: \(error.localizedDescription)"
        }
    }

    private func remove(_ link: SharedLink) async {
        do {
            try await service.removeSharedLink(id: link.id)
            links.removeAll { $0.id == link.id }
        } catch {
            errorMessage = "Couldn't turn the link off: \(error.localizedDescription)"
        }
    }
}

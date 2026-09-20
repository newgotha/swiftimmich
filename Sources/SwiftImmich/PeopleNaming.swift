import ImmichAPI
import SwiftUI

typealias Person = Components.Schemas.PersonResponseDto
typealias Face = Components.Schemas.AssetFaceResponseDto

extension Face {
    /// The generated type wraps the nullable `person` in an `allOf` payload; this unwraps it.
    var matchedPerson: Person? { person?.value1 }
}

/// Everyone Immich has found, shared by the People page and the photo info pane so a
/// name typed in one shows up in the other straight away.
@MainActor
final class PeopleDirectory: ObservableObject {
    @Published private(set) var people: [Person] = []
    @Published private(set) var isLoaded = false
    private var isLoading = false

    var namedPeople: [Person] { people.filter { !$0.name.isEmpty } }

    func loadIfNeeded(service: ImmichService) async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let loaded = try? await service.fetchPeople() {
            people = loaded
            isLoaded = true
        }
    }

    /// Forgets everything, e.g. when connecting to a different server.
    func invalidate() {
        people = []
        isLoaded = false
    }

    func reload(service: ImmichService) async {
        isLoaded = false
        await loadIfNeeded(service: service)
    }

    func upsert(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index] = person
        } else {
            people.insert(person, at: 0)
        }
    }

    func remove(id: String) {
        people.removeAll { $0.id == id }
    }
}

/// A small popover for naming someone: either a person on the People page, or one face
/// in the photo being viewed.
///
/// Typing a name and saving names that person (which names them in every photo, since a
/// "person" is a cluster of matching faces). Picking someone who's already named is
/// different — it says "this is that person" — so an unnamed cluster is merged into
/// them (all its photos move over), while a face that's already someone else is moved
/// on its own, leaving the rest of that person alone.
struct PersonNameEditor: View {
    enum Target {
        case person(Person)
        case face(Face)

        var person: Person? {
            switch self {
            case .person(let person): return person
            case .face(let face): return face.matchedPerson
            }
        }
    }

    let service: ImmichService
    let target: Target
    /// Called after a successful change so the caller can refresh what it's showing.
    var onChanged: () -> Void
    var onClose: () -> Void

    @EnvironmentObject private var directory: PeopleDirectory
    @State private var text: String
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(service: ImmichService, target: Target, onChanged: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.service = service
        self.target = target
        self.onChanged = onChanged
        self.onClose = onClose
        _text = State(initialValue: target.person?.name ?? "")
    }

    private var current: Person? { target.person }
    private var isUnnamed: Bool { current == nil || current?.name.isEmpty == true }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Someone who's already named — for renaming a person who already has a name from
    /// the People page there's nothing to choose between, so nothing is offered.
    private var suggestions: [Person] {
        if case .person = target, !isUnnamed { return [] }
        let others = directory.namedPeople.filter { $0.id != current?.id }
        guard !trimmed.isEmpty else { return Array(others.prefix(6)) }
        return Array(others.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isUnnamed ? "Who is this?" : "Rename")
                .font(.headline)

            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { Task { await save() } }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trimmed.isEmpty ? "Or pick someone you've already named" : "Already named")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.id) { person in
                        Button {
                            Task { await choose(person) }
                        } label: {
                            HStack(spacing: 8) {
                                CoverImageView(
                                    cacheKey: "person-\(person.id)",
                                    request: service.personThumbnailRequest(personId: person.id)
                                )
                                .frame(width: 26, height: 26)
                                .clipShape(Circle())
                                Text(person.name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                    Text(chooseHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onClose)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || trimmed.isEmpty || trimmed == current?.name)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .disabled(isWorking)
        .onAppear { isFocused = true }
    }

    private var chooseHint: String {
        if current == nil { return "Tags just this face." }
        return isUnnamed ? "Merges everyone in this cluster into that person." : "Moves just this face to them."
    }

    // MARK: - Actions

    private func save() async {
        guard !trimmed.isEmpty else { return }
        await perform {
            if let current {
                directory.upsert(try await service.renamePerson(id: current.id, name: trimmed))
            } else if case .face(let face) = target {
                let created = try await service.createPerson(name: trimmed)
                try await service.assignFace(face.id, toPerson: created.id)
                directory.upsert(created)
            }
        }
    }

    private func choose(_ existing: Person) async {
        await perform {
            switch (current, target) {
            case (nil, .face(let face)):
                try await service.assignFace(face.id, toPerson: existing.id)
            case (let current?, _) where current.name.isEmpty:
                try await service.mergePerson(current.id, into: existing.id)
                directory.remove(id: current.id)
            case (_, .face(let face)):
                try await service.assignFace(face.id, toPerson: existing.id)
            default:
                break
            }
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        do {
            try await work()
            onChanged()
            onClose()
        } catch {
            if case ImmichServiceError.requestFailed(let status, let message) = error {
                errorMessage = "The server said \(status)" + (message.map { ": \($0.prefix(120))" } ?? "")
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isWorking = false
    }
}

/// A face in the photo being viewed that the user wants to name.
struct PendingFace: Identifiable {
    let face: Face
    let assetId: String
    var id: String { face.id }
}

/// Shows the naming dialog for a face clicked in the viewer. A window-level sheet rather
/// than a popover on the box itself, which proved unreliable on top of the viewer.
struct FaceNamingPresenter: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection
    /// Passed in rather than read from the environment: a sheet presented from up here
    /// doesn't inherit environment objects injected below this point, and the editor
    /// needs the people list (missing it crashed the app).
    let directory: PeopleDirectory

    func body(content: Content) -> some View {
        content.sheet(item: $selection.pendingNameFace) { pending in
            if let service {
                PersonNameEditor(
                    service: service,
                    target: .face(pending.face),
                    onChanged: {
                        NotificationCenter.default.post(name: .assetMetadataChanged, object: [pending.assetId])
                    },
                    onClose: { selection.pendingNameFace = nil }
                )
                .environmentObject(directory)
            }
        }
    }
}

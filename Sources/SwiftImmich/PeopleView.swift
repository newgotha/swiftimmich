import SwiftUI
import ImmichAPI

struct PeopleView: View {
    let service: ImmichService

    @EnvironmentObject private var directory: PeopleDirectory
    @State private var editingPersonId: String?
    @State private var birthdayPersonId: String?
    @State private var showingHidden = false
    @State private var hiddenPeople: [Person] = []
    @State private var coverRevision = 0
    /// Kept local: observing the grid's shared selection state here made this page redraw on every hover.
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 16)]
    private let contentLeadingPadding: CGFloat = 20

    /// Favorites first, then everyone else in the order the server gave.
    private var shownPeople: [Person] {
        if showingHidden { return hiddenPeople }
        let favorites = directory.people.filter { $0.isFavorite == true }
        return favorites + directory.people.filter { $0.isFavorite != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(showingHidden ? "Hidden People" : "People")
                    .font(.title2.weight(.bold))
                Spacer()
                Button(showingHidden ? "Done" : "Show Hidden") { toggleHidden() }
                    .buttonStyle(ToolbarPillStyle())
                    .font(.callout)
            }
            .padding(.leading, contentLeadingPadding)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(shownPeople, id: \.id) { person in
                        card(for: person)
                    }
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .overlay {
                if !directory.isLoaded {
                    ProgressView("Loading people…")
                } else if shownPeople.isEmpty {
                    Text(showingHidden ? "You haven't hidden anyone." : "No people found yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .task { await directory.loadIfNeeded(service: service) }
        .onReceive(NotificationCenter.default.publisher(for: .peopleChanged)) { _ in coverRevision += 1 }
        .alert("People", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func card(for person: Person) -> some View {
        NavigationLink {
            PhotoGridView(service: service, filter: .person(id: person.id, name: displayName(for: person)))
        } label: {
            VStack(spacing: 6) {
                CoverImageView(
                    cacheKey: "person-\(person.id)",
                    request: service.personThumbnailRequest(personId: person.id)
                )
                .id(coverRevision)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if person.isFavorite == true {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(Color.pink))
                            .accessibilityLabel("Favorite")
                    }
                }

                // Unnamed people read as an invitation rather than a label.
                Text(person.name.isEmpty ? "Add name" : person.name)
                    .font(.subheadline)
                    .foregroundStyle(person.name.isEmpty ? Color.accentColor : Color.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(person.name.isEmpty ? "Name…" : "Rename…") { editingPersonId = person.id }
            Button(person.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                Task { await change(person, isFavorite: person.isFavorite != true) }
            }
            Button("Set Birthday…") { birthdayPersonId = person.id }
            Divider()
            Button(person.isHidden ? "Show Person" : "Hide Person") {
                Task { await change(person, isHidden: !person.isHidden) }
            }
        }
        .popover(
            isPresented: Binding(
                get: { editingPersonId == person.id },
                set: { if !$0 { editingPersonId = nil } }
            ),
            arrowEdge: .bottom
        ) {
            PersonNameEditor(service: service, target: .person(person), onChanged: {}, onClose: { editingPersonId = nil })
        }
        .popover(
            isPresented: Binding(
                get: { birthdayPersonId == person.id },
                set: { if !$0 { birthdayPersonId = nil } }
            ),
            arrowEdge: .bottom
        ) {
            BirthdayEditor(service: service, person: person) { updated in
                directory.upsert(updated)
                birthdayPersonId = nil
            }
        }
    }

    private func toggleHidden() {
        showingHidden.toggle()
        guard showingHidden else { return }
        Task {
            do {
                hiddenPeople = try await service.fetchPeople(includeHidden: true).filter(\.isHidden)
            } catch {
                errorMessage = "Couldn't load hidden people: \(FriendlyError.message(for: error))"
            }
        }
    }

    private func change(_ person: Person, isFavorite: Bool? = nil, isHidden: Bool? = nil) async {
        do {
            let updated = try await service.updatePerson(id: person.id, isFavorite: isFavorite, isHidden: isHidden)
            if let isHidden {
                if isHidden {
                    directory.remove(id: person.id)
                } else {
                    hiddenPeople.removeAll { $0.id == person.id }
                    directory.upsert(updated)
                }
            } else {
                directory.upsert(updated)
            }
        } catch {
            errorMessage = "Couldn't update the person: \(FriendlyError.message(for: error))"
        }
    }

    private func displayName(for person: Person) -> String {
        person.name.isEmpty ? "Unnamed" : person.name
    }
}

/// Set or clear the date someone was born, shown in Immich as their age in each photo.
private struct BirthdayEditor: View {
    let service: ImmichService
    let person: Person
    let onSaved: (Person) -> Void

    @State private var date = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(person.name.isEmpty ? "Birthday" : "\(person.name)'s Birthday")
                .font(.headline)
            DatePicker("Born", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { onSaved(person) }
                Spacer()
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { if let existing = person.birthDate.flatMap(PersonBirthday.date(from:)) { date = existing } }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            onSaved(try await service.updatePerson(id: person.id, birthDate: date))
        } catch {
            errorMessage = FriendlyError.message(for: error)
        }
    }
}

import SwiftUI
import ImmichAPI

struct PeopleView: View {
    let service: ImmichService

    @EnvironmentObject private var directory: PeopleDirectory
    @State private var editingPersonId: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 16)]
    private let contentLeadingPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("People")
                .font(.title2.weight(.bold))
                .padding(.leading, contentLeadingPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(directory.people, id: \.id) { person in
                        NavigationLink {
                            PhotoGridView(service: service, filter: .person(id: person.id, name: displayName(for: person)))
                        } label: {
                            VStack(spacing: 6) {
                                CoverImageView(
                                    cacheKey: "person-\(person.id)",
                                    request: service.personThumbnailRequest(personId: person.id)
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(Circle())

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
                    }
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .overlay {
                if !directory.isLoaded {
                    ProgressView("Loading people…")
                } else if directory.people.isEmpty {
                    Text("No people found yet.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .task { await directory.loadIfNeeded(service: service) }
    }

    private func displayName(for person: Components.Schemas.PersonResponseDto) -> String {
        person.name.isEmpty ? "Unnamed" : person.name
    }
}

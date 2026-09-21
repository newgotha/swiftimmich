import ImmichAPI
import SwiftUI

/// Everything besides the typed words that narrows a search.
struct SearchFilters: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case any = "Any Type", photos = "Photos", videos = "Videos"
    }
    enum Range: String, Codable, CaseIterable {
        case any = "Any Time", week = "Past Week", month = "Past Month", year = "Past Year", custom = "Custom…"
    }

    var kind: Kind = .any
    var range: Range = .any
    var from = Date().addingTimeInterval(-30 * 86400)
    var to = Date()
    var personIds: [String] = []
    var country = ""
    var city = ""
    var make = ""
    /// Exactly this many stars; 0 means any.
    var rating = 0
    var favoritesOnly = false

    /// Whether anything is narrowing the search. Compared field by field: comparing with a
    /// fresh `SearchFilters()` never matched, since that carries the current time in its
    /// (unused) custom date range.
    var isActive: Bool {
        kind != .any || range != .any || !personIds.isEmpty || !country.isEmpty || !city.isEmpty
            || !make.isEmpty || rating != 0 || favoritesOnly
    }

    var takenAfter: Date? {
        switch range {
        case .any: return nil
        case .week: return Date().addingTimeInterval(-7 * 86400)
        case .month: return Date().addingTimeInterval(-30 * 86400)
        case .year: return Date().addingTimeInterval(-365 * 86400)
        case .custom: return Calendar.current.startOfDay(for: from)
        }
    }

    var takenBefore: Date? {
        range == .custom ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) : nil
    }
}

struct SavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: String
    var filters: SearchFilters
}

/// The filters currently applied on the Search page, and the searches you've saved.
@MainActor
final class SearchModel: ObservableObject {
    @Published var filters = SearchFilters()
    @Published private(set) var saved: [SavedSearch] = []

    private static let defaultsKey = "savedSearches"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            saved = decoded
        }
    }

    func save(name: String, query: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        saved.append(SavedSearch(name: trimmed, query: query, filters: filters))
        persist()
    }

    func remove(_ search: SavedSearch) {
        saved.removeAll { $0.id == search.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Service

extension ImmichService {
    struct SearchPage {
        let assets: [AssetSummary]
        let nextPage: Int?
    }

    /// With words: Immich's smart (meaning-based) search, narrowed by the filters. With only
    /// filters: a plain metadata search, newest first.
    func search(query: String, filters: SearchFilters, page: Int) async throws -> SearchPage {
        let type: Components.Schemas.AssetTypeEnum? = {
            switch filters.kind {
            case .any: return nil
            case .photos: return .IMAGE
            case .videos: return .VIDEO
            }
        }()
        let personIds = filters.personIds.isEmpty ? nil : filters.personIds
        let city = filters.city.isEmpty ? nil : filters.city
        let country = filters.country.isEmpty ? nil : filters.country
        let make = filters.make.isEmpty ? nil : filters.make
        let rating = filters.rating == 0 ? nil : filters.rating
        let favorite: Bool? = filters.favoritesOnly ? true : nil

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let result: Components.Schemas.SearchAssetResponseDto
        if trimmed.isEmpty {
            let response = try await client.searchAssets(body: .json(.init(
                city: city, country: country, isFavorite: favorite, make: make, page: page,
                personIds: personIds, rating: rating, size: 200,
                takenAfter: filters.takenAfter, takenBefore: filters.takenBefore, _type: type
            )))
            result = try response.ok.body.json.assets
        } else {
            let response = try await client.searchSmart(body: .json(.init(
                city: city, country: country, isFavorite: favorite, make: make, page: page,
                personIds: personIds, query: trimmed, rating: rating, size: 200,
                takenAfter: filters.takenAfter, takenBefore: filters.takenBefore, _type: type
            )))
            result = try response.ok.body.json.assets
        }
        var assets = AssetSummary.makeSummaries(from: result.items)
        if trimmed.isEmpty { assets.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
        return SearchPage(assets: assets, nextPage: result.nextPage.flatMap { Int($0) })
    }

    func fetchSuggestions(_ type: Components.Schemas.SearchSuggestionType, country: String? = nil) async throws -> [String] {
        let response = try await client.getSearchSuggestions(query: .init(country: country, _type: type))
        return try response.ok.body.json.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Filter bar

private struct FilterPill: View {
    let title: String
    var isActive = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.callout)
        .foregroundStyle(isActive ? Color.white : ToolbarPill.text)
        .padding(.horizontal, 10)
        .frame(maxWidth: 240)
        .frame(height: 26)
        .background(isActive ? Color.accentColor : ToolbarPill.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isActive ? Color.clear : ToolbarPill.border, lineWidth: 0.75))
    }
}

/// The row of filters above search results.
struct SearchFilterBar: View {
    let service: ImmichService
    let query: String
    @EnvironmentObject private var model: SearchModel
    @EnvironmentObject private var directory: PeopleDirectory

    @State private var showDatePopover = false
    @State private var showPlacePopover = false
    @State private var makes: [String] = []
    @State private var showSaveAlert = false
    @State private var saveName = ""

    private var filters: Binding<SearchFilters> { $model.filters }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SearchFilters.Kind.allCases, id: \.self) { kind in
                        Button(kind.rawValue) { model.filters.kind = kind }
                    }
                } label: {
                    FilterPill(title: model.filters.kind.rawValue, isActive: model.filters.kind != .any)
                }

                Menu {
                    ForEach(SearchFilters.Range.allCases, id: \.self) { range in
                        Button(range.rawValue) {
                            model.filters.range = range
                            if range == .custom { showDatePopover = true }
                        }
                    }
                } label: {
                    FilterPill(title: dateTitle, isActive: model.filters.range != .any)
                }
                .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        DatePicker("From", selection: filters.from, displayedComponents: .date)
                        DatePicker("To", selection: filters.to, displayedComponents: .date)
                        Button("Done") { showDatePopover = false }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(14)
                    .frame(width: 240)
                }

                Menu {
                    if directory.namedPeople.isEmpty {
                        Text("No named people yet")
                    }
                    ForEach(directory.namedPeople, id: \.id) { person in
                        Toggle(person.name, isOn: Binding(
                            get: { model.filters.personIds.contains(person.id) },
                            set: { on in
                                if on { model.filters.personIds.append(person.id) }
                                else { model.filters.personIds.removeAll { $0 == person.id } }
                            }
                        ))
                    }
                } label: {
                    FilterPill(title: peopleTitle, isActive: !model.filters.personIds.isEmpty)
                }

                Button { showPlacePopover = true } label: {
                    FilterPill(title: placeTitle, isActive: !model.filters.country.isEmpty || !model.filters.city.isEmpty)
                }
                .buttonStyle(HoverPlainStyle())
                .popover(isPresented: $showPlacePopover, arrowEdge: .bottom) {
                    PlaceFilterPopover(service: service, filters: filters) { showPlacePopover = false }
                }

                Menu {
                    Button("Any Camera") { model.filters.make = "" }
                    Divider()
                    ForEach(makes, id: \.self) { make in
                        Button(make) { model.filters.make = make }
                    }
                } label: {
                    FilterPill(title: model.filters.make.isEmpty ? "Any Camera" : model.filters.make, isActive: !model.filters.make.isEmpty)
                }

                Menu {
                    Button("Any Rating") { model.filters.rating = 0 }
                    Divider()
                    ForEach((1...5).reversed(), id: \.self) { stars in
                        Button(String(repeating: "★", count: stars)) { model.filters.rating = stars }
                    }
                } label: {
                    FilterPill(
                        title: model.filters.rating == 0 ? "Any Rating" : String(repeating: "★", count: model.filters.rating),
                        isActive: model.filters.rating != 0
                    )
                }

                Button { model.filters.favoritesOnly.toggle() } label: {
                    FilterPill(title: "Favorites", isActive: model.filters.favoritesOnly)
                }
                .buttonStyle(HoverPlainStyle())

                if model.filters.isActive {
                    Button("Clear") { model.filters = SearchFilters() }
                        .buttonStyle(HoverPlainStyle())
                        .foregroundStyle(Color.accentColor)
                }
                if model.filters.isActive || !query.isEmpty {
                    Button("Save Search…") { saveName = query; showSaveAlert = true }
                        .buttonStyle(HoverPlainStyle())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .task {
            await directory.loadIfNeeded(service: service)
            if makes.isEmpty { makes = (try? await service.fetchSuggestions(.camera_hyphen_make)) ?? [] }
        }
        .alert("Save Search", isPresented: $showSaveAlert) {
            TextField("Name", text: $saveName)
            Button("Save") { model.save(name: saveName, query: query) }
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved searches appear in the sidebar.")
        }
    }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    private var dateTitle: String {
        guard model.filters.range == .custom else { return model.filters.range.rawValue }
        return "\(Self.dateFormat.string(from: model.filters.from)) – \(Self.dateFormat.string(from: model.filters.to))"
    }

    private var peopleTitle: String {
        let ids = model.filters.personIds
        if ids.isEmpty { return "Anyone" }
        let names = ids.compactMap { id in directory.people.first { $0.id == id }?.name }
        return names.count == 1 ? names[0] : "\(names.count) People"
    }

    private var placeTitle: String {
        let parts = [model.filters.city, model.filters.country].filter { !$0.isEmpty }
        return parts.isEmpty ? "Anywhere" : parts.joined(separator: ", ")
    }
}

/// Pick a country and/or city from the ones your photos were taken in.
private struct PlaceFilterPopover: View {
    let service: ImmichService
    @Binding var filters: SearchFilters
    var onClose: () -> Void

    @State private var countries: [String] = []
    @State private var cities: [String] = []
    @State private var text = ""

    private var shown: [(label: String, isCountry: Bool)] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        let matchedCountries = countries.filter { needle.isEmpty || $0.localizedCaseInsensitiveContains(needle) }.map { ($0, true) }
        let matchedCities = cities.filter { !needle.isEmpty && $0.localizedCaseInsensitiveContains(needle) }.map { ($0, false) }
        return Array((matchedCountries + matchedCities).prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search countries and cities", text: $text)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Anywhere") { filters.country = ""; filters.city = ""; onClose() }
                        .buttonStyle(HoverPlainStyle())
                        .padding(.vertical, 3)
                    ForEach(shown, id: \.label) { entry in
                        Button {
                            if entry.isCountry { filters.country = entry.label; filters.city = "" }
                            else { filters.city = entry.label }
                            onClose()
                        } label: {
                            Label(entry.label, systemImage: entry.isCountry ? "globe" : "building.2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverPlainStyle())
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(14)
        .frame(width: 260)
        .task {
            countries = (try? await service.fetchSuggestions(.country)) ?? []
            cities = (try? await service.fetchSuggestions(.city)) ?? []
        }
    }
}

/// Saved searches in the sidebar.
struct SavedSearchesSidebarGroup: View {
    @ObservedObject var model: SearchModel
    var apply: (SavedSearch) -> Void
    @State private var expanded = true

    var body: some View {
        if !model.saved.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(model.saved) { search in
                    Button { apply(search) } label: {
                        Label(search.name, systemImage: "magnifyingglass")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(HoverPlainStyle())
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Delete Saved Search", role: .destructive) { model.remove(search) }
                    }
                }
            } label: {
                Label("Saved Searches", systemImage: "magnifyingglass.circle")
                    .padding(.vertical, 4)
            }
        }
    }
}

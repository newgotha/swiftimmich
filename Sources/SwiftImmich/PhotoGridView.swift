import ImmichAPI
import SwiftUI

enum TimelineGrouping: String, CaseIterable, Identifiable {
    case all = "All Photos"
    case months = "Months"
    case years = "Years"
    var id: String { rawValue }
}

struct PhotoGridView: View {
    @StateObject private var model: PhotoLibraryModel
    @State private var grouping: TimelineGrouping = .months
    @State private var isNamingPerson = false
    @ObservedObject private var zoom = GridZoomStore.shared
    @EnvironmentObject private var directory: PeopleDirectory
    @EnvironmentObject private var selection: GridSelection
    @Environment(\.dismiss) private var dismiss
    private let service: ImmichService

    init(service: ImmichService, filter: TimelineFilter = .none) {
        self.service = service
        _model = StateObject(wrappedValue: PhotoLibraryModel(service: service, filter: filter))
    }

    private let placeholderColumns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)]
    /// Shared with the grid's own leading padding below so the title and the photos
    /// underneath it share exactly one left edge — macOS's automatic `.navigationTitle`
    /// position is controlled by AppKit and can't be made to line up with arbitrary
    /// custom content padding, so the title is rendered as ordinary content instead.
    private let contentLeadingPadding: CGFloat = 20

    private var albumContext: PhotoViewerView.AlbumContext? {
        if case let .album(id, name) = model.filter {
            return PhotoViewerView.AlbumContext(id: id, name: name)
        }
        return nil
    }

    /// A person's page gets a button to name (or rename) them, showing the live name so
    /// it updates the moment it's saved.
    @ViewBuilder
    private var titleRow: some View {
        if case let .person(id, _) = model.filter {
            let person = directory.people.first { $0.id == id }
            HStack(spacing: 10) {
                Text(person.map { $0.name.isEmpty ? "Unnamed" : $0.name } ?? model.filter.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                if let person {
                    Button(person.name.isEmpty ? "Add name" : "Rename") { isNamingPerson = true }
                        .buttonStyle(ToolbarPillStyle())
                        .font(.callout)
                        .popover(isPresented: $isNamingPerson, arrowEdge: .bottom) {
                            PersonNameEditor(
                                service: service,
                                target: .person(person),
                                onChanged: {
                                    // Merging into someone else removes this person, so there's
                                    // nothing left to show here.
                                    if !directory.people.contains(where: { $0.id == id }) { dismiss() }
                                },
                                onClose: { isNamingPerson = false }
                            )
                        }
                }
            }
        } else if case let .album(id, name) = model.filter {
            let album = selection.albums.first { $0.id == id }
            HStack(spacing: 10) {
                Text(album?.albumName ?? name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                if let album, album.shared {
                    if album.isActivityEnabled {
                        AlbumActivityButton(service: service, album: album)
                    }
                    SharedAlbumBadge(album: album, currentUserId: service.sharing.currentUserId, size: .title3)
                }
            }
        } else if case .trash = model.filter {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(model.filter.title)
                        .font(.title2.weight(.bold))
                    Button("Empty Trash") { selection.pendingEmptyTrash = true }
                        .buttonStyle(ToolbarPillStyle())
                        .font(.callout)
                        .disabled(model.buckets.isEmpty)
                }
                Text("Deleted items can be restored until you empty the trash or the server clears it out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(model.filter.title)
                .font(.title2.weight(.bold))
                .lineLimit(1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                titleRow
                Spacer(minLength: 16)
                zoomControl
            }
            .padding(.leading, contentLeadingPadding)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if model.isShowingSavedCopy {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text("Can't reach your server — showing the last saved copy.")
                    Button("Try Again") {
                        Task {
                            model.clear()
                            await model.loadBuckets()
                            if grouping != .months { await model.loadAllAssets() }
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, contentLeadingPadding)
                .padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
            ScrollView {
                switch grouping {
                case .months:
                    monthSections
                case .years:
                    yearSections
                case .all:
                    allPhotosSection
                }
            }
            .overlay(alignment: .trailing) {
                if showsScrubber {
                    TimelineScrubber(model: scrubberModel, title: scrubberTitle) { key in
                        proxy.scrollTo(grouping == .years ? String(key.prefix(4)) : key, anchor: .top)
                    }
                    .padding(.vertical, 40)
                }
            }
            .onChange(of: selection.focusedId) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .overlay {
                if model.isLoadingBuckets {
                    ProgressView("Loading timeline…")
                } else if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if model.buckets.isEmpty {
                    Text("No photos found.")
                        .foregroundStyle(.secondary)
                }
            }
            .task { await model.loadBuckets() }
            .task(id: grouping) {
                guard grouping != .months else { return }
                await model.loadAllAssets()
            }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                GroupingControl(selection: $grouping)
            }
            SelectToolbarContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetsRemoved)) { note in
            for id in note.object as? [String] ?? [] { model.removeAsset(id: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetsFavoriteChanged)) { note in
            if let change = note.object as? FavoriteChange { model.applyFavorite(change) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gridNeedsReload)) { _ in
            Task {
                model.clear()
                await model.loadBuckets()
                if grouping != .months { await model.loadAllAssets() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trashEmptied)) { _ in
            if model.filter.isTrashed { model.clear() }
        }
    }

    private var monthSections: some View {
        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
            ForEach(model.buckets, id: \.timeBucket) { bucket in
                Section {
                    bucketContent(for: bucket)
                } header: {
                    sectionHeader(monthTitle(for: bucket.timeBucket))
                        .id(bucket.timeBucket)
                }
            }
        }
        .padding(.leading, contentLeadingPadding)
        .padding(.trailing, trailingPadding)
    }

    private var yearSections: some View {
        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
            ForEach(yearGroups, id: \.year) { group in
                Section {
                    let assets = group.buckets.flatMap { model.assetsByBucket[$0.timeBucket] ?? [] }
                    JustifiedAssetGridView(assets: assets, service: model.service, order: yearIndex(of: group.year), onDelete: model.removeAsset, albumContext: albumContext, filter: model.filter)
                } header: {
                    sectionHeader(group.year)
                        .id(group.year)
                }
            }
        }
        .padding(.leading, contentLeadingPadding)
        .padding(.trailing, trailingPadding)
    }

    private var allPhotosSection: some View {
        JustifiedAssetGridView(assets: model.allLoadedAssets, service: model.service, onDelete: model.removeAsset, albumContext: albumContext, filter: model.filter)
            .padding(.leading, contentLeadingPadding)
            .padding(.trailing, 16)
    }

    @ViewBuilder
    private func bucketContent(for bucket: Components.Schemas.TimeBucketsResponseDto) -> some View {
        if let assets = model.assetsByBucket[bucket.timeBucket] {
            JustifiedAssetGridView(assets: assets, service: model.service, order: model.buckets.firstIndex(where: { $0.timeBucket == bucket.timeBucket }) ?? 0, onDelete: model.removeAsset, albumContext: albumContext, filter: model.filter)
        } else {
            LazyVGrid(columns: placeholderColumns, spacing: 10) {
                ForEach(0..<min(Int(bucket.count), 12), id: \.self) { _ in
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .task { await model.loadAssets(for: bucket.timeBucket) }
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: 9)).accessibilityHidden(true)
            Slider(value: $zoom.value, in: GridZoom.range)
                .frame(width: 110)
                .accessibilityLabel("Thumbnail size")
            Image(systemName: "photo").font(.system(size: 14)).accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .help("Thumbnail size (⌘+ and ⌘−)")
    }

    /// The date strip needs month or year sections to jump between, and more than one of them.
    private var showsScrubber: Bool { grouping != .all && model.buckets.count > 1 }
    private var trailingPadding: CGFloat { showsScrubber ? 46 : 16 }

    private var scrubberModel: ScrubberModel {
        ScrubberModel(buckets: model.buckets.map { (key: $0.timeBucket, count: Int($0.count)) })
    }

    private func scrubberTitle(_ key: String) -> String {
        grouping == .years ? String(key.prefix(4)) : monthTitle(for: key)
    }

    private func sectionHeader(_ title: String) -> some View {
        SectionHeader(title: title)
    }

    private func yearIndex(of year: String) -> Int {
        yearGroups.firstIndex(where: { $0.year == year }) ?? 0
    }

    private var yearGroups: [(year: String, buckets: [Components.Schemas.TimeBucketsResponseDto])] {
        var order: [String] = []
        var byYear: [String: [Components.Schemas.TimeBucketsResponseDto]] = [:]
        for bucket in model.buckets {
            let year = String(bucket.timeBucket.prefix(4))
            if byYear[year] == nil {
                order.append(year)
                byYear[year] = []
            }
            byYear[year]?.append(bucket)
        }
        return order.map { (year: $0, buckets: byYear[$0] ?? []) }
    }

    private static let bucketParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let monthDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private func monthTitle(for timeBucket: String) -> String {
        guard let date = Self.bucketParser.date(from: timeBucket) else { return timeBucket }
        return Self.monthDisplay.string(from: date)
    }
}

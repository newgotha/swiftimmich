import ImmichAPI
import SwiftUI

extension Notification.Name {
    /// Asks the window to show the Import from Photos page (from the menu bar item).
    static let showImportPage = Notification.Name("dev.local.swiftimmich.showImportPage")
    /// Posted (object: `[String]` of asset ids) after their date, location or description
    /// was edited, so anything showing them can re-read the details.
    static let assetMetadataChanged = Notification.Name("dev.local.swiftimmich.assetMetadataChanged")
}

/// A sheet for changing the date, location and/or description of one photo or several
/// at once. Each part has its own switch, so only what's switched on is touched — with
/// several photos selected, leaving description off keeps each photo's own.
struct MetadataEditor: View {
    enum DateMode: String, CaseIterable, Identifiable {
        case set = "Set to"
        case shift = "Shift by"
        var id: String { rawValue }
    }

    let service: ImmichService
    let assets: [AssetSummary]
    var onClose: () -> Void

    @State private var changeDescription = false
    @State private var descriptionText = ""

    @State private var changeDate = false
    @State private var dateMode: DateMode = .set
    @State private var date = Date()
    @State private var zone: TimeZone = .current
    @State private var shiftLater = true
    @State private var shiftDays = 0
    @State private var shiftHours = 0
    @State private var shiftMinutes = 0

    @State private var changeLocation = false
    @State private var placeQuery = ""
    @State private var places: [Components.Schemas.PlacesResponseDto] = []
    @State private var chosenPlace: Components.Schemas.PlacesResponseDto?
    /// Where the pin is: from a searched place, a click on the map, or a drag.
    @State private var pin: PinLocation?
    /// Where the photo is now, so the map opens there.
    @State private var existingPin: PinLocation?
    @State private var isSearching = false
    @State private var currentLocation: String?

    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isSingle: Bool { assets.count == 1 }
    private var hasChanges: Bool {
        (changeDescription) || (changeDate && (dateMode == .set || shiftMinutesTotal != 0)) || (changeLocation && pin != nil)
    }
    private var shiftMinutesTotal: Int {
        let total = (shiftDays * 24 + shiftHours) * 60 + shiftMinutes
        return shiftLater ? total : -total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isSingle ? "Edit Details" : "Edit Details for \(assets.count) Items")
                .font(.headline)

            descriptionSection
            Divider()
            dateSection
            Divider()
            locationSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || isSaving)
            }
        }
        .padding(20)
        .frame(width: 430)
        .disabled(isSaving)
        .task { await prefill() }
    }

    // MARK: - Sections

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isSingle ? "Description" : "Set description for all", isOn: $changeDescription)
                .toggleStyle(.checkbox)
            // Editing the field switches its section on (a plain onChange would also fire
            // for the prefill, making it look edited before the user touched anything).
            TextField(
                isSingle ? "Add a description" : "Replaces each photo's description",
                text: Binding(get: { descriptionText }, set: { descriptionText = $0; changeDescription = true }),
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Date and time", isOn: $changeDate)
                .toggleStyle(.checkbox)

            if !isSingle {
                Picker("", selection: $dateMode) {
                    ForEach(DateMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: dateMode) { _, _ in changeDate = true }
            }

            if dateMode == .set || isSingle {
                DatePicker(
                    "",
                    selection: Binding(get: { date }, set: { date = $0; changeDate = true }),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .environment(\.timeZone, zone)
                Text(isSingle ? "In the photo's own time zone (\(zone.identifier))." : "Every selected photo gets this exact time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Picker("", selection: $shiftLater) {
                        Text("Later").tag(true)
                        Text("Earlier").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    stepper("d", value: Binding(get: { shiftDays }, set: { shiftDays = $0; changeDate = true }), range: 0...3650)
                    stepper("h", value: Binding(get: { shiftHours }, set: { shiftHours = $0; changeDate = true }), range: 0...23)
                    stepper("m", value: Binding(get: { shiftMinutes }, set: { shiftMinutes = $0; changeDate = true }), range: 0...59)
                }
                Text("Moves each photo by this amount, keeping their order — handy when a camera's clock was off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepper(_ unit: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Location", isOn: $changeLocation)
                .toggleStyle(.checkbox)
            if let currentLocation, isSingle {
                Text("Currently: \(currentLocation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search for a place", text: $placeQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await searchPlaces() } }
                Button("Search") { Task { await searchPlaces() } }
                    .disabled(placeQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                if isSearching { ProgressView().controlSize(.small) }
            }
            if let pin {
                Label(pinLabel(for: pin), systemImage: "mappin.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
            LocationPickerMap(pin: Binding(
                get: { pin ?? existingPin },
                set: { newPin in
                    pin = newPin
                    if let chosenPlace, newPin != PinLocation(latitude: chosenPlace.latitude, longitude: chosenPlace.longitude) { self.chosenPlace = nil }
                    changeLocation = true
                }
            ))
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            Text("Click the map to place the pin, or drag it to where the photo was taken.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !places.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(places.indices, id: \.self) { index in
                        let place = places[index]
                        Button {
                            chosenPlace = place
                            pin = PinLocation(latitude: place.latitude, longitude: place.longitude)
                            changeLocation = true
                            places = []
                        } label: {
                            Text(Self.title(for: place))
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func pinLabel(for pin: PinLocation) -> String {
        if let chosenPlace { return Self.title(for: chosenPlace) }
        return "Pin at \(pin.text)"
    }

    private static func title(for place: Components.Schemas.PlacesResponseDto) -> String {
        [place.name, place.admin2name, place.admin1name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Loading and saving

    /// Fills the fields from the first photo, so they open showing something sensible.
    private func prefill() async {
        guard let first = assets.first, let info = try? await service.fetchAssetInfo(assetId: first.id) else { return }
        let exif = info.exifInfo
        zone = Self.timeZone(from: exif?.timeZone) ?? .current

        // `localDateTime` is the wall-clock time stored as if it were UTC; rebuild that same
        // wall-clock time in the photo's zone so the picker shows what the info pane shows.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: info.localDateTime)
        date = local.date(from: parts) ?? info.fileCreatedAt

        if isSingle {
            descriptionText = exif?.description ?? ""
            let place = [exif?.city, exif?.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            currentLocation = place.isEmpty ? (exif?.latitude == nil ? "no location" : "coordinates only") : place
            if let latitude = exif?.latitude, let longitude = exif?.longitude {
                existingPin = PinLocation(latitude: latitude, longitude: longitude)
            }
        }
    }

    /// An IANA name ("Australia/Sydney") or the "UTC+10:00" style Immich sometimes stores.
    static func timeZone(from string: String?) -> TimeZone? {
        guard let string, !string.isEmpty else { return nil }
        if let zone = TimeZone(identifier: string) { return zone }
        let pattern = #"^UTC([+-])(\d{1,2})(?::?(\d{2}))?$"#
        guard let match = string.range(of: pattern, options: .regularExpression) else { return nil }
        let text = String(string[match])
        let sign = text.contains("-") ? -1 : 1
        let digits = text.dropFirst(4).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let hours = digits.first else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + (digits.count > 1 ? digits[1] * 60 : 0)))
    }

    private func searchPlaces() async {
        let query = placeQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            places = Array(try await service.searchPlaces(name: query).prefix(6))
            errorMessage = places.isEmpty ? "No places found for “\(query)”." : nil
        } catch {
            errorMessage = "Couldn't search places: \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var dateString: String?
        var relativeMinutes: Int?
        if changeDate {
            if dateMode == .set || isSingle {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                formatter.timeZone = zone
                dateString = formatter.string(from: date)
            } else {
                relativeMinutes = shiftMinutesTotal
            }
        }
        let ids = assets.map(\.id)
        do {
            try await service.updateMetadata(
                assetIds: ids,
                description: changeDescription ? descriptionText : nil,
                dateTimeOriginal: dateString,
                dateTimeRelative: relativeMinutes,
                timeZone: dateString != nil && TimeZone(identifier: zone.identifier) != nil ? zone.identifier : nil,
                latitude: changeLocation ? pin?.latitude : nil,
                longitude: changeLocation ? pin?.longitude : nil
            )
            NotificationCenter.default.post(name: .assetMetadataChanged, object: ids)
            if changeDate { NotificationCenter.default.post(name: .gridNeedsReload, object: nil) }
            onClose()
        } catch {
            if case ImmichServiceError.requestFailed(let status, let message) = error {
                errorMessage = "The server said \(status)" + (message.map { ": \($0.prefix(160))" } ?? "")
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Presents the details editor when the selection hub asks for it. A separate modifier
/// because ContentView's body is already at the compiler's type-checking limit.
struct DetailsEditorSheet: ViewModifier {
    let service: ImmichService?
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { selection.pendingEditDetails != nil },
            set: { if !$0 { selection.pendingEditDetails = nil } }
        )) {
            if let service, let assets = selection.pendingEditDetails {
                MetadataEditor(service: service, assets: assets) { selection.pendingEditDetails = nil }
            }
        }
    }
}

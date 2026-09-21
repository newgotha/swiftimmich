import Photos
import SwiftUI

struct PhotosImportView: View {
    @AppStorage(AutoImport.enabledKey) private var autoImport = false
    private enum Scope: Hashable {
        case testRun, everything
    }

    private static let testRunSize = 10

    let service: ImmichService
    @ObservedObject var importer: PhotosImporter

    @State private var scope: Scope = .testRun

    var body: some View {
        CardPage(maxWidth: 660) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from Photos")
                    .font(.title2.weight(.semibold))
                Text("Copies your Mac's Photos library — including photos and videos that only exist in iCloud — to your Immich server.")
                    .foregroundStyle(.secondary)
            }

            switch importer.authorization {
            case .notDetermined:
                accessRequest
            case .denied, .restricted:
                accessDenied
            default:
                importControls
            }
        }
        .task {
            importer.configure(serverIdentity: service.apiURL.absoluteString)
            await importer.refreshCounts()
        }
    }

    // MARK: - Permission states

    private var accessRequest: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS needs your permission before this app can read your Photos library. Nothing is changed or deleted in Photos — it's only read.")
            Button("Allow Access to Photos") {
                Task { await importer.requestAccess() }
            }
            .buttonStyle(HoverProminentStyle())
        }
    }

    private var accessDenied: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Access to Photos is turned off for this app.", systemImage: "lock.fill")
            Text("Turn it on in System Settings → Privacy & Security → Photos, then come back here.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check Again") {
                    Task { await importer.refreshCounts() }
                }
            }
        }
    }

    // MARK: - Import controls

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            libraryCard

            if importer.authorization == .limited {
                Label("You've given this app access to only some of your photos, so only those can be imported.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if importer.isRunning {
                progressSection
            } else {
                startSection
            }

            if importer.phase == .finished || importer.phase == .stopped {
                summarySection
            }

            if !importer.failures.isEmpty {
                failuresSection
            }
        }
    }

    private var libraryCard: some View {
        HStack(spacing: 24) {
            statBlock("In Photos", importer.librarySize)
            statBlock("Already imported", importer.alreadyImported)
            statBlock("Still to import", importer.pendingCount)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statBlock(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $scope) {
                Text("Test run — the \(Self.testRunSize) newest").tag(Scope.testRun)
                Text("Everything not yet imported").tag(Scope.everything)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Button(importer.phase == .stopped ? "Resume Import" : "Start Import") {
                    importer.start(service: service, limit: scope == .testRun ? Self.testRunSize : nil)
                }
                .buttonStyle(HoverProminentStyle())
                .disabled(importer.pendingCount == 0)

                if importer.pendingCount == 0 && importer.librarySize > 0 {
                    Label("Everything in Photos is already on your server.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }

            Divider()
            DirectUploadField(compact: true)
            Divider()

            Toggle(isOn: $autoImport) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import new photos automatically")
                    Text("While this app is open, photos you take from now on are copied to your server shortly after they appear in Photos. Everything already in your library still needs the import above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if importer.previouslyFailedCount > 0 {
                Label("\(importer.previouslyFailedCount) failed on an earlier run. They'll be tried last, so they can't hold up the rest.", systemImage: "arrow.uturn.down")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Items already on your server are recognised and skipped, so it's safe to run this more than once. Originals stored only in iCloud are downloaded one at a time, uploaded, then removed from temporary storage. Your Mac stays awake while it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(importer.processed), total: Double(max(importer.totalToProcess, 1)))

            HStack {
                Text(importer.phase == .scanning
                     ? "Reading your Photos library…"
                     : "Item \(min(importer.processed + 1, importer.totalToProcess)) of \(importer.totalToProcess)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Spacer()
                Button("Stop") { importer.stop() }
            }

            if let name = importer.currentName {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let detail = importer.currentDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            counters
        }
    }

    private var counters: some View {
        HStack(spacing: 16) {
            counter("Uploaded", importer.uploaded, .green)
            counter("Already on server", importer.alreadyOnServer, .secondary)
            counter("Skipped", importer.skipped, .secondary)
            counter("Failed", importer.failures.count, importer.failures.isEmpty ? .secondary : .red)
        }
        .font(.caption)
    }

    private func counter(_ title: String, _ value: Int, _ color: Color) -> some View {
        Text("\(title): \(value.formatted())")
            .foregroundStyle(color)
            .monospacedDigit()
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = importer.stopReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if importer.phase == .stopped {
                Label("Stopped. Progress is saved — Resume Import picks up where this left off.", systemImage: "pause.circle")
            } else {
                Label("Import finished.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            counters
        }
    }

    private var failuresSection: some View {
        DisclosureGroup("\(importer.failures.count) couldn't be imported") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(importer.failures) { failure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.name).font(.callout)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text("Failed items aren't marked as imported, so they'll be tried again next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }
}

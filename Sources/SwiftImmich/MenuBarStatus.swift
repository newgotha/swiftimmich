import AppKit
import SwiftUI

/// The small menu bar item: import progress at a glance, with pause and resume.
struct MenuBarStatus: View {
    @ObservedObject var importer: PhotosImporter
    @AppStorage(AutoImport.enabledKey) private var autoImport = false
    @AppStorage(AutoImport.pausedKey) private var paused = false

    private var headline: String {
        switch importer.phase {
        case .scanning: return "Reading your Photos library…"
        case .importing: return "Importing \(min(importer.processed + 1, max(importer.totalToProcess, 1))) of \(importer.totalToProcess)"
        case .finished: return importer.uploaded > 0 ? "Imported \(importer.uploaded) \(importer.uploaded == 1 ? "item" : "items")" : "Photos import is up to date"
        case .stopped: return "Import stopped"
        case .idle:
            if !autoImport { return "Automatic import is off" }
            return paused ? "Automatic import is paused" : "Watching Photos for new items"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photos import").font(.headline)

            if importer.isRunning {
                ProgressView(value: Double(importer.processed), total: Double(max(importer.totalToProcess, 1)))
            }
            Text(headline).font(.callout)
            if importer.isRunning, let name = importer.currentName {
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !importer.failures.isEmpty {
                Label("\(importer.failures.count) failed", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            if importer.isRunning {
                Button("Stop Import") { importer.stop() }
            }
            if autoImport {
                Button(paused ? "Resume Automatic Import" : "Pause Automatic Import") { paused.toggle() }
            } else {
                Text("Turn on automatic import on the Import from Photos page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Open Import from Photos") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showImportPage, object: nil)
            }
            Divider()
            Button("Quit SwiftImmich") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
    }
}

/// The menu bar icon: still when idle, turning with a running count while importing.
struct MenuBarIcon: View {
    @ObservedObject var importer: PhotosImporter
    @AppStorage(AutoImport.pausedKey) private var paused = false

    var body: some View {
        if importer.isRunning {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                if importer.totalToProcess > 0 { Text("\(importer.processed)/\(importer.totalToProcess)") }
            }
        } else {
            Image(systemName: paused ? "pause.circle" : "photo.on.rectangle.angled")
        }
    }
}

import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    @AppStorage(DiskImageCache.limitKey) private var cacheLimitMB = 1024
    @AppStorage(AutoImport.enabledKey) private var autoImport = false
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(UpdateChecker.autoCheckKey) private var autoCheckUpdates = true
    @State private var usedBytes = 0
    @State private var isClearing = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Look", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in
                    (AppearanceMode(rawValue: value) ?? .system).apply()
                }
            }

            Section("Saved photos") {
                Text("Thumbnails and previews you've viewed are kept on this Mac so browsing is quick and still works without a connection. Full-size originals aren't saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Keep up to", selection: $cacheLimitMB) {
                    Text("500 MB").tag(512)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("10 GB").tag(10240)
                }
                .onChange(of: cacheLimitMB) { _, _ in
                    Task.detached { DiskImageCache.prune() }
                    refreshUsage()
                }
                HStack {
                    Text("Using \(ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Saved Photos") {
                        isClearing = true
                        Task {
                            await ThumbnailLoader.shared.clearAll()
                            isClearing = false
                            refreshUsage()
                        }
                    }
                    .disabled(isClearing)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoCheckUpdates)
                HStack {
                    Text("SwiftImmich \(AppInfo.version)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Task { await UpdateChecker.shared.checkNow() } }
                }
                Text("New versions are published on GitHub. Updating means downloading the new version and replacing the app in Applications; your settings and server connection are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show import status in the menu bar", isOn: $showMenuBarItem)
            }

            Section("Sidebar") {
                Text("Drag rows and groups in the sidebar to rearrange them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Reset Sidebar Order") { UserDefaults.standard.removeObject(forKey: SidebarView.orderKey) }
            }

            Section("Large files") {
                DirectUploadField()
            }

            Section("Photos library") {
                Toggle("Import new photos automatically", isOn: $autoImport)
                Text("While the app is open, photos taken from the moment this is switched on are copied to your server. Set up Photos access on the Import from Photos page first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshUsage)
    }

    private func refreshUsage() {
        Task.detached {
            let bytes = DiskImageCache.totalBytes()
            await MainActor.run { usedBytes = bytes }
        }
    }
}

/// The optional direct address for files too big for the Cloudflare-proxied one, shared by
/// Settings and the Import from Photos page.
struct DirectUploadField: View {
    var compact = false

    @AppStorage(ImmichService.directUploadKey) private var directURL = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                Text("Large photos and videos")
                    .font(.headline)
            }
            TextField("Local server address", text: $directURL, prompt: Text("http://192.168.1.20:2283"))
                .textFieldStyle(.roundedBorder)
            Text("Cloudflare rejects any single upload over about 100 MB, so big RAW photos and videos fail. Enter your Immich server's address on your home network (or any address that doesn't go through Cloudflare) and files over 95 MB will be sent there instead. Everything else still goes the normal way.")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
            Label("This only works while this Mac is on the same network as your Immich server. Away from home, large files will fail until you're back.", systemImage: "wifi")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Test Connection") { Task { await test() } }
                    .disabled(ImmichService.directUploadBase == nil || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: directURL) { _, _ in testResult = nil }
    }

    private func test() async {
        guard let base = ImmichService.directUploadBase else { return }
        isTesting = true
        defer { isTesting = false }
        var request = URLRequest(url: base.appendingPathComponent("server/ping"))
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data, as: UTF8.self).contains("pong")
            testResult = ok ? "Connected — that's an Immich server." : "Something answered, but it doesn't look like Immich."
        } catch {
            testResult = "Couldn't reach it: \(error.localizedDescription) (Are you on the same network as the server?)"
        }
    }
}

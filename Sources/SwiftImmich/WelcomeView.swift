import SwiftUI

/// Shown until the app is connected for the first time: what's needed, where to find it,
/// and a Connect button that really tests the address and key before continuing.
struct WelcomeView: View {
    @Binding var serverURL: String
    @Binding var apiKey: String
    let errorMessage: String?
    let isBusy: Bool
    let onConnect: () -> Void

    var body: some View {
        CardPage(maxWidth: 520) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to SwiftImmich")
                    .font(.title.weight(.semibold))
                Text("Connect to your Immich server to browse, organise and back up your photos from your Mac.")
                    .foregroundStyle(.secondary)
            }

            step(1, "Your server address",
                 "The web address you use to open Immich in a browser, for example https://photos.example.com. On your home network a local address such as http://192.168.1.20:2283 works too.") {
                TextField("https://photos.example.com", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if ServerAddress.isInsecureRemote(serverURL) {
                    Label("http:// sends your API key across the internet unencrypted. Use https:// if your server supports it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            step(2, "An API key",
                 "In Immich's web page choose your picture, then Account Settings, then API Keys, then New API Key. The simplest choice is to allow All permissions. The key is stored encrypted on this Mac and never leaves it except to talk to your server.") {
                SecureField("Paste your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connectIfReady)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Test and Connect", action: connectIfReady)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }

            Text("The Locked Folder asks for your Immich email and password once, because Immich only opens it for a signed-in session, not an API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    private func connectIfReady() { if canConnect { onConnect() } }

    private func step<Content: View>(_ number: Int, _ title: String, _ detail: String, @ViewBuilder field: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                field()
            }
        }
    }
}

import AppKit
import ImmichAPI
import LocalAuthentication
import SwiftUI

/// Who may open the Locked Folder, and whether it's open right now.
///
/// Immich shows locked photos only to a signed-in *session* that has been unlocked with
/// the account PIN — an API key can't be elevated — so this may ask you to sign in once
/// with your email and password. The password is used for that one request and never kept;
/// only the session it returns is saved (encrypted, like the API key).
///
/// While it's open every request uses that session; locking drops back to the API key,
/// forgets anything fetched with the session, and asks the server to lock it too.
@MainActor
final class LockedFolderSession: ObservableObject {
    enum Phase: Equatable {
        case gate               // waiting for Touch ID / the Mac password
        case checking
        case needsPINSetup
        case needsPIN
        case needsSignIn(String)  // why
        case unlocked
    }

    @Published private(set) var phase: Phase = .gate
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var suggestedEmail = ""

    private var service: ImmichService?
    private var autoLock: Task<Void, Never>?
    private var deactivationLock: Task<Void, Never>?
    /// What to do once the user has signed in.
    private var afterSignIn: (() async -> Void)?

    var isUnlocked: Bool { phase == .unlocked }

    /// How long it stays open before locking itself (the server's own limit is 15 minutes).
    private static let openFor: Duration = .seconds(14 * 60)

    // MARK: - Opening

    func begin(service: ImmichService) {
        self.service = service
        if phase == .unlocked { return }
        phase = .gate
        errorMessage = nil
    }

    /// The local check that it's really you at the Mac, before the PIN is even asked for.
    func authenticateLocally() async {
        let context = LAContext()
        var error: NSError?
        // With no way to authenticate locally at all, fall through to the PIN.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            await checkStatus()
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open your Locked Folder")
            if ok { await checkStatus() }
        } catch {
            errorMessage = nil   // cancelled: stay on the gate
        }
    }

    private func checkStatus() async {
        guard let service else { return }
        phase = .checking
        restoreSavedSession(for: service)
        do {
            let status = try await service.authStatus()
            phase = status.hasPIN ? .needsPIN : .needsPINSetup
        } catch {
            // A saved session that no longer works shouldn't lock you out of everything.
            if service.sharing.useSession { dropSession(service: service) }
            AppLog.error("locked folder status", error)
            errorMessage = "Couldn't reach the server: \(Self.describe(error))"
            phase = .gate
        }
    }

    private func restoreSavedSession(for service: ImmichService) {
        if service.sharing.sessionToken == nil { service.sharing.sessionToken = APIKeyStore.loadSessionToken() }
    }

    // MARK: - PIN

    func setupPIN(_ pin: String) async {
        guard let service else { return }
        await run {
            do {
                try await service.setupPIN(pin)
                try await self.unlockAndOpen(pin: pin, service: service)
            } catch {
                if self.needsSession(error, service: service) {
                    self.afterSignIn = { await self.setupPIN(pin) }
                    self.phase = .needsSignIn("Immich needs you signed in to set up a PIN.")
                    await self.prefillEmail()
                } else {
                    throw error
                }
            }
        }
    }

    func submitPIN(_ pin: String) async {
        guard let service else { return }
        await run {
            do {
                try await self.unlockAndOpen(pin: pin, service: service)
            } catch {
                if self.needsSession(error, service: service) {
                    self.afterSignIn = { await self.submitPIN(pin) }
                    self.phase = .needsSignIn("Immich only shows the Locked Folder to a signed-in session, not to an API key.")
                    await self.prefillEmail()
                } else {
                    throw error
                }
            }
        }
    }

    /// Unlocks, then checks the Locked Folder can really be read before showing it.
    private func unlockAndOpen(pin: String, service: ImmichService) async throws {
        let hadSession = service.sharing.sessionToken != nil
        service.sharing.useSession = hadSession
        try await service.unlockSession(pin: pin)
        _ = try await service.fetchTimeBuckets(filter: .locked)
        open()
    }

    private func open() {
        phase = .unlocked
        errorMessage = nil
        autoLock?.cancel()
        autoLock = Task {
            try? await Task.sleep(for: Self.openFor)
            if !Task.isCancelled { lock() }
        }
    }

    // MARK: - Signing in

    func signIn(email: String, password: String) async {
        guard let service else { return }
        await run {
            let token = try await service.signIn(email: email, password: password)
            APIKeyStore.saveSessionToken(token)
            service.sharing.sessionToken = token
            service.sharing.useSession = true
            if let next = self.afterSignIn {
                self.afterSignIn = nil
                self.phase = .checking
                await next()
            }
        }
    }

    func signOutOfLockedFolder() async {
        guard let service else { return }
        lock()
        if service.sharing.sessionToken != nil {
            service.sharing.useSession = true
            await service.signOut()
            service.sharing.useSession = false
        }
        APIKeyStore.deleteSessionToken()
        service.sharing.sessionToken = nil
    }

    // MARK: - Locking

    /// Closes the folder and forgets what was fetched while it was open.
    func lock() {
        autoLock?.cancel()
        deactivationLock?.cancel()
        let wasOpen = phase == .unlocked || service?.sharing.useSession == true
        if let service, wasOpen {
            let usedSession = service.sharing.useSession
            Task {
                if usedSession { await service.lockSession() }
                service.sharing.useSession = false
            }
            service.sharing.useSession = false
        }
        Task { await ThumbnailLoader.shared.purgeSensitive() }
        if phase != .gate { phase = .gate }
    }

    /// Locks a minute after the app goes to the background, if it's still open.
    func appDeactivated() {
        guard phase == .unlocked else { return }
        deactivationLock?.cancel()
        deactivationLock = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { lock() }
        }
    }

    func appActivated() { deactivationLock?.cancel() }

    // MARK: - Helpers

    private func run(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            AppLog.error("locked folder", error)
            errorMessage = Self.describe(error)
            if case .checking = phase { phase = .needsPIN }
        }
    }

    /// Whether the server refused because the request wasn't made by a (working) session.
    private func needsSession(_ error: Error, service: ImmichService) -> Bool {
        guard case ImmichServiceError.requestFailed(let status, let message) = error else { return false }
        let text = (message ?? "").lowercased()
        if service.sharing.useSession && service.sharing.sessionToken != nil {
            // Already using a saved session: a 401 means it has expired, so sign in afresh.
            if status == 401 && !text.contains("pin") {
                dropSession(service: service)
                return true
            }
            return false
        }
        return text.contains("session") || text.contains("elevated") || status == 401
    }

    private func dropSession(service: ImmichService) {
        service.sharing.useSession = false
        service.sharing.sessionToken = nil
        APIKeyStore.deleteSessionToken()
    }

    private func prefillEmail() async {
        guard let service, suggestedEmail.isEmpty else { return }
        service.sharing.useSession = false
        if let me = try? await service.fetchMe() { suggestedEmail = me.email }
    }

    private static func describe(_ error: Error) -> String {
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            let text = (message ?? "").lowercased()
            if text.contains("pin") { return "That PIN isn't right." }
            if text.contains("password") || text.contains("credentials") || status == 401 && text.contains("incorrect") {
                return "That email or password isn't right."
            }
            return "The server said \(status)" + (message.map { ": \($0.prefix(140))" } ?? "")
        }
        return error.localizedDescription
    }
}

/// The Locked Folder page: a gate, then the folder's photos.
struct LockedFolderView: View {
    let service: ImmichService
    @EnvironmentObject private var session: LockedFolderSession

    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Group {
            if session.isUnlocked {
                PhotoGridView(service: service, filter: .locked)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Menu {
                                Button("Lock Now") { session.lock() }
                                Divider()
                                Button("Sign Out of Locked Folder") { Task { await session.signOutOfLockedFolder() } }
                            } label: {
                                Label("Locked", systemImage: "lock.open.fill")
                            }
                        }
                    }
            } else {
                gate
            }
        }
        .navigationTitle("")
        .onAppear {
            session.begin(service: service)
            if session.phase == .gate { Task { await session.authenticateLocally() } }
        }
    }

    private var gate: some View {
        CardPage(maxWidth: 460) {
          VStack(spacing: 16) {

            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Locked Folder")
                .font(.title2.weight(.semibold))

            switch session.phase {
            case .gate:
                Text("Your private photos are hidden until you unlock them.")
                    .foregroundStyle(.secondary)
                Button("Unlock with Touch ID or Password") { Task { await session.authenticateLocally() } }
                    .buttonStyle(.borderedProminent)
            case .checking:
                ProgressView()
            case .needsPINSetup:
                Text("Choose a 6-digit PIN for your Locked Folder. Immich uses it to protect these photos.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                SecureField("New PIN", text: $pin).frame(width: 160)
                SecureField("Repeat PIN", text: $confirmPIN).frame(width: 160)
                Button("Set PIN") { Task { await session.setupPIN(pin) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!Self.isValid(pin) || pin != confirmPIN || session.isWorking)
            case .needsPIN:
                Text("Enter your PIN")
                    .foregroundStyle(.secondary)
                SecureField("PIN", text: $pin)
                    .frame(width: 160)
                    .multilineTextAlignment(.center)
                    .onSubmit { submit() }
                    .onChange(of: pin) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(6))
                        if digits != value { pin = digits }
                        if digits.count == 6 { submit() }
                    }
                Button("Unlock") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!Self.isValid(pin) || session.isWorking)
            case .needsSignIn(let reason):
                Text(reason + " Sign in once with your Immich account. Your password isn't saved.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
                TextField("Email", text: $email).textFieldStyle(.roundedBorder).frame(width: 260)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { signIn() }
                Button("Sign In") { signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || password.isEmpty || session.isWorking)
            case .unlocked:
                EmptyView()
            }

            if session.isWorking { ProgressView().controlSize(.small) }
            if let message = session.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
          }
          .frame(maxWidth: .infinity)
        }
        .onChange(of: session.suggestedEmail) { _, value in if email.isEmpty { email = value } }
    }

    private static func isValid(_ pin: String) -> Bool { pin.count == 6 && pin.allSatisfy(\.isNumber) }

    private func submit() {
        guard Self.isValid(pin), !session.isWorking else { return }
        let entered = pin
        pin = ""
        Task { await session.submitPIN(entered) }
    }

    private func signIn() {
        let mail = email, secret = password
        password = ""
        Task { await session.signIn(email: mail, password: secret) }
    }
}

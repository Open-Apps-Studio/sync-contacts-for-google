import Foundation
import SwiftUI
import Contacts
import AuthenticationServices
import SyncEngine

/// Presentation anchor for ASWebAuthenticationSession.
final class ASWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}

/// Thread-safe box so the sync actor can read the latest settings off the main actor.
private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = SyncSettings()
    var value: SyncSettings {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// Thread-safe boolean the sync actor reads to learn whether contacts access is
/// currently Limited (iOS 18). Updated on the main actor whenever auth status changes.
private final class LimitedAccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// The single source of truth for the app. Owns the whole engine stack.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    enum Phase {
        case welcome, connect, access, preview, ready
    }

    /// Counts (and sample names) computed for the first-sync preview. Read-only —
    /// nothing is written while building it.
    struct PreviewCounts {
        var addedToGoogle = 0
        var addedToiPhone = 0
        var merged = 0
        var addedToGoogleNames: [String] = []
        var addedToiPhoneNames: [String] = []
        var mergedNames: [String] = []
        var localTotal = 0
        var remoteTotal = 0
    }

    // MARK: - Engine stack

    let keychain: KeychainTokenStore
    let oauthClient: GoogleOAuthClient
    let tokenProvider: TokenProvider
    let mappingStore: MappingStore
    let snapshots: SnapshotManager
    let contactsAdapter: CNContactStoreAdapter
    let peopleClient: GooglePeopleClient
    let orchestrator: SyncOrchestrator

    private let settingsBox: SettingsBox
    private let limitedAccessBox: LimitedAccessBox
    private let authPresenter = ASWebAuthPresenter()
    private var authSession: ASWebAuthenticationSession?

    // MARK: - Published state

    @Published var phase: Phase = .welcome
    @Published var connectionEmail: String?
    @Published var contactsAuthStatus: CNAuthorizationStatus =
        CNContactStore.authorizationStatus(for: .contacts)
    @Published var lastSyncDate: Date?
    @Published var lastSummary: SyncSummary?
    @Published var syncState: SyncOrchestrator.State = .idle
    @Published var recentActivity: [ActivityEvent] = []
    @Published var isSyncing = false
    @Published var contactCount: Int = 0
    @Published var lastErrorMessage: String?
    /// Read-only "Preview the app" mode: shows the dashboard with clearly-labeled
    /// sample data so people (and App Review) can explore before connecting Google.
    /// No real contacts or Google account are touched while this is on.
    @Published var isDemoMode = false

    @Published var settings: SyncSettings {
        didSet {
            settingsBox.value = settings
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Keys.settings)
            }
        }
    }

    /// True when the user granted only limited contact access (iOS 18+).
    var contactsAccessIsLimited: Bool {
        Self.isLimited(contactsAuthStatus)
    }

    static func isLimited(_ status: CNAuthorizationStatus) -> Bool {
        if #available(iOS 18.0, *) {
            return status == .limited
        }
        return false
    }

    var contactsAccessGranted: Bool {
        contactsAuthStatus == .authorized || contactsAccessIsLimited
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let onboardingComplete = "onboardingComplete"
        static let connectionEmail = "connectionEmail"
        static let lastSyncDate = "lastSyncDate"
        static let lastSummary = "lastSummary"
        static let settings = "syncSettings"
        static let contactCount = "contactCount"
        static let apnsToken = "apnsTokenHex"
        static let lastWakeDate = "lastBackgroundWakeDate"
        static let lastWakeSource = "lastBackgroundWakeSource"

        static let all = [onboardingComplete, connectionEmail, lastSyncDate, lastSummary,
                          settings, contactCount, apnsToken, lastWakeDate, lastWakeSource]
    }

    // MARK: - Init

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let keychain = KeychainTokenStore()
        let oauthClient = GoogleOAuthClient(config: GoogleOAuthConfig(
            clientID: AppConfig.googleOAuthClientID,
            redirectScheme: AppConfig.oauthRedirectScheme))
        let tokenProvider = TokenProvider(oauth: oauthClient, store: keychain)
        // App Support is always writable inside the app sandbox.
        let mappingStore = try! MappingStore(path: appSupport.appendingPathComponent("sync.sqlite").path)
        let snapshots = SnapshotManager(directory: appSupport.appendingPathComponent("snapshots"))
        let contactsAdapter = CNContactStoreAdapter()
        let peopleClient = GooglePeopleClient(tokenProvider: { try await tokenProvider.currentAccessToken() })

        let box = SettingsBox()
        let limitedBox = LimitedAccessBox()
        limitedBox.value = Self.isLimited(CNContactStore.authorizationStatus(for: .contacts))
        let defaults = UserDefaults.standard
        let loadedSettings: SyncSettings
        if let data = defaults.data(forKey: Keys.settings),
           let decoded = try? JSONDecoder().decode(SyncSettings.self, from: data) {
            loadedSettings = decoded
        } else {
            loadedSettings = SyncSettings()
        }
        box.value = loadedSettings

        self.keychain = keychain
        self.oauthClient = oauthClient
        self.tokenProvider = tokenProvider
        self.mappingStore = mappingStore
        self.snapshots = snapshots
        self.contactsAdapter = contactsAdapter
        self.peopleClient = peopleClient
        self.settingsBox = box
        self.limitedAccessBox = limitedBox
        self.settings = loadedSettings
        self.orchestrator = SyncOrchestrator(deps: .init(
            local: contactsAdapter,
            remote: peopleClient,
            store: mappingStore,
            snapshots: snapshots,
            localAccessLimited: { limitedBox.value },
            settings: { box.value }))

        // Restore persisted UI state.
        connectionEmail = defaults.string(forKey: Keys.connectionEmail)
        lastSyncDate = defaults.object(forKey: Keys.lastSyncDate) as? Date
        contactCount = defaults.integer(forKey: Keys.contactCount)
        if let data = defaults.data(forKey: Keys.lastSummary),
           let summary = try? JSONDecoder().decode(SyncSummary.self, from: data) {
            lastSummary = summary
        }
        if defaults.bool(forKey: Keys.onboardingComplete) {
            phase = .ready
        }
        refreshActivity()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoMode") {
            enterDemoMode()
        }
        #endif
    }

    // MARK: - Demo / preview mode

    /// Enters the read-only preview. Populates believable sample state and lands on
    /// the dashboard. Safe in release: `runSync` requires a real Google token (none
    /// exists here), so nothing is ever written to the address book or Google.
    func enterDemoMode() {
        isDemoMode = true
        connectionEmail = "demo@openappsstudio.com"
        contactCount = 1482
        lastSyncDate = Date().addingTimeInterval(-120)
        var demoSummary = SyncSummary()
        demoSummary.addedToGoogle = 3
        demoSummary.updatedOniPhone = 1
        lastSummary = demoSummary
        recentActivity = [
            ActivityEvent(id: 3, timestamp: Date().addingTimeInterval(-120), kind: .syncCompleted,
                          summary: "Everything already in sync"),
            ActivityEvent(id: 2, timestamp: Date().addingTimeInterval(-7200), kind: .updatedOniPhone,
                          summary: "Updated \"Anna Lee\" on iPhone"),
            ActivityEvent(id: 1, timestamp: Date().addingTimeInterval(-86400), kind: .addedToGoogle,
                          summary: "Added \"Priya Sharma\" to Google")
        ]
        phase = .ready
    }

    /// Leaves preview and returns to the welcome screen (used by the demo banner's
    /// "Connect Google" action, which routes into the real onboarding).
    func exitDemoMode(startConnect: Bool = false) {
        isDemoMode = false
        connectionEmail = nil
        contactCount = 0
        lastSyncDate = nil
        lastSummary = nil
        recentActivity = []
        phase = startConnect ? .connect : .welcome
    }

    // MARK: - Google connection

    /// Runs the full PKCE flow in ASWebAuthenticationSession and stores the tokens.
    /// Does not advance `phase` — the calling view decides how to transition.
    func connectGoogle() async throws {
        let pending = oauthClient.makeAuthorization()
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: pending.url,
                callbackURLScheme: AppConfig.oauthRedirectScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = authPresenter
            session.start()
            self.authSession = session  // keep alive for the duration of the flow
        }
        authSession = nil
        let tokens = try await oauthClient.exchangeCode(callbackURL: callbackURL, pending: pending)
        try await tokenProvider.adopt(tokens)
        connectionEmail = tokens.email
        UserDefaults.standard.set(tokens.email, forKey: Keys.connectionEmail)
    }

    // MARK: - Contacts access

    func requestContactsAccess() async {
        let store = CNContactStore()
        _ = try? await store.requestAccess(for: .contacts)
        refreshContactsAuthStatus()
    }

    func refreshContactsAuthStatus() {
        contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
        // Keep the sync actor's data-loss guard in step with the live permission.
        limitedAccessBox.value = contactsAccessIsLimited
    }

    /// A Google account is also syncing contacts natively on this device — warn about
    /// the duplicate risk during setup.
    var hasNativeGoogleSyncOverlap: Bool {
        contactsAdapter.hasGoogleCardDAVContainer()
    }

    // MARK: - First-sync preview

    /// Fetches both sides and runs the matcher WITHOUT writing anything anywhere.
    func buildPreview() async throws -> PreviewCounts {
        let locals = try await contactsAdapter.fetchAll()
        let delta = try await peopleClient.listConnections(syncToken: nil)

        let localCandidates = locals
            .filter { !$0.contact.isEffectivelyEmpty }
            .map { Matching.Candidate(id: $0.id, contact: $0.contact) }
        let remoteCandidates = delta.records
            .filter { !$0.deleted && !$0.contact.isEffectivelyEmpty }
            .map { Matching.Candidate(id: $0.resourceName, contact: $0.contact) }
        let match = Matching.match(local: localCandidates, remote: remoteCandidates)

        var preview = PreviewCounts()
        preview.localTotal = locals.count
        preview.remoteTotal = delta.records.filter { !$0.deleted }.count
        if settings.mode != .googleToIphone {
            preview.addedToGoogle = match.localOnly.count
            preview.addedToGoogleNames = match.localOnly.map(\.contact.displayName)
        }
        if settings.mode != .iphoneToGoogle {
            preview.addedToiPhone = match.remoteOnly.count
            preview.addedToiPhoneNames = match.remoteOnly.map(\.contact.displayName)
        }
        preview.merged = match.pairs.count
        preview.mergedNames = match.pairs.map(\.local.contact.displayName)

        contactCount = locals.count
        UserDefaults.standard.set(locals.count, forKey: Keys.contactCount)
        return preview
    }

    // MARK: - Sync

    @discardableResult
    func runSync(isFirstSync: Bool = false) async -> SyncSummary? {
        guard !isSyncing else { return nil }
        guard await tokenProvider.isConnected else { return nil }
        isSyncing = true
        lastErrorMessage = nil
        defer { isSyncing = false }

        var result: SyncSummary?
        do {
            let summary = try await orchestrator.sync(isFirstSync: isFirstSync)
            result = summary
            lastSummary = summary
            if let data = try? JSONEncoder().encode(summary) {
                UserDefaults.standard.set(data, forKey: Keys.lastSummary)
            }
            if summary.paused == nil {
                lastSyncDate = Date()
                UserDefaults.standard.set(lastSyncDate, forKey: Keys.lastSyncDate)
            }
            if let count = try? await contactsAdapter.count() {
                contactCount = count
                UserDefaults.standard.set(count, forKey: Keys.contactCount)
            }
        } catch {
            lastErrorMessage = Self.friendlyMessage(for: error)
        }
        syncState = await orchestrator.state
        refreshActivity()
        return result
    }

    /// Marks onboarding done and lands on the dashboard.
    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Keys.onboardingComplete)
        phase = .ready
    }

    // MARK: - Deletion guard

    func confirmDeletions() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let summary = try await orchestrator.confirmDeletionsAndResume()
            lastSummary = summary
            if let data = try? JSONEncoder().encode(summary) {
                UserDefaults.standard.set(data, forKey: Keys.lastSummary)
            }
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: Keys.lastSyncDate)
        } catch {
            lastErrorMessage = Self.friendlyMessage(for: error)
        }
        syncState = await orchestrator.state
        refreshActivity()
    }

    func rejectDeletions() async {
        try? await orchestrator.rejectPendingDeletions()
        syncState = await orchestrator.state
        refreshActivity()
    }

    // MARK: - Push registration

    func registerDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Keys.apnsToken)
        Task {
            var request = URLRequest(url: AppConfig.backendBaseURL.appendingPathComponent("v1/device"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "token": hex,
                "cadenceMinutes": AppConfig.pushCadenceMinutes
            ])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func unregisterDeviceFromBackend() async {
        guard let hex = UserDefaults.standard.string(forKey: Keys.apnsToken) else { return }
        var request = URLRequest(url: AppConfig.backendBaseURL
            .appendingPathComponent("v1/device")
            .appendingPathComponent(hex))
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
        UserDefaults.standard.removeObject(forKey: Keys.apnsToken)
    }

    // MARK: - Disconnect / reset

    /// Revokes the Google grant and returns to onboarding. Contacts (and the mapping
    /// table) stay on the phone so reconnecting doesn't duplicate anything.
    func disconnect() async {
        await tokenProvider.disconnectAndRevoke()
        await unregisterDeviceFromBackend()
        connectionEmail = nil
        UserDefaults.standard.removeObject(forKey: Keys.connectionEmail)
        UserDefaults.standard.removeObject(forKey: Keys.onboardingComplete)
        phase = .welcome
    }

    /// Full factory reset: tokens, mappings, sync cursors, snapshots, preferences.
    /// Contacts themselves are never touched.
    func deleteAllAppData() async {
        await tokenProvider.disconnectAndRevoke()
        await unregisterDeviceFromBackend()
        try? mappingStore.deleteAllMappings()
        try? mappingStore.clearWorkQueue()
        try? mappingStore.setCursor("google.syncToken", nil)
        try? mappingStore.pruneActivity(keeping: 0)

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: appSupport.appendingPathComponent("snapshots"))
        try? fm.createDirectory(at: appSupport.appendingPathComponent("snapshots"),
                                withIntermediateDirectories: true)

        for key in Keys.all { UserDefaults.standard.removeObject(forKey: key) }
        connectionEmail = nil
        lastSyncDate = nil
        lastSummary = nil
        recentActivity = []
        contactCount = 0
        settings = SyncSettings()
        syncState = .idle
        phase = .welcome
    }

    // MARK: - Activity

    func refreshActivity() {
        guard !isDemoMode else { return }   // keep the sample activity intact in preview
        recentActivity = (try? mappingStore.recentActivity(limit: 200)) ?? []
    }

    // MARK: - Background wake bookkeeping (Sync Health screen)

    nonisolated static func recordBackgroundWake(source: String) {
        UserDefaults.standard.set(Date(), forKey: Keys.lastWakeDate)
        UserDefaults.standard.set(source, forKey: Keys.lastWakeSource)
    }

    static var lastBackgroundWake: (date: Date, source: String)? {
        guard let date = UserDefaults.standard.object(forKey: Keys.lastWakeDate) as? Date,
              let source = UserDefaults.standard.string(forKey: Keys.lastWakeSource)
        else { return nil }
        return (date, source)
    }

    // MARK: - Error copy

    static func friendlyMessage(for error: Error) -> String {
        switch error {
        case OAuthError.notConnected, OAuthError.noRefreshToken, OAuthError.tokenEndpoint:
            // Grant revoked / password changed / refresh rejected: the local mapping
            // and connection email stay put; the user just needs to reconnect Google.
            return "Google isn't connected. Sign in again from Settings."
        case PeopleAPIError.unauthorized:
            return "Google sign-in expired. Reconnect your account from Settings."
        case PeopleAPIError.rateLimited:
            return "Google asked us to slow down — sync will retry shortly."
        case PeopleAPIError.quotaExhausted:
            return "Google limits daily updates — the rest finish automatically tomorrow."
        case let PeopleAPIError.http(status, _):
            return "Google returned an error (\(status)). We'll retry on the next sync."
        case is URLError:
            return "No connection to Google right now. Sync resumes when you're back online."
        default:
            return "Sync hit a snag: \(error.localizedDescription)"
        }
    }
}

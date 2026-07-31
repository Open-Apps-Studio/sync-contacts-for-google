import UIKit
import BackgroundTasks
import Contacts

/// Ensures a BGTask's completion callback runs exactly once. The OS expiration handler
/// and the work task can both try to complete the task; calling setTaskCompleted twice
/// is undefined, so this serializes and de-dupes the call behind a lock.
private final class BGTaskCompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let task: BGTask

    init(_ task: BGTask) { self.task = task }

    func complete(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}

/// Background plumbing: BGTaskScheduler, silent push, APNs registration, and the
/// CNContactStore change observer. All sync work funnels into AppState.runSync().
final class AppDelegate: NSObject, UIApplicationDelegate {

    private var contactChangeDebounce: Task<Void, Never>?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerBackgroundTasks()
        Self.scheduleBackgroundTasks()
        application.registerForRemoteNotifications()

        NotificationCenter.default.addObserver(
            self, selector: #selector(contactStoreDidChange),
            name: .CNContactStoreDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        return true
    }

    // MARK: - BGTaskScheduler

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.refreshTaskID,
                                        using: nil) { [weak self] task in
            self?.handle(task: task, source: "Background refresh")
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.reconcileTaskID,
                                        using: nil) { [weak self] task in
            self?.handle(task: task, source: "Background reconcile")
        }
    }

    static func scheduleBackgroundTasks() {
        let refresh = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let reconcile = BGProcessingTaskRequest(identifier: AppConfig.reconcileTaskID)
        reconcile.requiresNetworkConnectivity = true
        reconcile.requiresExternalPower = false
        reconcile.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        try? BGTaskScheduler.shared.submit(reconcile)
    }

    private func handle(task: BGTask, source: String) {
        // Always re-arm before doing work, so a crash doesn't stop the chain.
        Self.scheduleBackgroundTasks()
        AppState.recordBackgroundWake(source: source)

        let completion = BGTaskCompletionGuard(task)
        let work = Task { @MainActor in
            let state = AppState.shared
            if state.phase == .ready && state.settings.automaticSync {
                await state.runSync()
            }
            completion.complete(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }

    // MARK: - APNs / silent push

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            AppState.shared.registerDeviceToken(deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected on simulator; background pushes simply won't arrive.
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        AppState.recordBackgroundWake(source: "Silent push")
        Task { @MainActor in
            let state = AppState.shared
            guard state.phase == .ready, state.settings.automaticSync else {
                completionHandler(.noData)
                return
            }
            let summary = await state.runSync()
            completionHandler((summary?.totalChanges ?? 0) > 0 ? .newData : .noData)
        }
    }

    // MARK: - Contact change observer (3s debounce)

    @objc private func contactStoreDidChange(_ note: Notification) {
        contactChangeDebounce?.cancel()
        contactChangeDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard UIApplication.shared.applicationState == .active else { return }
            let state = AppState.shared
            guard state.phase == .ready, state.settings.automaticSync, !state.isSyncing else { return }
            await state.runSync()
        }
    }

    @objc private func appDidEnterBackground(_ note: Notification) {
        Self.scheduleBackgroundTasks()
    }
}

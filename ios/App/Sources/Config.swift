import Foundation

/// Central place for deploy-time configuration.
enum AppConfig {
    /// Supply your own Google iOS OAuth client ID (Google Cloud Console →
    /// APIs & Services → Credentials → "OAuth client ID" of type iOS). iOS
    /// clients use PKCE with no client secret, so this ID ships in the binary.
    static let googleOAuthClientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"

    /// Custom URL scheme registered in Info.plist for the OAuth redirect —
    /// Google iOS clients use the reversed client ID as the scheme. Keep this
    /// in sync with `CFBundleURLSchemes` in Info.plist / project.yml.
    static let oauthRedirectScheme = "com.googleusercontent.apps.YOUR_CLIENT_ID"

    /// Base URL of your deployed push-scheduler backend (see `backend/`).
    static let backendBaseURL = URL(string: "https://YOUR_BACKEND.example.com")!

    /// BGTaskScheduler identifiers (must match BGTaskSchedulerPermittedIdentifiers).
    static let refreshTaskID = "com.openappsstudio.contactssync.refresh"
    static let reconcileTaskID = "com.openappsstudio.contactssync.reconcile"

    /// Silent-push cadence requested from the backend.
    static let pushCadenceMinutes = 20
}

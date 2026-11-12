import Foundation
import OSLog
import UserNotifications

/// Local notifications for proposal arrivals.
///
/// Foreground-only serving (an iOS constraint) means proposals only arrive
/// while Niles is up — so the notification is presented as an in-app banner
/// via `willPresent`, and never needs a background-delivery story.
final class ProposalNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ProposalNotifier()
    /// A no-op notifier for tests and previews.
    static let disabled = ProposalNotifier(isDisabled: true)

    private let isDisabled: Bool
    private let logger = Logger(subsystem: "com.gerstman.niles", category: "notifications")

    private init(isDisabled: Bool) {
        self.isDisabled = isDisabled
        super.init()
    }

    convenience override init() {
        self.init(isDisabled: false)
    }

    /// The center's delegate must be set before launch finishes so banners
    /// present while the app is foregrounded (the only time it runs).
    static func registerForegroundPresentation() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// Asks once, on first launch. When the user declines, proposals still
    /// queue on the Approvals tab — the banner is a courtesy, not the channel.
    func requestPermissionIfNeeded() {
        guard !isDisabled else { return }
        // Fixture runs (seeded relaunch QA) capture the UI headless — there
        // is no one to answer the system prompt, and it would occlude every
        // capture. Skip the request under that launch argument.
        guard !ProcessInfo.processInfo.arguments.contains("-UINotificationsDisabled") else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if !granted {
                    logger.notice("Proposal notifications declined; the Approvals tab is the only channel")
                }
            } catch {
                // A denied authorization request is a user-visible dead end if
                // silenced; log it so a broken permission state is discoverable.
                logger.error("Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Posts the arrival banner for one staged proposal.
    func proposalArrived(title: String, summary: String) {
        guard !isDisabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Proposal from an agent"
        content.subtitle = title
        content.body = summary
        content.sound = .default
        let request = UNNotificationRequest(identifier: "proposal-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Failed to post proposal notification: \(error.localizedDescription)")
            }
        }
    }

    /// Present banners in-app while foregrounded — Niles never serves in the
    /// background, so every arrival happens on this screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

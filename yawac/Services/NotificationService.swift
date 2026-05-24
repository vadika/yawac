import Foundation
import UserNotifications
import AppKit

/// Surface a banner notification.
///
/// On signed builds we'd use `UNUserNotificationCenter`. Ad-hoc/dev builds
/// can't get authorization (macOS rejects them silently — `didGrant: 0,
/// hasError: 1`), so we additionally fall back to `osascript`'s `display
/// notification`, which fires through the always-signed System Events
/// process and doesn't need per-app authorization. Once UN is authorized
/// the osascript fallback is suppressed to avoid "Script Editor" attribution.
enum NotificationService {
    /// True once `UNUserNotificationCenter` grants authorization.
    /// Used to suppress the osascript fallback on signed builds so
    /// notifications are attributed to yawac rather than "Script Editor".
    private static var unGranted: Bool = false

    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        unGranted = granted
        NSLog("[yawac/notify] UN authorization granted=%d", granted ? 1 : 0)
    }

    static func notify(
        title: String,
        body: String,
        chatJID: String,
        subtitle: String? = nil,
        resolveMentions: ((String) -> String)? = nil
    ) {
        let resolvedBody: String
        if let resolveMentions {
            resolvedBody = resolveMentionsText(body, resolver: resolveMentions)
        } else {
            resolvedBody = body
        }

        // Path A: official user-notification (works only on signed builds)
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = resolvedBody
        content.sound = .default
        content.userInfo = ["chatJID": chatJID]
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(req)

        // Path B: osascript fallback — always works on macOS, but attributes
        // the notification to "Script Editor". Suppressed when UN is authorized.
        if !unGranted {
            osascriptNotify(title: title, subtitle: subtitle, body: resolvedBody)
        }
    }

    private static func osascriptNotify(title: String, subtitle: String?, body: String) {
        let safeTitle = escapeForAppleScript(title)
        let safeBody = escapeForAppleScript(body)
        let script: String
        if let subtitle, !subtitle.isEmpty {
            let safeSubtitle = escapeForAppleScript(subtitle)
            script =
                "display notification \"\(safeBody)\" with title \"\(safeTitle)\" subtitle \"\(safeSubtitle)\""
        } else {
            script =
                "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do {
            try task.run()
        } catch {
            // Last-resort: bell-only via NSSound, no banner.
            NSLog("[yawac/notify] osascript fail: %@", error.localizedDescription)
        }
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Notification tap → open chat

@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Set once from AppRoot's `.task` so taps can route to the right chat.
    weak var session: SessionViewModel?

    /// Show banners even when the app is foregrounded (otherwise macOS
    /// silently drops them).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let chatJID = userInfo["chatJID"] as? String
        Task { @MainActor in
            if let jid = chatJID, !jid.isEmpty {
                self.session?.pendingChatSelection = jid
            }
            WindowToggler.bringToFront()
            completionHandler()
        }
    }
}

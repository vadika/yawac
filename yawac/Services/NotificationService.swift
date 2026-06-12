import Foundation
import UserNotifications
import AppKit

/// F73-F74: pure-function inputs for `buildNotificationContent`.
/// All side-channel state (per-chat bell, global toggles) is passed
/// in so the builder is testable without `UserDefaults` mocking.
struct NotificationPrefs {
    let enabled: Bool
    let preview: Bool
    let soundName: String  // "Default" / "Pop" / "Glass" / "None"
    let bellEnabled: Bool
}

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

    /// F64: notification category id used for incoming chat messages.
    /// Carries the inline Reply text-input action so the user can send
    /// a reply from the banner without bringing yawac to the front.
    static let messageCategoryID = "MESSAGE"

    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        unGranted = granted
        NSLog("[yawac/notify] UN authorization granted=%d", granted ? 1 : 0)
        // F64: register the Reply text-input action regardless of grant
        // state — the category survives across launches and is needed
        // the moment the user grants authorization.
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply…")
        let category = UNNotificationCategory(
            identifier: messageCategoryID,
            actions: [replyAction],
            intentIdentifiers: [],
            options: [])
        center.setNotificationCategories([category])
    }

    /// F73-F74: pure builder. Returns `nil` when the notification is fully
    /// suppressed (master notifications-enabled toggle is off). Caller
    /// short-circuits without scheduling a `UNNotificationRequest` or
    /// firing the osascript fallback.
    static func buildNotificationContent(
        title: String,
        subtitle: String?,
        body: String,
        chatJID: String,
        prefs: NotificationPrefs
    ) -> UNMutableNotificationContent? {
        guard prefs.enabled else { return nil }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = prefs.preview ? body : ""
        content.userInfo = ["chatJID": chatJID]
        // F64: wire the message category so the banner shows the inline
        // Reply action.
        content.categoryIdentifier = Self.messageCategoryID
        if prefs.bellEnabled {
            switch prefs.soundName {
            case "Default": content.sound = .default
            case "Pop":     content.sound = UNNotificationSound(named: UNNotificationSoundName("Pop.aiff"))
            case "Glass":   content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
            case "None":    content.sound = nil
            default:        content.sound = .default
            }
        } else {
            content.sound = nil
        }
        return content
    }

    static func notify(
        title: String,
        body: String,
        chatJID: String,
        subtitle: String? = nil,
        resolveMentions: ((String) -> String)? = nil,
        bellEnabled: Bool = true
    ) {
        let resolvedBody: String = resolveMentions.map { resolver in
            resolveMentionsText(body, resolver: resolver)
        } ?? body
        // `UserDefaults.standard.object(forKey:) as? Bool ?? true` honors
        // @AppStorage default-true semantics when the key has never been
        // written.
        let prefs = NotificationPrefs(
            enabled: UserDefaults.standard.object(forKey: "yawac.notifications.enabled") as? Bool ?? true,
            preview: UserDefaults.standard.object(forKey: "yawac.notifications.preview") as? Bool ?? true,
            soundName: UserDefaults.standard.string(forKey: "yawac.notifications.sound") ?? "Default",
            bellEnabled: bellEnabled
        )
        guard let content = buildNotificationContent(
            title: title, subtitle: subtitle, body: resolvedBody,
            chatJID: chatJID, prefs: prefs
        ) else { return }
        // Path A: official user-notification (works only on signed builds)
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
        // F64: inline Reply path. Send the text via the bridge without
        // bringing yawac to the front; surface the outgoing message in
        // the open conversation if the user happens to have it open.
        if let textResponse = response as? UNTextInputNotificationResponse,
           response.actionIdentifier == "REPLY",
           let jid = chatJID, !jid.isEmpty {
            let text = textResponse.userText
            Task { @MainActor in
                guard let session = self.session,
                      let client = session.client,
                      !text.isEmpty else {
                    completionHandler()
                    return
                }
                let cjid = JIDNormalize.canonical(jid, client: client)
                // sendText is nonisolated (F51) — run off MainActor so the
                // notification handler returns quickly. The bridge call
                // echoes back via the normal .message event stream, which
                // updates the open conversation + sidebar through the
                // existing ingest pipeline.
                _ = try? await Task.detached(priority: .userInitiated) {
                    try client.sendText(cjid, text)
                }.value
                completionHandler()
            }
            return
        }
        Task { @MainActor in
            if let jid = chatJID, !jid.isEmpty {
                self.session?.pendingChatSelection = jid
            }
            WindowToggler.bringToFront()
            completionHandler()
        }
    }
}

import Foundation
import UserNotifications

/// Surface a banner notification.
///
/// On signed builds we'd use `UNUserNotificationCenter`. Ad-hoc/dev builds
/// can't get authorization (macOS rejects them silently — `didGrant: 0,
/// hasError: 1`), so we additionally fall back to `osascript`'s `display
/// notification`, which fires through the always-signed System Events
/// process and doesn't need per-app authorization. Calling both is fine:
/// when UN is unauthorized it no-ops; when it works the user sees one
/// banner because macOS de-dupes by title+body.
enum NotificationService {
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notify(title: String, body: String, chatJID: String) {
        // Path A: official user-notification (works only on signed builds)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["chatJID": chatJID]
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(req)

        // Path B: osascript fallback — always works on macOS.
        osascriptNotify(title: title, body: body)
    }

    private static func osascriptNotify(title: String, body: String) {
        let safeTitle = escapeForAppleScript(title)
        let safeBody = escapeForAppleScript(body)
        let script =
            "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
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

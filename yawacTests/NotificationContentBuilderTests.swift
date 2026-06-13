import XCTest
import UserNotifications
@testable import yawac

final class NotificationContentBuilderTests: XCTestCase {
    private func prefs(
        enabled: Bool = true,
        preview: Bool = true,
        soundName: String = "Default",
        bellEnabled: Bool = true
    ) -> NotificationPrefs {
        NotificationPrefs(enabled: enabled, preview: preview,
                          soundName: soundName, bellEnabled: bellEnabled)
    }

    func testReturnsNilWhenMasterDisabled() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(enabled: false))
        XCTAssertNil(c)
    }

    func testBlanksBodyWhenPreviewOff() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "secret", chatJID: "x",
            prefs: prefs(preview: false))
        XCTAssertEqual(c?.body, "")
        XCTAssertEqual(c?.title, "T")
    }

    func testKeepsBodyWhenPreviewOn() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "hello", chatJID: "x",
            prefs: prefs(preview: true))
        XCTAssertEqual(c?.body, "hello")
    }

    func testSoundNoneStripsSound() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(soundName: "None"))
        XCTAssertNil(c?.sound)
    }

    func testBellOffStripsSound() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(soundName: "Default", bellEnabled: false))
        XCTAssertNil(c?.sound)
    }

    func testBellOnHonorsGlobalSound() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(soundName: "Default", bellEnabled: true))
        XCTAssertNotNil(c?.sound)
    }

    func testUserInfoCarriesChatJID() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "abc@x",
            prefs: prefs())
        XCTAssertEqual(c?.userInfo["chatJID"] as? String, "abc@x")
    }

    func testCategoryIdentifierWired() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs())
        XCTAssertEqual(c?.categoryIdentifier, NotificationService.messageCategoryID)
    }
}

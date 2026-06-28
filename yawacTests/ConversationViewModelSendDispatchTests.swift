import XCTest
@testable import yawac

@MainActor
final class ConversationViewModelSendDispatchTests: XCTestCase {

    private func makeVM() throws -> ConversationViewModel {
        let dir = NSTemporaryDirectory().appending("yawac-send-dispatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let client = try WAClient(dbPath: dir + "/state.db")
        return ConversationViewModel(chatJID: "1@s.whatsapp.net", client: client)
    }

    func testStageLocationAppends() throws {
        let vm = try makeVM()
        vm.stageLocation(LocationPayload(lat: 60, lng: 24, name: "X", address: "Y"))
        XCTAssertEqual(vm.pendingLocations.count, 1)
        XCTAssertEqual(vm.pendingLocations.first?.name, "X")
        XCTAssertEqual(vm.pendingLocations.first?.address, "Y")
    }

    func testStageContactAppends() throws {
        let vm = try makeVM()
        vm.stageContact(ContactPayload(
            jid: "1@s.whatsapp.net", displayName: "A", phone: "+1"))
        XCTAssertEqual(vm.pendingContacts.count, 1)
        XCTAssertEqual(vm.pendingContacts.first?.displayName, "A")
    }

    func testRemovePendingLocation() throws {
        let vm = try makeVM()
        vm.stageLocation(LocationPayload(lat: 60, lng: 24, name: "A", address: ""))
        vm.stageLocation(LocationPayload(lat: 61, lng: 25, name: "B", address: ""))
        vm.removePendingLocation(at: 0)
        XCTAssertEqual(vm.pendingLocations.map(\.name), ["B"])
    }

    func testRemovePendingContact() throws {
        let vm = try makeVM()
        vm.stageContact(ContactPayload(
            jid: "1@s.whatsapp.net", displayName: "A", phone: ""))
        vm.stageContact(ContactPayload(
            jid: "2@s.whatsapp.net", displayName: "B", phone: ""))
        vm.removePendingContact(at: 0)
        XCTAssertEqual(vm.pendingContacts.map(\.displayName), ["B"])
    }

    func testRemoveOutOfBoundsIsNoop() throws {
        let vm = try makeVM()
        vm.stageLocation(LocationPayload(lat: 60, lng: 24, name: "A", address: ""))
        vm.removePendingLocation(at: 5)
        vm.removePendingContact(at: 5)
        XCTAssertEqual(vm.pendingLocations.count, 1)
        XCTAssertEqual(vm.pendingContacts.count, 0)
    }

    func testSendPendingAttachmentsEmptyIsNoop() async throws {
        let vm = try makeVM()
        // No staged items of any kind — must not throw or mutate state.
        await vm.sendPendingAttachments()
        XCTAssertTrue(vm.messages.isEmpty)
    }
}

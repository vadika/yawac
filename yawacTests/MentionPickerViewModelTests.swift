import XCTest
@testable import yawac

@MainActor
final class MentionPickerViewModelTests: XCTestCase {

    private func makePicker() -> MentionPickerViewModel { MentionPickerViewModel() }

    private func participant(_ jid: String, _ name: String) -> MentionPickerViewModel.Candidate {
        .participant(jid: jid, displayName: name)
    }

    private func loadGroup(_ p: MentionPickerViewModel,
                           _ items: [MentionPickerViewModel.Candidate]) {
        p.setCandidates(items, includeEveryone: true)
    }

    private func loadDM(_ p: MentionPickerViewModel,
                        _ items: [MentionPickerViewModel.Candidate]) {
        p.setCandidates(items, includeEveryone: false)
    }

    func testAtOpensWithFullList() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice"),
                      participant("b@s.whatsapp.net", "Bob")])
        p.update(text: "@")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.filtered.map(\.label), ["everyone", "Alice", "Bob"])
        XCTAssertEqual(p.selectedIdx, 0)
    }

    func testFilterByPrefix() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice"),
                      participant("b@s.whatsapp.net", "Bob")])
        p.update(text: "@bo")
        XCTAssertEqual(p.filtered.map(\.label), ["Bob"])
    }

    func testWhitespaceAfterAtClosesPicker() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@ ")
        XCTAssertFalse(p.isActive)
    }

    func testAtMustFollowWhitespace() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "email@example")
        XCTAssertFalse(p.isActive)
    }

    func testAtAfterSpaceOpens() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "hello @a")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.filtered.map(\.label), ["Alice"])
    }

    func testEveryoneHiddenInDM() {
        let p = makePicker()
        loadDM(p, [participant("u@s.whatsapp.net", "User")])
        p.update(text: "@")
        XCTAssertEqual(p.filtered.map(\.label), ["User"])
    }

    func testMoveWraps() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice"),
                      participant("b@s.whatsapp.net", "Bob")])
        p.update(text: "@")
        XCTAssertEqual(p.selectedIdx, 0)
        p.move(by: 1); XCTAssertEqual(p.selectedIdx, 1)
        p.move(by: 1); XCTAssertEqual(p.selectedIdx, 2)
        p.move(by: 1); XCTAssertEqual(p.selectedIdx, 0)
        p.move(by: -1); XCTAssertEqual(p.selectedIdx, 2)
    }

    func testCommitSelectedReturnsCandidate() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@al")
        let picked = p.commitSelected()
        XCTAssertEqual(picked?.label, "Alice")
        XCTAssertFalse(p.isActive)
    }

    func testTriggerRangeCoversAtThroughEnd() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        let text = "hello @al"
        p.update(text: text)
        let r = p.triggerRange!
        XCTAssertEqual(String(text[r]), "@al")
    }

    func testEveryoneMatchesAllPrefix() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@all")
        XCTAssertEqual(p.filtered.first?.label, "everyone")
    }

    func testCancelClears() {
        let p = makePicker()
        loadGroup(p, [participant("a@s.whatsapp.net", "Alice")])
        p.update(text: "@a")
        p.cancel()
        XCTAssertFalse(p.isActive)
        XCTAssertNil(p.triggerRange)
    }
}

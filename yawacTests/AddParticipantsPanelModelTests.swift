import XCTest
@testable import yawac

/// Fake validator captures calls so we can assert debouncing.
final class CountingValidator: PhoneValidating {
    var ownJID: String = "me@s.whatsapp.net"
    var calls: [String] = []
    var result: PhoneCheckResult = .init(
        jid: "1234@s.whatsapp.net", registered: true,
        businessName: nil, pushName: nil, fullName: nil)

    func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
        calls.append(phone)
        return result
    }
}

@MainActor
final class AddParticipantsPanelModelTests: XCTestCase {
    private func makeModel(existing: [String] = [],
                           validator: PhoneValidating = CountingValidator())
        -> AddParticipantsPanelModel {
        let m = AddParticipantsPanelModel(
            existingParticipantJIDs: Set(existing),
            allContacts: [
                BridgeContact(jid: "1@s.whatsapp.net", name: "Anna",
                              pushName: nil, fullName: "Anna Berg",
                              businessName: nil),
                BridgeContact(jid: "2@s.whatsapp.net", name: "Carlos",
                              pushName: nil, fullName: "Carlos Romero",
                              businessName: nil),
                BridgeContact(jid: "3@s.whatsapp.net", name: "Dana",
                              pushName: nil, fullName: "Dana Park",
                              businessName: nil),
            ],
            validator: validator)
        m.debounceMs = 10  // keep tests fast
        return m
    }

    func testSuggestionsFilterByQuery() {
        let m = makeModel()
        m.query = "an"
        XCTAssertTrue(m.suggestions.contains(where: { $0.name == "Anna" }))
        XCTAssertTrue(m.suggestions.contains(where: { $0.name == "Dana" }))
        XCTAssertFalse(m.suggestions.contains(where: { $0.name == "Carlos" }))
    }

    func testExistingParticipantsExcluded() {
        let m = makeModel(existing: ["1@s.whatsapp.net"])
        m.query = ""
        XCTAssertFalse(m.suggestions.contains(where: { $0.jid == "1@s.whatsapp.net" }))
    }

    func testChipsExcludedFromSuggestions() {
        let m = makeModel()
        m.addChip(BridgeContact(jid: "1@s.whatsapp.net", name: "Anna",
                                pushName: nil, fullName: nil,
                                businessName: nil))
        m.query = ""
        XCTAssertFalse(m.suggestions.contains(where: { $0.jid == "1@s.whatsapp.net" }))
    }

    func testPhoneQueryDebouncesValidator() async {
        let v = CountingValidator()
        let m = makeModel(validator: v)
        m.query = "+1"
        m.query = "+14"
        m.query = "+1415"
        m.query = "+14155551234"
        // give the debounce window a moment to settle
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertLessThanOrEqual(v.calls.count, 1,
            "validator should fire at most once per quiet burst, got \(v.calls)")
    }

    func testPhoneResolvedAddsCandidate() async {
        let v = CountingValidator()
        let m = makeModel(validator: v)
        m.query = "+14155551234"
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(m.phoneCandidate?.jid, "1234@s.whatsapp.net")
    }

    func testNonPhoneClearsCandidate() async {
        let v = CountingValidator()
        let m = makeModel(validator: v)
        m.query = "+14155551234"
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(m.phoneCandidate)
        m.query = "Anna"
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(m.phoneCandidate)
    }

    func testApplyResultDropsSuccessChipsKeepsFailures() {
        let m = makeModel()
        let anna = BridgeContact(jid: "1@s.whatsapp.net", name: "Anna",
                                 pushName: nil, fullName: nil, businessName: nil)
        let carlos = BridgeContact(jid: "2@s.whatsapp.net", name: "Carlos",
                                   pushName: nil, fullName: nil, businessName: nil)
        m.addChip(anna)
        m.addChip(carlos)
        m.applyResult([
            BridgeParticipantModel(jid: "1@s.whatsapp.net",
                                   isAdmin: false, isSuper: false),
            BridgeParticipantModel(jid: "2@s.whatsapp.net",
                                   isAdmin: false, isSuper: false,
                                   errorCode: 403,
                                   inviteCode: "ABC", inviteExpiry: 0),
        ])
        XCTAssertEqual(m.chips.count, 1)
        XCTAssertEqual(m.chips.first?.jid, "2@s.whatsapp.net")
        XCTAssertEqual(m.result?.rows.count, 2)
    }
}

import XCTest
@testable import yawac

/// Fake LID resolver with a fixed mapping table.
private final class FakeLIDResolver: LIDResolving {
    var lidToPN: [String: String] = [:]
    var pnToLID: [String: String] = [:]

    func resolveLIDToPN(_ jid: String) -> String {
        lidToPN[jid] ?? jid
    }

    func resolvePNToLID(_ jid: String) -> String {
        pnToLID[jid] ?? jid
    }
}

final class JIDNormalizeTests: XCTestCase {

    // MARK: - bare

    func testBareStripsDeviceSuffix() {
        XCTAssertEqual(JIDNormalize.bare("123:5@s.whatsapp.net"),
                       "123@s.whatsapp.net")
        XCTAssertEqual(JIDNormalize.bare("123@lid"), "123@lid")
        XCTAssertEqual(JIDNormalize.bare("123@s.whatsapp.net"),
                       "123@s.whatsapp.net")
    }

    func testBareHandlesEmpty() {
        XCTAssertEqual(JIDNormalize.bare(""), "")
        XCTAssertEqual(JIDNormalize.bare("noatchar"), "noatchar")
    }

    // MARK: - canonical

    func testCanonicalNoClientLeavesLIDAlone() {
        XCTAssertEqual(JIDNormalize.canonical("123@lid", client: nil),
                       "123@lid")
    }

    func testCanonicalNonLIDPassesThrough() {
        XCTAssertEqual(JIDNormalize.canonical("123@s.whatsapp.net", client: nil),
                       "123@s.whatsapp.net")
    }

    func testCanonicalResolvesLIDWhenMapped() {
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        XCTAssertEqual(JIDNormalize.canonical("111@lid", client: r),
                       "555@s.whatsapp.net")
    }

    func testCanonicalStripsDeviceSuffixThenResolves() {
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        XCTAssertEqual(JIDNormalize.canonical("111:9@lid", client: r),
                       "555@s.whatsapp.net")
    }

    // MARK: - same

    func testSameIdenticalJIDs() {
        XCTAssertTrue(JIDNormalize.same(
            "123@s.whatsapp.net", "123@s.whatsapp.net", client: nil))
    }

    func testSameDeviceSuffixVariants() {
        XCTAssertTrue(JIDNormalize.same(
            "123:5@s.whatsapp.net", "123@s.whatsapp.net", client: nil))
        XCTAssertTrue(JIDNormalize.same(
            "123:5@s.whatsapp.net", "123:9@s.whatsapp.net", client: nil))
    }

    func testSameDifferentPeople() {
        XCTAssertFalse(JIDNormalize.same(
            "123@s.whatsapp.net", "456@s.whatsapp.net", client: nil))
        XCTAssertFalse(JIDNormalize.same(
            "111@lid", "222@lid", client: nil))
    }

    func testSameCrossNamespaceUnmappedReturnsFalse() {
        // Without a client / mapping, opposite-namespace JIDs are
        // conservatively treated as different people.
        XCTAssertFalse(JIDNormalize.same(
            "999@lid", "999@s.whatsapp.net", client: nil))
        XCTAssertFalse(JIDNormalize.same(
            "555@lid", "555@s.whatsapp.net", client: nil))
    }

    func testSameCrossNamespaceForwardMappingMatches() {
        // LID→PN mapping known; same person on both sides.
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        XCTAssertTrue(JIDNormalize.same(
            "111@lid", "555@s.whatsapp.net", client: r))
        XCTAssertTrue(JIDNormalize.same(
            "555@s.whatsapp.net", "111@lid", client: r))
    }

    func testSameCrossNamespaceReverseMappingMatches() {
        // Only PN→LID mapping known; canonical(PN) returns PN, canonical(LID)
        // returns LID (no forward mapping). The reverse branch must catch it.
        let r = FakeLIDResolver()
        r.pnToLID["555@s.whatsapp.net"] = "111@lid"
        XCTAssertTrue(JIDNormalize.same(
            "111@lid", "555@s.whatsapp.net", client: r))
        XCTAssertTrue(JIDNormalize.same(
            "555@s.whatsapp.net", "111@lid", client: r))
    }

    func testSameAcrossDeviceSuffixAndNamespace() {
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        XCTAssertTrue(JIDNormalize.same(
            "111:4@lid", "555:9@s.whatsapp.net", client: r))
    }

    // MARK: - key

    func testKeyIsCanonical() {
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        XCTAssertEqual(JIDNormalize.key("111@lid", client: r),
                       "555@s.whatsapp.net")
        XCTAssertEqual(JIDNormalize.key("111@lid", client: nil),
                       "111@lid")
    }

    // MARK: - allForms

    func testAllFormsNoClient() {
        XCTAssertEqual(JIDNormalize.allForms("111@lid", client: nil),
                       ["111@lid"])
        XCTAssertEqual(JIDNormalize.allForms("123:5@s.whatsapp.net",
                                             client: nil),
                       ["123@s.whatsapp.net"])
    }

    func testAllFormsWithForwardMapping() {
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        let forms = JIDNormalize.allForms("111@lid", client: r)
        // Canonical resolves to PN; reverse-mapping from canonical PN
        // back to LID may not be known, so the LID form is only included
        // when pnToLID has it. Without it, the canonical is what we use.
        XCTAssertTrue(forms.contains("555@s.whatsapp.net"))
        XCTAssertTrue(forms.contains("111@lid"))
    }

    func testAllFormsWithBothMappings() {
        let r = FakeLIDResolver()
        r.lidToPN["111@lid"] = "555@s.whatsapp.net"
        r.pnToLID["555@s.whatsapp.net"] = "111@lid"
        let lidForms = JIDNormalize.allForms("111@lid", client: r)
        let pnForms = JIDNormalize.allForms("555@s.whatsapp.net", client: r)
        XCTAssertEqual(lidForms, ["111@lid", "555@s.whatsapp.net"])
        XCTAssertEqual(pnForms, ["111@lid", "555@s.whatsapp.net"])
    }
}

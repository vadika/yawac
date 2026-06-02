import XCTest
@testable import yawac

@MainActor
final class LinkSubGroupSheetModelTests: XCTestCase {

    private let me = "me@s.whatsapp.net"

    func testCandidatesExcludeParentAndCommunityMembers() {
        let parent = "comm@g.us"
        let all: [BridgeGroupModel] = [
            .stub(jid: "linked-here@g.us", linkedParent: parent, amAdmin: true, meJID: me),
            .stub(jid: "other@g.us", amAdmin: true, meJID: me),
            .stub(jid: "non-admin@g.us", amAdmin: false, meJID: me),
            .stub(jid: "parent@g.us", isCommunityParent: true, amAdmin: true, meJID: me),
            .stub(jid: "linked-other@g.us",
                  linkedParent: "other-comm@g.us", amAdmin: true, meJID: me)
        ]
        let m = LinkSubGroupSheetModel(parentChatJID: parent,
                                       myJID: me,
                                       availableGroups: all,
                                       linker: StubLinker())
        let jids = m.candidates.map(\.jid)
        XCTAssertFalse(jids.contains("linked-here@g.us"))
        XCTAssertFalse(jids.contains("non-admin@g.us"))
        XCTAssertFalse(jids.contains("parent@g.us"))
        XCTAssertTrue(jids.contains("other@g.us"))
        XCTAssertTrue(jids.contains("linked-other@g.us"))
    }

    func testCrossCommunityCandidateRequiresConfirmation() {
        let all: [BridgeGroupModel] = [
            .stub(jid: "x@g.us", linkedParent: "other@g.us", amAdmin: true, meJID: me)
        ]
        let m = LinkSubGroupSheetModel(parentChatJID: "p@g.us",
                                       myJID: me,
                                       availableGroups: all,
                                       linker: StubLinker())
        m.selected = "x@g.us"
        XCTAssertTrue(m.needsCrossCommunityConfirmation)
    }

    func testSuccessfulLink() async {
        let linker = StubLinker()
        let m = LinkSubGroupSheetModel(
            parentChatJID: "p@g.us",
            myJID: me,
            availableGroups: [.stub(jid: "x@g.us", amAdmin: true, meJID: me)],
            linker: linker)
        m.selected = "x@g.us"
        await m.confirmLink()
        XCTAssertEqual(linker.lastParent, "p@g.us")
        XCTAssertEqual(linker.lastSub, "x@g.us")
        XCTAssertTrue(m.didLink)
        XCTAssertNil(m.error)
    }
}

final class StubLinker: SubGroupLinker, @unchecked Sendable {
    var lastParent: String?
    var lastSub: String?
    func linkSubGroup(parentJID: String, subJID: String) throws {
        lastParent = parentJID; lastSub = subJID
    }
}

extension BridgeGroupModel {
    /// Test-only factory. `meJID` becomes an admin participant when
    /// `amAdmin=true`, otherwise a non-admin. `isCommunityParent`
    /// maps onto `BridgeGroupModel.isParent`; `linkedParent` onto
    /// `linkedParentJID`. All other fields filled with inert defaults.
    static func stub(jid: String,
                     name: String = "stub",
                     isCommunityParent: Bool = false,
                     linkedParent: String? = nil,
                     amAdmin: Bool = false,
                     meJID: String = "me@s.whatsapp.net") -> BridgeGroupModel {
        let participants: [BridgeParticipantModel] = [
            BridgeParticipantModel(jid: meJID, isAdmin: amAdmin, isSuper: false)
        ]
        return BridgeGroupModel(
            jid: jid,
            name: name,
            topic: "",
            ownerJID: meJID,
            created: 0,
            participants: participants,
            isParent: isCommunityParent,
            linkedParentJID: linkedParent,
            isDefaultSubGroup: false,
            joinApprovalMode: false
        )
    }
}

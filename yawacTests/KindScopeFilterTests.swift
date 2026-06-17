import XCTest
@testable import yawac

final class KindScopeFilterTests: XCTestCase {

    func testDirectMatchesNonGroupNonCommunity() {
        let c = makeChat(jid: "1@s.whatsapp.net", isCommunityParent: false)
        XCTAssertTrue(KindScope.direct.matches(c))
        XCTAssertFalse(KindScope.groups.matches(c))
        XCTAssertFalse(KindScope.communities.matches(c))
    }

    func testGroupsMatchesGroup() {
        let c = makeChat(jid: "1@g.us", isCommunityParent: false)
        XCTAssertFalse(KindScope.direct.matches(c))
        XCTAssertTrue(KindScope.groups.matches(c))
        XCTAssertFalse(KindScope.communities.matches(c))
    }

    func testCommunitiesMatchesCommunityParent() {
        let c = makeChat(jid: "1@g.us", isCommunityParent: true)
        XCTAssertFalse(KindScope.direct.matches(c))
        XCTAssertFalse(KindScope.groups.matches(c))
        XCTAssertTrue(KindScope.communities.matches(c))
    }

    func testAllMatchesAnyChat() {
        let direct    = makeChat(jid: "1@s.whatsapp.net", isCommunityParent: false)
        let group     = makeChat(jid: "1@g.us", isCommunityParent: false)
        let community = makeChat(jid: "2@g.us", isCommunityParent: true)
        XCTAssertTrue(KindScope.all.matches(direct))
        XCTAssertTrue(KindScope.all.matches(group))
        XCTAssertTrue(KindScope.all.matches(community))
    }

    private func makeChat(jid: String, isCommunityParent: Bool) -> Chat {
        var c = Chat(jid: jid, name: jid, lastMessage: "", lastTimestamp: 0, unread: 0)
        c.isCommunityParent = isCommunityParent
        return c
    }
}

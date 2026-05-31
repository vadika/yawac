import XCTest
@testable import yawac

final class MentionEncodingTests: XCTestCase {

    private func encode(body: String,
                        mentions: [ConversationViewModel.ActiveMention],
                        allParticipants: [String] = []) -> (String, [String]) {
        ConversationViewModel.encodeMentions(
            body: body, mentions: mentions, allParticipants: allParticipants)
    }

    func testNoMentionsPassThrough() {
        let (out, jids) = encode(body: "hello", mentions: [])
        XCTAssertEqual(out, "hello")
        XCTAssertTrue(jids.isEmpty)
    }

    func testSingleMentionReplacedAndJIDCaptured() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "Natali", jid: "200347423354946@s.whatsapp.net")
        let (out, jids) = encode(body: "hi @Natali bye", mentions: [m])
        XCTAssertEqual(out, "hi @200347423354946 bye")
        XCTAssertEqual(jids, ["200347423354946@s.whatsapp.net"])
    }

    func testMissingNeedleDropsMention() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "Natali", jid: "200347423354946@s.whatsapp.net")
        let (out, jids) = encode(body: "hi @Natli bye", mentions: [m])
        XCTAssertEqual(out, "hi @Natli bye")
        XCTAssertTrue(jids.isEmpty)
    }

    func testMultipleMentionsBothReplaced() {
        let m1 = ConversationViewModel.ActiveMention(
            displayName: "Natali", jid: "1@s.whatsapp.net")
        let m2 = ConversationViewModel.ActiveMention(
            displayName: "Bob", jid: "2@s.whatsapp.net")
        let (out, jids) = encode(body: "hi @Natali and @Bob", mentions: [m1, m2])
        XCTAssertEqual(out, "hi @1 and @2")
        XCTAssertEqual(Set(jids), Set(["1@s.whatsapp.net", "2@s.whatsapp.net"]))
    }

    func testEveryoneSentinelExpandsToAllAndKeepsLiteral() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "everyone", jid: MentionPickerViewModel.everyoneSentinelJID)
        let (out, jids) = encode(
            body: "hello @everyone",
            mentions: [m],
            allParticipants: ["a@s.whatsapp.net", "b@s.whatsapp.net", "c@s.whatsapp.net"])
        XCTAssertEqual(out, "hello @everyone")
        XCTAssertEqual(Set(jids),
                       Set(["a@s.whatsapp.net", "b@s.whatsapp.net", "c@s.whatsapp.net"]))
    }

    func testEveryoneAndDirectMentionDedupe() {
        let everyone = ConversationViewModel.ActiveMention(
            displayName: "everyone", jid: MentionPickerViewModel.everyoneSentinelJID)
        let direct = ConversationViewModel.ActiveMention(
            displayName: "Bob", jid: "b@s.whatsapp.net")
        let (out, jids) = encode(
            body: "hi @Bob and @everyone",
            mentions: [direct, everyone],
            allParticipants: ["a@s.whatsapp.net", "b@s.whatsapp.net"])
        XCTAssertEqual(out, "hi @b and @everyone")
        XCTAssertEqual(Set(jids), Set(["a@s.whatsapp.net", "b@s.whatsapp.net"]))
    }

    func testLIDJIDStripsToLIDNumber() {
        let m = ConversationViewModel.ActiveMention(
            displayName: "Carol", jid: "987654@lid")
        let (out, jids) = encode(body: "hi @Carol", mentions: [m])
        XCTAssertEqual(out, "hi @987654")
        XCTAssertEqual(jids, ["987654@lid"])
    }
}

import XCTest
@testable import yawac

@MainActor
final class MediaSaveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func message(kind: String = "image", path: String?, filename: String? = nil) -> UIMessage {
        UIMessage(id: "media", chatJID: "chat", senderJID: "sender", fromMe: false, timestamp: .now,
                  body: .media(kind: kind, caption: nil, fileName: filename, localPath: path))
    }

    func testSavePreservesOriginalBytesAndCachedFileForEveryMediaKind() async throws {
        for (kind, ext) in [("image", "png"), ("video", "mp4"), ("audio", "ogg"), ("document", "pdf"), ("sticker", "webp")] {
            let source = directory.appendingPathComponent("cached.\(ext)")
            let destination = directory.appendingPathComponent("saved.\(ext)")
            let bytes = Data([0, 1, 255, 0, 128]) + Data(kind.utf8)
            try bytes.write(to: source)
            let row = MessageRow(message: message(kind: kind, path: source.path))

            try await row.saveMedia(to: destination)

            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(row.suggestedMediaFilename, source.lastPathComponent)
        }
    }

    func testSaveUsesDownloadedPathAndOriginalDocumentFilename() async throws {
        let source = directory.appendingPathComponent("cached-id.pdf")
        let destination = directory.appendingPathComponent("Report.pdf")
        try Data("document".utf8).write(to: source)
        let row = MessageRow(message: message(kind: "document", path: "/missing", filename: "../Report.pdf"),
                             localPath: source.path)
        XCTAssertEqual(row.suggestedMediaFilename, "Report.pdf")
        try await row.saveMedia(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("document".utf8))
    }

    func testSaveReplacesExistingDestinationWithoutChangingSource() async throws {
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("saved.mp4")
        try Data("new video".utf8).write(to: source)
        try Data("old video".utf8).write(to: destination)
        let row = MessageRow(message: message(kind: "video", path: source.path))

        try await row.saveMedia(to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new video".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new video".utf8))
    }

    func testSavingOverSourceOrItsSymlinkIsHarmless() async throws {
        let source = directory.appendingPathComponent("source.png")
        let alias = directory.appendingPathComponent("alias.png")
        try Data("original".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let row = MessageRow(message: message(path: source.path))
        try await row.saveMedia(to: source)
        try await row.saveMedia(to: alias)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: alias), Data("original".utf8))
    }

    func testUnavailableAndRestrictedMediaCannotOverwriteDestination() async throws {
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("saved.png")
        try Data("media".utf8).write(to: source)
        try Data("keep this".utf8).write(to: destination)
        let media = message(path: source.path)
        var viewOnce = media
        viewOnce.isViewOnce = true
        var consumed = media
        consumed.viewOnceLocked = true
        var revoked = media
        revoked.revokedAt = .now
        var deleted = media
        deleted.locallyDeleted = true
        for unavailable in [viewOnce, consumed, revoked, deleted, message(path: nil), message(path: "/missing")] {
            let row = MessageRow(message: unavailable)
            XCTAssertNil(row.suggestedMediaFilename)
            do {
                try await row.saveMedia(to: destination)
                XCTFail("Unavailable media must not be saved")
            } catch {
                XCTAssertEqual(try Data(contentsOf: destination), Data("keep this".utf8))
            }
        }
    }
}

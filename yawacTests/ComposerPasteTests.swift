import AppKit
import XCTest
@testable import yawac

@MainActor
final class ComposerPasteTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var temporaryURLs: [URL] = []

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs = []
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testPlainTextAndWebLinksRemainText() {
        pasteboard.setString("A message", forType: .string)
        XCTAssertTrue(ComposerView.attachmentURLs(from: pasteboard).isEmpty)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(string: "https://example.com/photo.png")!])
        XCTAssertTrue(ComposerView.attachmentURLs(from: pasteboard).isEmpty)
    }

    func testFilePastePreservesMultipleFilesAndTypes() {
        let urls = ["photo.png", "report.pdf", "clip.mp4", "recording.m4a"].map {
            FileManager.default.temporaryDirectory.appendingPathComponent($0)
        }
        pasteboard.writeObjects(urls as [NSURL])
        XCTAssertEqual(ComposerView.attachmentURLs(from: pasteboard), urls)
    }

    func testBrowserImageUsesBitmapInsteadOfSourceURL() throws {
        let item = NSPasteboardItem()
        item.setString("https://example.com/photo.png", forType: .URL)
        item.setData(try imageData(), forType: .png)
        pasteboard.writeObjects([item])

        temporaryURLs = ComposerView.attachmentURLs(from: pasteboard)
        let url = try XCTUnwrap(temporaryURLs.first)
        XCTAssertEqual(temporaryURLs.count, 1)
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: url))
        XCTAssertEqual(ConversationViewModel.attachmentKind(url), "image")
    }

    func testMultipleBitmapItemsAreAllStaged() throws {
        let data = try imageData()
        let items = (0..<2).map { _ in
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            return item
        }
        pasteboard.writeObjects(items)
        temporaryURLs = ComposerView.attachmentURLs(from: pasteboard)
        XCTAssertEqual(temporaryURLs.count, 2)
        XCTAssertEqual(Set(temporaryURLs).count, 2)
        XCTAssertTrue(temporaryURLs.allSatisfy { NSImage(contentsOf: $0) != nil })
    }

    func testTIFFClipboardImage() throws {
        let image = try XCTUnwrap(NSImage(data: imageData()))
        pasteboard.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        temporaryURLs = ComposerView.attachmentURLs(from: pasteboard)
        XCTAssertEqual(temporaryURLs.count, 1)
        XCTAssertTrue(temporaryURLs.allSatisfy { NSImage(contentsOf: $0) != nil })
    }

    func testMediaCopyRoundTripsOriginalFilesThroughComposerPaste() throws {
        for (ext, kind) in [("png", "image"), ("mp4", "video"), ("m4a", "audio"), ("pdf", "document")] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chat media \(UUID().uuidString).\(ext)")
            temporaryURLs.append(url)
            let data = kind == "image" ? try imageData() : Data("original \(kind)".utf8)
            try data.write(to: url)
            let row = MessageRow(message: mediaMessage(kind: kind, path: url.path))

            XCTAssertTrue(row.copyMedia(to: pasteboard))
            let pasted = ComposerView.attachmentURLs(from: pasteboard)
            XCTAssertEqual(pasted, [url])
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pasted.first)), data)
            XCTAssertEqual(ConversationViewModel.attachmentKind(url), kind)
        }
    }

    func testMediaCopyUsesNewlyDownloadedPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        temporaryURLs.append(url)
        try imageData().write(to: url)
        let row = MessageRow(message: mediaMessage(path: nil), localPath: url.path)
        XCTAssertTrue(row.copyMedia(to: pasteboard))
        XCTAssertEqual(ComposerView.attachmentURLs(from: pasteboard), [url])
    }

    func testUnavailableOrRestrictedMediaDoesNotReplaceClipboard() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        temporaryURLs.append(url)
        try imageData().write(to: url)
        let media = mediaMessage(path: url.path)
        var viewOnce = media
        viewOnce.isViewOnce = true
        var revoked = media
        revoked.revokedAt = .now
        var deleted = media
        deleted.locallyDeleted = true
        let missing = mediaMessage(path: url.appendingPathExtension("missing").path)
        pasteboard.setString("Keep this", forType: .string)
        for message in [viewOnce, revoked, deleted, missing, mediaMessage(path: nil)] {
            let row = MessageRow(message: message)
            XCTAssertNil(row.copyableMediaURL)
            XCTAssertFalse(row.copyMedia(to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "Keep this")
        }
    }

    private func mediaMessage(kind: String = "image", path: String?) -> UIMessage {
        UIMessage(id: "media", chatJID: "source@s.whatsapp.net",
                  senderJID: "sender@s.whatsapp.net", fromMe: false, timestamp: .now,
                  body: .media(kind: kind, caption: nil, fileName: nil, localPath: path))
    }

    private func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

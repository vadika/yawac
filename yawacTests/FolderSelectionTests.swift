import XCTest
@testable import yawac

final class FolderSelectionTests: XCTestCase {

    func testStorageKeyRoundTrip() {
        XCTAssertEqual(FolderSelection.all.storageValue, "")
        XCTAssertEqual(FolderSelection.archived.storageValue, "_archived")
        XCTAssertEqual(FolderSelection.custom(folderID: "abc").storageValue, "abc")
    }

    func testFromStorageValue() {
        XCTAssertEqual(FolderSelection(storageValue: ""), .all)
        XCTAssertEqual(FolderSelection(storageValue: "_archived"), .archived)
        XCTAssertEqual(FolderSelection(storageValue: "uuid-1234"),
                       .custom(folderID: "uuid-1234"))
    }

    func testFallbackForMissingFolderID() {
        // When the persisted folder id no longer exists in `validIDs`,
        // FolderSelection.resolved(...) collapses to .all.
        let knownIDs: Set<String> = ["folder-A", "folder-B"]
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "folder-A", knownIDs: knownIDs),
            .custom(folderID: "folder-A"))
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "missing-folder",
                                      knownIDs: knownIDs),
            .all)
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "_archived", knownIDs: knownIDs),
            .archived)
        XCTAssertEqual(
            FolderSelection.resolved(storageValue: "", knownIDs: knownIDs),
            .all)
    }
}

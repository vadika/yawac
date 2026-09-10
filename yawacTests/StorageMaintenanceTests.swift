import XCTest
import SQLite3
@testable import yawac

final class StorageMaintenanceTests: XCTestCase {
    func testPruneRollsBackChangesIfTransactionDeleteFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE ATRANSACTION (Z_PK INTEGER PRIMARY KEY, ZTIMESTAMP REAL);
            CREATE TABLE ACHANGE (ZTRANSACTIONID INTEGER);
            INSERT INTO ATRANSACTION VALUES (1, 0);
            INSERT INTO ACHANGE VALUES (1);
            CREATE TRIGGER reject_prune BEFORE DELETE ON ATRANSACTION BEGIN SELECT RAISE(ABORT, 'test failure'); END;
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try SwiftDataMaintenance.pruneHistory(at: url, keepDays: 7))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ACHANGE", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_prune", nil, nil, nil), SQLITE_OK)
        try SwiftDataMaintenance.pruneHistory(at: url, keepDays: 7)
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ACHANGE", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
    }
}

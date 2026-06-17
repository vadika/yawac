// yawacTests/GlobalHotkeyTests.swift
import XCTest
@testable import yawac

@MainActor
final class GlobalHotkeyTests: XCTestCase {

    func testRegisterUnregisterIsIdempotent() throws {
        let hk = GlobalHotkey()
        XCTAssertFalse(hk.isRegistered)

        hk.register { /* no-op for this test */ }
        XCTAssertTrue(hk.isRegistered)

        // Second register call is a no-op, not a crash.
        hk.register { }
        XCTAssertTrue(hk.isRegistered)

        hk.unregister()
        XCTAssertFalse(hk.isRegistered)

        // Second unregister is also a no-op.
        hk.unregister()
        XCTAssertFalse(hk.isRegistered)
    }

    func testConflictDoesNotCrashOrThrow() {
        // Two GlobalHotkey instances racing for the same shortcut.
        // The second one's register call must swallow eventHotKeyExistsErr
        // and report isRegistered == false.
        let first = GlobalHotkey()
        let second = GlobalHotkey()
        first.register { }
        second.register { }
        XCTAssertTrue(first.isRegistered)
        XCTAssertFalse(second.isRegistered)
        first.unregister()
        second.unregister()
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import yawac

@MainActor
final class BottomVisibilityTrackerTests: XCTestCase {
    @Observable
    final class State {
        var messages = ["first"]
        var visibleIDs: Set<String> = ["first"]
        var atBottom = false
        var appearances: [String: Int] = [:]
    }

    private struct Timeline: View {
        @Bindable var state: State

        var body: some View {
            VStack {
                ForEach(state.messages.filter { state.visibleIDs.contains($0) }, id: \.self) { id in
                    Text(id)
                        .onAppear { state.appearances[id, default: 0] += 1 }
                        .modifier(BottomVisibilityTracker(
                            messageID: id,
                            lastMessageID: { state.messages.last },
                            atBottom: $state.atBottom))
                }
            }
        }
    }

    func testAppendingAndReplacingLastMessageKeepsBottomVisible() async {
        let state = State()
        let host = NSHostingView(rootView: Timeline(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        await render(host)
        XCTAssertTrue(state.atBottom)
        XCTAssertEqual(state.appearances["first"], 1)

        state.messages.append("pending")
        state.visibleIDs.insert("pending")
        await render(host)
        XCTAssertTrue(state.atBottom)
        XCTAssertEqual(state.appearances["first"], 1, "Appending must preserve existing row identity")

        // Sending replaces the optimistic row with the server message ID.
        state.messages = ["first", "sent"]
        state.visibleIDs = ["first", "sent"]
        await render(host)
        XCTAssertTrue(state.atBottom)

        state.messages = ["first"]
        state.visibleIDs = ["first"]
        await render(host)
        XCTAssertTrue(state.atBottom)
    }

    func testLeavingAndReturningToLatestMessageUpdatesButton() async {
        let state = State()
        state.messages = ["first", "last"]
        state.visibleIDs = ["first", "last"]
        let host = NSHostingView(rootView: Timeline(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        await render(host)
        XCTAssertTrue(state.atBottom)

        state.visibleIDs = ["first"]
        await render(host)
        XCTAssertFalse(state.atBottom)

        state.messages.append("new")
        await render(host)
        XCTAssertFalse(state.atBottom)

        state.visibleIDs = ["last", "new"]
        await render(host)
        XCTAssertTrue(state.atBottom)
    }

    private func render(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
    }
}

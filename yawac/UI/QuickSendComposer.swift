// yawac/UI/QuickSendComposer.swift
import SwiftUI

/// Composer for the menu-bar quick-send popover. The send logic is
/// factored into a static `attemptSend` so it can be unit-tested
/// without a real `WAClient` / Go bridge.
struct QuickSendComposer: View {

    let chatJID: String
    let displayName: String
    let send: @Sendable (String, String) async throws -> Void
    let onClose: () -> Void
    let onBack: () -> Void

    @State private var draft: String = ""
    @State private var sending: Bool = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    /// Pure: returns `true` iff the draft has at least one
    /// non-whitespace character.
    static func canSend(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum SendOutcome: Equatable {
        case success
        case failure(String)
    }

    /// Pure-async send driver. Calls `sender(chatJID, draft)`; on
    /// success invokes `onClose`. Returns the outcome so the test can
    /// assert on it without spinning the SwiftUI runtime.
    static func attemptSend(
        chatJID: String,
        draft: String,
        sender: @Sendable (String, String) async throws -> Void,
        onClose: () -> Void
    ) async -> SendOutcome {
        guard canSend(draft: draft) else { return .failure("empty draft") }
        do {
            try await sender(chatJID, draft)
            onClose()
            return .success
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return .failure(msg)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField("Message \(displayName)…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { trigger() }
                .disabled(sending)
                .padding(.horizontal, 10)

            if let error {
                Text(error)
                    .scaledUI(11)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
            }

            HStack {
                Spacer()
                Button {
                    trigger()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .scaledIcon(11, weight: .semibold)
                        Text("Send")
                            .scaledUI(12)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!Self.canSend(draft: draft) || sending)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .scaledIcon(12, weight: .semibold)
            }
            .buttonStyle(.plain)
            Text(displayName)
                .scaledUI(12, weight: .semibold)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func trigger() {
        guard Self.canSend(draft: draft), !sending else { return }
        sending = true
        error = nil
        let snapshot = draft
        Task {
            let outcome = await Self.attemptSend(
                chatJID: chatJID,
                draft: snapshot,
                sender: { jid, body in try await send(jid, body) },
                onClose: onClose)
            switch outcome {
            case .success:
                draft = ""
                sending = false
            case .failure(let msg):
                sending = false
                error = msg
                // Auto-clear the error banner after 4s.
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if self.error == msg { self.error = nil }
                }
            }
        }
    }
}

import SwiftUI

struct PollComposerView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var options: [String] = ["", ""]
    @State private var allowMultiple: Bool = false
    @State private var sending: Bool = false

    private static let questionCap = 255
    private static let optionCap = 100
    private static let maxOptions = 12
    private static let minOptions = 2

    private var trimmedOptions: [String] {
        options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trimmedOptions.count >= Self.minOptions
            && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New poll")
                .font(.title3).bold()
            questionField
            optionsList
            Toggle("Allow multiple answers", isOn: $allowMultiple)
                .toggleStyle(.switch)
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: options) { _, _ in autoGrow() }
        .onChange(of: question) { _, new in
            if new.count > Self.questionCap {
                question = String(new.prefix(Self.questionCap))
            }
        }
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Question").font(.caption).foregroundStyle(.secondary)
            TextField("Ask something…", text: $question, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            Text("\(question.count)/\(Self.questionCap)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options").font(.caption).foregroundStyle(.secondary)
            ForEach(options.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("Option \(i + 1)",
                              text: Binding(
                                get: { options[i] },
                                set: { newVal in
                                    options[i] = String(newVal.prefix(Self.optionCap))
                                }))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        removeOption(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(options.count <= Self.minOptions)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(sending ? "Sending…" : "Create") {
                send()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
    }

    private func autoGrow() {
        guard options.count < Self.maxOptions else { return }
        let last = options.last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !last.isEmpty {
            options.append("")
        }
    }

    private func removeOption(at index: Int) {
        guard options.count > Self.minOptions,
              options.indices.contains(index) else { return }
        options.remove(at: index)
    }

    private func send() {
        let qSnap = question
        let optsSnap = options
        let multiSnap = allowMultiple
        sending = true
        Task {
            await vm.sendPoll(question: qSnap,
                              options: optsSnap,
                              allowMultiple: multiSnap)
            sending = false
            if vm.transientError == nil {
                dismiss()
            }
        }
    }
}

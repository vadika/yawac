import SwiftUI

/// Modal sheet presenting two `DatePicker`s (From / To) used by the
/// search filter chips' "Custom…" date option. Apply is disabled
/// when `from > to` — the only other validity check the filter
/// SQL has to honour.
struct DateRangeSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Initial values in seconds-since-reference-date (matches the
    /// `MessageIndex.SearchFilters.fromTimestamp` shape).
    let initialFrom: Int64?
    let initialTo:   Int64?
    let onApply: (_ fromTs: Int64?, _ toTs: Int64?) -> Void

    @State private var fromDate: Date
    @State private var toDate:   Date

    init(initialFrom: Int64?, initialTo: Int64?,
         onApply: @escaping (_ fromTs: Int64?, _ toTs: Int64?) -> Void) {
        self.initialFrom = initialFrom
        self.initialTo   = initialTo
        self.onApply     = onApply
        let now = Date()
        let defaultFrom = now.addingTimeInterval(-30 * 86_400)
        self._fromDate = State(initialValue: initialFrom.map {
            Date(timeIntervalSinceReferenceDate: TimeInterval($0))
        } ?? defaultFrom)
        self._toDate = State(initialValue: initialTo.map {
            Date(timeIntervalSinceReferenceDate: TimeInterval($0))
        } ?? now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Date range")
                .scaledUI(15, weight: .semibold)
                .foregroundStyle(Theme.text)

            DatePicker("From", selection: $fromDate, displayedComponents: .date)
                .datePickerStyle(.compact)
            DatePicker("To",   selection: $toDate,   displayedComponents: .date)
                .datePickerStyle(.compact)

            if fromDate > toDate {
                Text("From date must be on or before To date.")
                    .scaledUI(11)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Apply") {
                    onApply(
                        Int64(fromDate.timeIntervalSinceReferenceDate),
                        Int64(toDate.timeIntervalSinceReferenceDate))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fromDate > toDate)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

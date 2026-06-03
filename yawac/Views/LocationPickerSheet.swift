import SwiftUI
import MapKit

struct LocationPickerSheet: View {
    @Bindable var model: LocationPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: (LocationPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send location").font(.headline)

            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.query) { _, _ in
                    model.onQueryChange()
                }

            if !model.searchResults.isEmpty {
                List(model.searchResults, id: \.self) { item in
                    Button {
                        model.pickResult(item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unnamed")
                                .scaledUI(13)
                            if let addr = item.placemark.title {
                                Text(addr)
                                    .foregroundStyle(.secondary)
                                    .scaledUI(11)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 120)
            }

            Map(coordinateRegion: $model.region,
                interactionModes: [.pan, .zoom],
                annotationItems: [SelectedPin(coord: model.selectedCoord)]) { pin in
                MapAnnotation(coordinate: pin.coord) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 220)

            VStack(alignment: .leading, spacing: 2) {
                if !model.resolvedName.isEmpty {
                    Text(model.resolvedName).scaledUI(13)
                }
                if !model.resolvedAddress.isEmpty {
                    Text(model.resolvedAddress)
                        .foregroundStyle(.secondary).scaledUI(11)
                }
            }

            if model.permissionDenied {
                Text("Location access denied — open System Settings → Privacy & Security → Location Services.")
                    .foregroundStyle(.orange)
                    .scaledUI(11)
            }

            if let err = model.error {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }

            HStack {
                Button("Use current location") {
                    Task { await model.useCurrentLocation() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send") {
                    onSend(model.buildPayload())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct SelectedPin: Identifiable {
    let coord: CLLocationCoordinate2D
    var id: String { "\(coord.latitude),\(coord.longitude)" }
}

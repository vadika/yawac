import SwiftUI
import MapKit

struct LocationPickerSheet: View {
    @Bindable var model: LocationPickerSheetModel
    @Environment(\.dismiss) private var dismiss
    var onSend: (LocationPayload) -> Void

    @State private var camera: MapCameraPosition = .automatic

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
                        camera = .region(model.region)
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

            // F103: new Map(position:) API + MapReader. The legacy
            // Map(coordinateRegion:annotationItems:) exposes no per-pin
            // drag; this version uses a DragGesture(minimumDistance: 0)
            // over the whole map to convert any click/release point to
            // a coordinate via the proxy. The pin re-anchors because
            // it reads model.selectedCoord on every body eval.
            MapReader { proxy in
                Map(position: $camera) {
                    Annotation("", coordinate: model.selectedCoord) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.red)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            if let coord = proxy.convert(value.location, from: .local) {
                                model.onPinDrag(to: coord)
                            }
                        }
                )
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
                    Task {
                        await model.useCurrentLocation()
                        camera = .region(model.region)
                    }
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
        .onAppear { camera = .region(model.region) }
    }
}

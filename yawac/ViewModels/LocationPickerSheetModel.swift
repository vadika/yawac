import Foundation
import CoreLocation
import MapKit
import Observation

/// Drives the "share a location" composer sheet.
///
/// Holds the map region, the currently picked coordinate, the resolved
/// name/address, search results from `MKLocalSearch`, and the
/// permission-denied gate for "use my current location". Search and
/// reverse-geocode are debounced (250ms) so a quick query or pin drag
/// does not spam MapKit/CoreLocation. The fallback center is Helsinki
/// (60.17, 24.94); it is replaced by the user's location once
/// `useCurrentLocation()` resolves a fix.
@MainActor
@Observable
final class LocationPickerSheetModel {

    // Fallback center: Helsinki (60.17, 24.94). Replaced by user
    // location once permission is granted and a fix arrives.
    var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 60.17, longitude: 24.94),
        latitudinalMeters: 5000, longitudinalMeters: 5000)
    var selectedCoord: CLLocationCoordinate2D =
        CLLocationCoordinate2D(latitude: 60.17, longitude: 24.94)

    var query: String = ""
    var searchResults: [MKMapItem] = []
    var resolvedName: String = ""
    var resolvedAddress: String = ""
    var permissionDenied: Bool = false
    var inFlight: Bool = false
    var error: String?

    @ObservationIgnored private var searchDebounce: Task<Void, Never>?
    @ObservationIgnored private var geocodeDebounce: Task<Void, Never>?
    @ObservationIgnored private lazy var locationManager: CLLocationManager = {
        CLLocationManager()
    }()
    @ObservationIgnored private lazy var geocoder = CLGeocoder()

    func updateCoord(lat: Double, lng: Double, name: String, address: String) {
        selectedCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        resolvedName = name
        resolvedAddress = address
    }

    func onQueryChange() {
        searchDebounce?.cancel()
        let snapshotQuery = query
        let snapshotRegion = region
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard !snapshotQuery.isEmpty else {
                self?.searchResults = []
                return
            }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = snapshotQuery
            req.region = snapshotRegion
            do {
                let result = try await MKLocalSearch(request: req).start()
                if Task.isCancelled { return }
                self?.searchResults = result.mapItems
            } catch {
                self?.searchResults = []
            }
        }
    }

    func pickResult(_ item: MKMapItem) {
        let placemark = item.placemark
        let coord = placemark.coordinate
        let name = item.name ?? ""
        let address = [
            placemark.thoroughfare, placemark.locality,
            placemark.administrativeArea, placemark.country
        ].compactMap { $0 }.joined(separator: ", ")
        updateCoord(lat: coord.latitude, lng: coord.longitude,
                    name: name, address: address)
        region = MKCoordinateRegion(
            center: coord,
            latitudinalMeters: 2000, longitudinalMeters: 2000)
    }

    func useCurrentLocation() async {
        let status = locationManager.authorizationStatus
        if status == .denied || status == .restricted {
            permissionDenied = true
            return
        }
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            // Wait briefly for the permission prompt to resolve. CoreLocation
            // delivers the authorization decision asynchronously; reading
            // `.authorizationStatus` again immediately after the request
            // returns the stale value.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if locationManager.authorizationStatus != .notDetermined { break }
            }
        }
        let status2 = locationManager.authorizationStatus
        if status2 == .denied || status2 == .restricted {
            permissionDenied = true
            return
        }
        // Kick off a one-shot fix. `locationManager.location` is nil until
        // the manager has had a chance to deliver a fix — a single sync
        // read on first tap always returns nil and the map never moves.
        // Start updates, poll up to ~3s for a coordinate, then stop.
        locationManager.startUpdatingLocation()
        defer { locationManager.stopUpdatingLocation() }
        for _ in 0..<15 {
            if let loc = locationManager.location {
                let coord = loc.coordinate
                region = MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 1000, longitudinalMeters: 1000)
                selectedCoord = coord
                error = nil
                await reverseGeocode(coord: coord)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        error = "Couldn't get current location — try again."
    }

    func onPinDrag(to coord: CLLocationCoordinate2D) {
        selectedCoord = coord
        geocodeDebounce?.cancel()
        geocodeDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.reverseGeocode(coord: coord)
        }
    }

    func reverseGeocode(coord: CLLocationCoordinate2D) async {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coord.latitude,
                           longitude: coord.longitude))
            if let p = placemarks.first {
                resolvedName = p.name ?? ""
                resolvedAddress = [
                    p.thoroughfare, p.locality,
                    p.administrativeArea, p.country
                ].compactMap { $0 }.joined(separator: ", ")
            }
        } catch {
            resolvedName = ""
            resolvedAddress = ""
        }
    }

    func buildPayload() -> LocationPayload {
        return LocationPayload(
            lat: selectedCoord.latitude,
            lng: selectedCoord.longitude,
            name: resolvedName,
            address: resolvedAddress)
    }
}

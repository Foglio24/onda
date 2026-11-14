import CoreLocation

/// The device's approximate position, for the concerts near it under the classic player. It is
/// asked for only when the user taps to see them (when in use, reduced accuracy: a few kilometres),
/// fixed once and again after an hour at most while the card is shown, kept in memory and never
/// sent anywhere: the concerts are compared with it on the device.
@MainActor
final class NearbyLocation: NSObject, ObservableObject {
    static let shared = NearbyLocation()

    @Published private(set) var status: CLAuthorizationStatus
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager: CLLocationManager
    private var fixedAt: Date?
    private var locating = false

    private override init() {
        let manager = CLLocationManager()
        self.manager = manager
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    /// The system hasn't asked yet: the card offers to show the concerts near.
    var canAsk: Bool { status == .notDetermined }

    /// The card's button: the system's question the first time, then the position.
    func request() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            refresh()
        }
    }

    /// A position when there is none or it's over an hour old. Only once allowed: it never asks.
    func refresh() {
        guard isAllowed, !locating else { return }
        if coordinate != nil, let fixedAt, Date().timeIntervalSince(fixedAt) < 3600 { return }
        locating = true
        manager.requestLocation()
    }
}

extension NearbyLocation: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != self.status else { return }
            self.status = status
            if self.isAllowed {
                self.refresh()
            } else {
                self.coordinate = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
        Task { @MainActor in
            self.locating = false
            self.coordinate = coordinate
            self.fixedAt = Date()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locating = false }
    }
}

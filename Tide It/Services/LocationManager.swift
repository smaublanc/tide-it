import Foundation
import CoreLocation
import os.log

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    private var locationTimeoutTask: Task<Void, Never>?
    private let timeoutSeconds: UInt64 = 15

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        // Only auto-request if already authorized (don't trigger system prompt at launch)
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            startTimeout()
        }
    }

    deinit {
        locationTimeoutTask?.cancel()
        manager.stopUpdatingLocation()
    }

    /// Explicitly request location authorization (call from onboarding or user action)
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Demande une mise à jour de la localisation à la demande (ex: bouton GPS sur la carte).
    /// Si l'utilisateur n'a pas encore autorisé, demande l'autorisation.
    func requestLocationUpdate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            startTimeout()
        case .denied, .restricted:
            appLogger.info("LocationManager: autorisation refusée, impossible de centrer")
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            startTimeout()
        default:
            manager.stopUpdatingLocation()
            cancelTimeout()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.first
        manager.stopUpdatingLocation()
        cancelTimeout()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLogger.error("LocationManager error: \(error.localizedDescription)")
        manager.stopUpdatingLocation()
        cancelTimeout()
    }

    private func startTimeout() {
        cancelTimeout()
        locationTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            manager.stopUpdatingLocation()
        }
    }

    private func cancelTimeout() {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
    }
}

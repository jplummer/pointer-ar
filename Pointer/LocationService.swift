@preconcurrency import CoreLocation
import Foundation

/// When-in-use location for bearing math (Step 4). Starts updates after authorization.
///
/// `CLLocationManager` callbacks are delivered on a system queue; we hop to the main actor with `Task`.
/// `LocationService` is `@MainActor`-isolated; `@unchecked Sendable` matches that handoff and silences
/// incorrect default `Sendable` diagnostics when Core Location types appear in `@Sendable` closures.
@MainActor
final class LocationService: NSObject, ObservableObject, @unchecked Sendable {
  @Published private(set) var authorizationStatus: CLAuthorizationStatus
  @Published private(set) var lastLocation: CLLocation?
  @Published private(set) var lastError: Error?
  @Published private(set) var lastHeading: CLHeading?

  private let manager = CLLocationManager()

  override init() {
    authorizationStatus = CLLocationManager().authorizationStatus
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.distanceFilter = 5
  }

  /// Request authorization if needed, then start continuous updates when allowed.
  func begin() {
    authorizationStatus = manager.authorizationStatus
    switch authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      manager.startUpdatingLocation()
      manager.startUpdatingHeading()
    default:
      break
    }
  }

  func stop() {
    manager.stopUpdatingLocation()
    manager.stopUpdatingHeading()
  }

  var isAuthorized: Bool {
    authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
  }
}

extension LocationService: CLLocationManagerDelegate {
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.authorizationStatus = status
      switch status {
      case .authorizedAlways, .authorizedWhenInUse:
        self.manager.startUpdatingLocation()
        self.manager.startUpdatingHeading()
      default:
        break
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let fix = locations.last else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.lastLocation = fix
      self.lastError = nil
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    Task { @MainActor [weak self] in
      self?.lastHeading = newHeading
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor [weak self] in
      self?.lastError = error
    }
  }
}

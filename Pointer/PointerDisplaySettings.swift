import CoreLocation
import Foundation
import SwiftUI
import simd

private enum PointerDisplayKeys {
  static let arrow = "pointer.overlay.showArrow"
  static let azDisk = "pointer.overlay.showAzimuthDisk"
  static let azNumber = "pointer.overlay.showAzimuthNumber"
  static let elNumber = "pointer.overlay.showElevationNumber"
}

/// User-toggled on-screen overlay elements (persisted in `UserDefaults`).
final class PointerDisplaySettings: ObservableObject {

  var showArrow: Bool {
    willSet { objectWillChange.send() }
    didSet { UserDefaults.standard.set(showArrow, forKey: PointerDisplayKeys.arrow) }
  }

  var showAzimuthDisk: Bool {
    willSet { objectWillChange.send() }
    didSet { UserDefaults.standard.set(showAzimuthDisk, forKey: PointerDisplayKeys.azDisk) }
  }

  var showAzimuthNumber: Bool {
    willSet { objectWillChange.send() }
    didSet { UserDefaults.standard.set(showAzimuthNumber, forKey: PointerDisplayKeys.azNumber) }
  }

  var showElevationNumber: Bool {
    willSet { objectWillChange.send() }
    didSet { UserDefaults.standard.set(showElevationNumber, forKey: PointerDisplayKeys.elNumber) }
  }

  init() {
    let d = UserDefaults.standard
    showArrow = (d.object(forKey: PointerDisplayKeys.arrow) as? Bool) ?? true
    showAzimuthDisk = (d.object(forKey: PointerDisplayKeys.azDisk) as? Bool) ?? true
    showAzimuthNumber = (d.object(forKey: PointerDisplayKeys.azNumber) as? Bool) ?? true
    showElevationNumber = (d.object(forKey: PointerDisplayKeys.elNumber) as? Bool) ?? true
  }
}

/// Horizontal **azimuth** (degrees clockwise from true north, 0…360) and **elevation** (degrees above horizon), matching overlay geometry.
enum AimHorizonAngles {

  static func azimuthElevationDegrees(
    aimMode: AimSession.AimMode,
    userCoordinate: CLLocationCoordinate2D?,
    aimInstant: Date,
    satelliteENU: simd_float3?,
    ellipsoidHeightMeters: Double
  ) -> (azimuthDeg: Double, elevationDeg: Double)? {
    guard let obs = userCoordinate else { return nil }
    switch aimMode {
    case .ground(let target):
      let dest = CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude)
      let origin = CLLocation(latitude: obs.latitude, longitude: obs.longitude)
      let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
      guard origin.distance(from: destLoc) >= 3,
            let d = Geodesy.trueNorthENUChordUnit(from: obs, to: dest)
      else { return nil }
      return azEl(fromENU: d)

    case .celestial(let target):
      switch target.kind {
      case .satellite:
        guard let d = satelliteENU else { return nil }
        return azEl(fromENU: d)

      case .magnetic_north:
        guard let d = TopocentricAstronomy.enuForCelestialCatalog(
          target,
          observer: obs,
          at: aimInstant,
          ellipsoidHeightMeters: ellipsoidHeightMeters
        ) else { return nil }
        return azEl(fromENU: d)

      case .sun, .moon, .planet, .fixed_star:
        if let h = TopocentricAstronomy.apparentHorizontalDegrees(
          target: target,
          observer: obs,
          at: aimInstant,
          ellipsoidHeightMeters: ellipsoidHeightMeters
        ) {
          return (normalizeAzimuthDegrees(h.azimuthDeg), h.altitudeDeg)
        }
        guard let d = TopocentricAstronomy.enuForCelestialCatalog(
          target,
          observer: obs,
          at: aimInstant,
          ellipsoidHeightMeters: ellipsoidHeightMeters
        ) else { return nil }
        return azEl(fromENU: d)
      }
    }
  }

  private static func azEl(fromENU d: simd_float3) -> (Double, Double) {
    let u = Double(d.z)
    let uClamped = min(1, max(-1, u))
    let el = asin(uClamped) * 180 / .pi
    let az = normalizeAzimuthDegrees(atan2(Double(d.y), Double(d.x)) * 180 / .pi)
    return (az, el)
  }

  private static func normalizeAzimuthDegrees(_ deg: Double) -> Double {
    var a = deg.truncatingRemainder(dividingBy: 360)
    if a < 0 { a += 360 }
    return a
  }
}

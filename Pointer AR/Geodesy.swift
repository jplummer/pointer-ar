import CoreLocation
import simd

enum Geodesy {
  // WGS84 (EPSG:4978) — geodetic → ECEF meters.
  private static let wgs84A = 6_378_137.0
  private static let wgs84E2 = 6.69437999014e-3

  /// ECEF position on the reference ellipsoid (`height` meters above ellipsoid).
  static func ecefMeters(latitude: Double, longitude: Double, heightAboveEllipsoid: Double = 0) -> simd_double3 {
    let φ = latitude * .pi / 180
    let λ = longitude * .pi / 180
    let sinφ = sin(φ)
    let cosφ = cos(φ)
    let cosλ = cos(λ)
    let sinλ = sin(λ)
    let N = Self.wgs84A / sqrt(1 - Self.wgs84E2 * sinφ * sinφ)
    let h = heightAboveEllipsoid
    let x = (N + h) * cosφ * cosλ
    let y = (N + h) * cosφ * sinλ
    let z = (N * (1 - Self.wgs84E2) + h) * sinφ
    return simd_double3(x, y, z)
  }

  /// Straight-line direction from `from` to `to` on the ellipsoid, in Core Motion **xTrueNorthZVertical** axes:
  /// **+X** true north, **+Y** east, **+Z** up (local tangent plane at `from`).
  ///
  /// Unlike using initial bearing in the horizontal plane only, this follows the **3D chord** in ECEF projected into local ENU,
  /// so distant targets pick up a small **nadir** (down) component — the arrow “dips” toward the horizon for far-off places.
  /// Returns `nil` when separation is negligible.
  static func trueNorthENUChordUnit(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> simd_float3? {
    let a = ecefMeters(latitude: from.latitude, longitude: from.longitude)
    let b = ecefMeters(latitude: to.latitude, longitude: to.longitude)
    let d = b - a
    let separation = simd_length(d)
    guard separation > 0.5 else { return nil }

    let φ = from.latitude * .pi / 180
    let λ = from.longitude * .pi / 180
    let sinφ = sin(φ)
    let cosφ = cos(φ)
    let sinλ = sin(λ)
    let cosλ = cos(λ)

    let east = -sinλ * d.x + cosλ * d.y
    let north = -sinφ * cosλ * d.x - sinφ * sinλ * d.y + cosφ * d.z
    let up = cosφ * cosλ * d.x + cosφ * sinλ * d.y + sinφ * d.z

    let v = simd_float3(Float(north), Float(east), Float(up))
    let len = simd_length(v)
    guard len > 1e-12 else { return nil }
    return simd_normalize(v)
  }

  /// Initial (forward) azimuth from `from` to `to`, degrees clockwise from true north (0…360).
  static func initialBearingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let φ1 = from.latitude * .pi / 180
    let φ2 = to.latitude * .pi / 180
    let Δλ = (to.longitude - from.longitude) * .pi / 180
    let y = sin(Δλ) * cos(φ2)
    let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
    let θ = atan2(y, x)
    let deg = θ * 180 / .pi
    return (deg + 360).truncatingRemainder(dividingBy: 360)
  }
}

import CoreLocation
import Foundation
import simd

/// Observer-centered horizontal and ENU directions for celestial targets.
/// Sun: simplified geocentric apparent equatorial (~Meeus). Fixed stars: catalog RA/Dec.
/// All azimuths are **clockwise from true north**; altitude is elevation above mathematical horizon (refraction omitted).
enum TopocentricAstronomy {

  /// Unit direction in Core Motion **xTrueNorthZVertical**: +X north, +Y east, +Z up.
  static func enuTowardCelestial(
    raRad: Double,
    decRad: Double,
    observer: CLLocationCoordinate2D,
    at date: Date
  ) -> simd_float3? {
    let jd = julianDayUTC(date)
    let lst = localSiderealTimeRadians(julianDay: jd, longitudeRad: observer.longitude * .pi / 180)
    let lat = Float(observer.latitude * .pi / 180)
    let (alt, az) = altitudeAzimuthRadians(raRad: raRad, decRad: decRad, latitudeRad: lat, lstRad: lst)
    return enuFromAltitudeAzimuthTrueNorth(altitudeRad: alt, azimuthFromNorthRad: az)
  }

  /// Low-precision apparent geocentric Sun (degrees ~arcminute class for testing).
  static func sunGeocentricRADecRadians(julianDay: Double) -> (Double, Double) {
    let n = julianDay - 2_451_545.0
    let T = n / 36_525.0
    let L = revDeg(280.460 + 0.985_647_4 * n)
    let g = revDeg(357.528 + 0.985_600_3 * n)
    let lambda = revDeg(L + 1.915 * sinDeg(g) + 0.020 * sinDeg(2 * g))
    let eps =
      23.4392911111 - 0.013004167 * T - 0.000000163 * T * T + 0.000000504 * T * T * T
    let ra = atan2(cosDeg(eps) * sinDeg(lambda), cosDeg(lambda))
    let dec = asin(min(1, max(-1, sinDeg(eps) * sinDeg(lambda))))
    return (ra, dec)
  }

  static func enuForCelestialCatalog(
    _ target: CelestialTarget,
    observer: CLLocationCoordinate2D,
    at date: Date,
    ellipsoidHeightMeters: Double = 0
  ) -> simd_float3? {
    switch target.kind {
    case .sun:
      let jd = julianDayUTC(date)
      let (ra, dec) = sunGeocentricRADecRadians(julianDay: jd)
      return enuTowardCelestial(raRad: ra, decRad: dec, observer: observer, at: date)
    case .moon:
      let jd = julianDayUTC(date)
      let (ra, dec) = LunarEphemeris.moonGeocentricRADecRadians(julianDay: jd)
      return enuTowardCelestial(raRad: ra, decRad: dec, observer: observer, at: date)
    case .fixed_star:
      guard let h = target.raHours, let d = target.decDegrees else { return nil }
      let ra = h * .pi / 12
      let dec = d * .pi / 180
      return enuTowardCelestial(raRad: ra, decRad: dec, observer: observer, at: date)
    case .magnetic_north:
      return WorldMagneticModel.fieldDirectionENUUnit(
        latitudeDeg: observer.latitude,
        longitudeDeg: observer.longitude,
        heightKilometers: ellipsoidHeightMeters / 1000,
        at: date
      )
    case .satellite:
      return nil
    }
  }

  /// Altitude / azimuth (degrees, azimuth 0…360 from north through east) for details UI.
  static func apparentHorizontalDegrees(
    target: CelestialTarget,
    observer: CLLocationCoordinate2D,
    at date: Date,
    ellipsoidHeightMeters: Double = 0
  ) -> (altitudeDeg: Double, azimuthDeg: Double)? {
    let ra: Double
    let dec: Double
    let jd = julianDayUTC(date)
    switch target.kind {
    case .sun:
      (ra, dec) = sunGeocentricRADecRadians(julianDay: jd)
    case .moon:
      (ra, dec) = LunarEphemeris.moonGeocentricRADecRadians(julianDay: jd)
    case .fixed_star:
      guard let h = target.raHours, let d = target.decDegrees else { return nil }
      ra = h * .pi / 12
      dec = d * .pi / 180
    case .magnetic_north:
      return nil
    case .satellite:
      return nil
    }
    let lst = localSiderealTimeRadians(julianDay: jd, longitudeRad: observer.longitude * .pi / 180)
    let lat = Float(observer.latitude * .pi / 180)
    let (alt, az) = altitudeAzimuthRadians(raRad: ra, decRad: dec, latitudeRad: lat, lstRad: lst)
    var azDeg = Double(az) * 180 / .pi
    if azDeg < 0 { azDeg += 360 }
    return (Double(alt) * 180 / .pi, azDeg)
  }

  // MARK: - Internals

  static func julianDayUTC(_ date: Date) -> Double {
    date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
  }

  /// Greenwich mean sidereal time at JD (radians).
  static func greenwichMeanSiderealTimeRadians(julianDay: Double) -> Double {
    let t = (julianDay - 2_451_545.0) / 36_525.0
    let theta0 =
      280.46061837
        + 360.98564736629 * (julianDay - 2_451_545.0)
        + 0.000387933 * t * t
        - t * t * t / 38_710_000.0
    return revDeg(theta0) * .pi / 180
  }

  static func localSiderealTimeRadians(julianDay: Double, longitudeRad: Double) -> Double {
    greenwichMeanSiderealTimeRadians(julianDay: julianDay) + longitudeRad
  }

  /// Altitude (radians), azimuth clockwise from true north (radians).
  static func altitudeAzimuthRadians(
    raRad: Double,
    decRad: Double,
    latitudeRad: Float,
    lstRad: Double
  ) -> (Float, Float) {
    let ha = normalizeAngleRadians(lstRad - raRad)
    let lat = Double(latitudeRad)
    let sinAlt = sin(lat) * sin(decRad) + cos(lat) * cos(decRad) * cos(ha)
    let alt = asin(max(-1, min(1, sinAlt)))
    let y = -sin(ha) * cos(decRad)
    let x = cos(lat) * sin(decRad) - sin(lat) * cos(decRad) * cos(ha)
    let az = atan2(y, x)
    return (Float(alt), Float(az))
  }

  static func enuFromAltitudeAzimuthTrueNorth(altitudeRad: Float, azimuthFromNorthRad: Float) -> simd_float3 {
    let cAlt = cos(altitudeRad)
    let n = cAlt * cos(azimuthFromNorthRad)
    let e = cAlt * sin(azimuthFromNorthRad)
    let u = sin(altitudeRad)
    return simd_normalize(simd_float3(n, e, u))
  }

  private static func revDeg(_ x: Double) -> Double {
    var y = x.truncatingRemainder(dividingBy: 360)
    if y < 0 { y += 360 }
    return y
  }

  private static func sinDeg(_ d: Double) -> Double {
    sin(d * .pi / 180)
  }

  private static func cosDeg(_ d: Double) -> Double {
    cos(d * .pi / 180)
  }

  private static func normalizeAngleRadians(_ r: Double) -> Double {
    var a = r
    while a > .pi { a -= 2 * .pi }
    while a < -.pi { a += 2 * .pi }
    return a
  }
}

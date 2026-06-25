import Foundation

/// Geocentric Moon RA/Dec from a compact low-precision theory (similar to simplified Meeus / common JS moon snippets).
enum LunarEphemeris {

  /// Right ascension and declination of the Moon’s geocentric apparent place (radians), mean obliquity.
  static func moonGeocentricRADecRadians(julianDay: Double) -> (Double, Double) {
    let d = julianDay - 2_451_545.0
    let rad = Double.pi / 180
    let e = rad * 23.4397

    let L = rad * (218.316 + 13.176396 * d)
    let M = rad * (134.963 + 13.064993 * d)
    let F = rad * (93.272 + 13.229350 * d)

    let lon = L + rad * 6.289 * sin(M)
    let lat = rad * 5.128 * sin(F)

    let ra = atan2(sin(lon) * cos(e) - tan(lat) * sin(e), cos(lon))
    let dec = asin(sin(lat) * cos(e) + cos(lat) * sin(e) * sin(lon))
    return (ra, dec)
  }
}

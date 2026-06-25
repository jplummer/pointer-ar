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
    case .planet:
      guard let pid = target.planetId else { return nil }
      let jd = julianDayUTC(date)
      let (ra, dec) = planetGeocentricRADecRadians(pid, julianDay: jd)
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
    case .planet:
      guard let pid = target.planetId else { return nil }
      (ra, dec) = planetGeocentricRADecRadians(pid, julianDay: jd)
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

  // MARK: - Simplified planetary ephemeris

  private struct OrbitalElements {
    let a: Double   // semi-major axis (AU)
    let e: Double   // eccentricity
    let I: Double   // inclination (deg)
    let L: Double   // mean longitude (deg)
    let wBar: Double // longitude of perihelion (deg)
    let omega: Double // longitude of ascending node (deg)
  }

  /// Mean orbital elements at J2000 + rates per century (JPL approximations, valid ~1800–2050).
  private static func meanElements(_ planet: CelestialTarget.PlanetId, T: Double) -> OrbitalElements {
    switch planet {
    case .mercury:
      return OrbitalElements(
        a: 0.38709927 + 0.00000037 * T, e: 0.20563593 + 0.00001906 * T,
        I: 7.00497902 - 0.00594749 * T, L: revDeg(252.25032350 + 149472.67411175 * T),
        wBar: 77.45779628 + 0.16047689 * T, omega: 48.33076593 - 0.12534081 * T)
    case .venus:
      return OrbitalElements(
        a: 0.72333566 + 0.00000390 * T, e: 0.00677672 - 0.00004107 * T,
        I: 3.39467605 - 0.00078890 * T, L: revDeg(181.97909950 + 58517.81538729 * T),
        wBar: 131.60246718 + 0.00268329 * T, omega: 76.67984255 - 0.27769418 * T)
    case .mars:
      return OrbitalElements(
        a: 1.52371034 + 0.00001847 * T, e: 0.09339410 + 0.00007882 * T,
        I: 1.84969142 - 0.00813131 * T, L: revDeg(-4.55343205 + 19140.30268499 * T),
        wBar: -23.94362959 + 0.44441088 * T, omega: 49.55953891 - 0.29257343 * T)
    case .jupiter:
      return OrbitalElements(
        a: 5.20288700 - 0.00011607 * T, e: 0.04838624 - 0.00013253 * T,
        I: 1.30439695 - 0.00183714 * T, L: revDeg(34.39644051 + 3034.74612775 * T),
        wBar: 14.72847983 + 0.21252668 * T, omega: 100.47390909 + 0.20469106 * T)
    case .saturn:
      return OrbitalElements(
        a: 9.53667594 - 0.00125060 * T, e: 0.05386179 - 0.00050991 * T,
        I: 2.48599187 + 0.00193609 * T, L: revDeg(49.95424423 + 1222.49362201 * T),
        wBar: 92.59887831 - 0.41897216 * T, omega: 113.66242448 - 0.28867794 * T)
    }
  }

  /// Geocentric equatorial RA/Dec (radians) for a naked-eye planet.
  static func planetGeocentricRADecRadians(_ planet: CelestialTarget.PlanetId, julianDay: Double) -> (Double, Double) {
    let T = (julianDay - 2_451_545.0) / 36_525.0
    let el = meanElements(planet, T: T)

    let M = revDeg(el.L - el.wBar) * .pi / 180
    let E = solveKepler(M: M, e: el.e)
    let xOrb = el.a * (cos(E) - el.e)
    let yOrb = el.a * sqrt(1 - el.e * el.e) * sin(E)

    let w = (el.wBar - el.omega) * .pi / 180
    let Om = el.omega * .pi / 180
    let Inc = el.I * .pi / 180

    let cosW = cos(w); let sinW = sin(w)
    let cosO = cos(Om); let sinO = sin(Om)
    let cosI = cos(Inc); let sinI = sin(Inc)

    let px1 = cosW * cosO - sinW * sinO * cosI
    let px2 = -sinW * cosO - cosW * sinO * cosI
    let py1 = cosW * sinO + sinW * cosO * cosI
    let py2 = -sinW * sinO + cosW * cosO * cosI
    let xEcl = px1 * xOrb + px2 * yOrb
    let yEcl = py1 * xOrb + py2 * yOrb
    let zEcl = sinW * sinI * xOrb + cosW * sinI * yOrb

    let earthEl = meanElements_Earth(T: T)
    let Me = revDeg(earthEl.L - earthEl.wBar) * .pi / 180
    let Ee = solveKepler(M: Me, e: earthEl.e)
    let xeOrb = earthEl.a * (cos(Ee) - earthEl.e)
    let yeOrb = earthEl.a * sqrt(1 - earthEl.e * earthEl.e) * sin(Ee)

    let we = (earthEl.wBar - earthEl.omega) * .pi / 180
    let Oe = earthEl.omega * .pi / 180
    let Ie = earthEl.I * .pi / 180
    let cosWe = cos(we); let sinWe = sin(we)
    let cosOe = cos(Oe); let sinOe = sin(Oe)
    let cosIe = cos(Ie); let sinIe = sin(Ie)

    let ex1 = cosWe * cosOe - sinWe * sinOe * cosIe
    let ex2 = -sinWe * cosOe - cosWe * sinOe * cosIe
    let ey1 = cosWe * sinOe + sinWe * cosOe * cosIe
    let ey2 = -sinWe * sinOe + cosWe * cosOe * cosIe
    let xeEcl = ex1 * xeOrb + ex2 * yeOrb
    let yeEcl = ey1 * xeOrb + ey2 * yeOrb
    let zeEcl = sinWe * sinIe * xeOrb + cosWe * sinIe * yeOrb

    let dx = xEcl - xeEcl
    let dy = yEcl - yeEcl
    let dz = zEcl - zeEcl

    let eps = (23.4392911111 - 0.013004167 * T) * .pi / 180
    let xEq = dx
    let yEq = dy * cos(eps) - dz * sin(eps)
    let zEq = dy * sin(eps) + dz * cos(eps)

    let ra = atan2(yEq, xEq)
    let dec = atan2(zEq, sqrt(xEq * xEq + yEq * yEq))
    return (ra, dec)
  }

  private static func meanElements_Earth(T: Double) -> OrbitalElements {
    OrbitalElements(
      a: 1.00000261 + 0.00000562 * T, e: 0.01671123 - 0.00004392 * T,
      I: -0.00001531 - 0.01294668 * T, L: revDeg(100.46457166 + 35999.37244981 * T),
      wBar: 102.93768193 + 0.32327364 * T, omega: 0.0)
  }

  private static func solveKepler(M: Double, e: Double) -> Double {
    var E = M
    for _ in 0 ..< 15 {
      let dE = (M - E + e * sin(E)) / (1 - e * cos(E))
      E += dE
      if abs(dE) < 1e-12 { break }
    }
    return E
  }
}

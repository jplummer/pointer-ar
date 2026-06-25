import Foundation
import simd

/// Rough LEO propagation from CelesTrak GP JSON classical elements (~km-level drift vs SGP4).
enum TLEKeplerPropagator {

  private static let earthMuKm3s2 = 398_600.4418

  struct GPRecord {
    let epoch: Date
    let meanMotionRevPerDay: Double
    let eccentricity: Double
    let inclinationDeg: Double
    let raOfAscNodeDeg: Double
    let argOfPericenterDeg: Double
    let meanAnomalyDeg: Double
  }

  /// Earth-fixed ECEF position (km) for the spacecraft at `time` using two-body dynamics + Greenwich rotation.
  static func ecefKilometers(gp: GPRecord, time: Date) -> simd_double3? {
    let dt = time.timeIntervalSince(gp.epoch)
    guard dt.isFinite else { return nil }

    let n = gp.meanMotionRevPerDay * (2 * Double.pi) / 86_400
    guard n > 0 else { return nil }

    let a = pow(Self.earthMuKm3s2 / (n * n), 1.0 / 3.0)
    let e = gp.eccentricity
    guard e >= 0, e < 1 else { return nil }

    let M0 = gp.meanAnomalyDeg * Double.pi / 180
    let Mk = M0 + n * dt

    let E = solveKepler(M: Mk, eccentricity: e)
    let nu = 2 * atan2(sqrt(1 + e) * sin(E / 2), sqrt(1 - e) * cos(E / 2))
    let r = a * (1 - e * cos(E))

    let i = gp.inclinationDeg * Double.pi / 180
    let omega = gp.raOfAscNodeDeg * Double.pi / 180
    let w = gp.argOfPericenterDeg * Double.pi / 180
    let u = w + nu

    let x = r * (cos(u) * cos(omega) - sin(u) * sin(omega) * cos(i))
    let y = r * (cos(u) * sin(omega) + sin(u) * cos(omega) * cos(i))
    let z = r * (sin(u) * sin(i))

    let jd = julianDayUTC(time)
    let gmst = TopocentricAstronomy.greenwichMeanSiderealTimeRadians(julianDay: jd)
    let x1 = x * cos(gmst) + y * sin(gmst)
    let y1 = -x * sin(gmst) + y * cos(gmst)
    let z1 = z
    return simd_double3(x1, y1, z1)
  }

  static func julianDayUTC(_ date: Date) -> Double {
    date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
  }

  private static func solveKepler(M: Double, eccentricity e: Double) -> Double {
    var E = M
    for _ in 0..<12 {
      let d = (E - e * sin(E) - M) / (1 - e * cos(E))
      E -= d
      if abs(d) < 1e-12 { break }
    }
    return E
  }
}

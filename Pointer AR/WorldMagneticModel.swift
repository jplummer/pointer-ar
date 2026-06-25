import CoreLocation
import Foundation
import simd

/// World Magnetic Model (WMM-2025) geomagnetic field and declination at a WGS84 site.
/// Ported from NOAA’s reference flow as used by the `pygeomag` package (same coefficient layout as WMM.COF).
enum WorldMagneticModel {

  static let wmmVersion = "WMM-2025"

  /// Declination in degrees, **east** of true north, for a horizontal compass needle.
  static func declinationDegrees(
    latitudeDeg: Double,
    longitudeDeg: Double,
    heightKilometers: Double,
    at date: Date
  ) -> Double? {
    let time = decimalYearUTC(date)
    guard let r = evaluate(
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      altitudeKm: heightKilometers,
      decimalYear: time,
      allowDateOutsideLifespan: true
    ) else { return nil }
    return r.declinationDegrees
  }

  /// Declination (east of true north) and **inclination** (dip): angle of the field vector below the horizontal; degrees, positive downward.
  static func geomagneticSurvey(
    latitudeDeg: Double,
    longitudeDeg: Double,
    heightKilometers: Double,
    at date: Date
  ) -> (declinationDegrees: Double, inclinationDegrees: Double)? {
    let time = decimalYearUTC(date)
    guard let r = evaluate(
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      altitudeKm: heightKilometers,
      decimalYear: time,
      allowDateOutsideLifespan: true
    ) else { return nil }
    return (r.declinationDegrees, r.inclinationDegrees)
  }

  /// Unit vector in observer **ENU** (north, east, up) aligned with the local geomagnetic field (WMM North/East/Down converted to ENU).
  static func fieldDirectionENUUnit(
    latitudeDeg: Double,
    longitudeDeg: Double,
    heightKilometers: Double,
    at date: Date
  ) -> simd_float3? {
    let time = decimalYearUTC(date)
    guard let r = evaluate(
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      altitudeKm: heightKilometers,
      decimalYear: time,
      allowDateOutsideLifespan: true
    ) else { return nil }
    let bx = r.bx
    let by = r.by
    let bz = r.bzDown
    let len = sqrt(bx * bx + by * by + bz * bz)
    guard len > 1e-12, len.isFinite else { return nil }
    return simd_normalize(
      simd_float3(
        Float(bx / len),
        Float(by / len),
        Float(-bz / len)
      )
    )
  }

  // MARK: - Internals

  private static let maxord = 12
  private static let size = 13

  private static var cachedCoefficients: Coefficients?

  private struct Coefficients {
    let epoch: Double
    let c: [[Double]]
    let cd: [[Double]]
    let k: [[Double]]
    let fn: [Double]
    let fm: [Double]
    /// Schmidt normalization scratch vector carried into each evaluation (matches NOAA reference flow).
    let legendreSeed: [Double]
  }

  private struct FieldResult {
    let declinationDegrees: Double
    let inclinationDegrees: Double
    let bx: Double
    let by: Double
    /// Downward component (WMM convention); ENU up uses **minus** this.
    let bzDown: Double
  }

  private static func loadCoefficients() -> Coefficients? {
    if let cachedCoefficients { return cachedCoefficients }
    guard let url = Bundle.main.url(forResource: "WMM_2025", withExtension: "COF"),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }

    var lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else { return nil }

    let headerParts = lines[0].split(whereSeparator: \.isWhitespace).map(String.init)
    guard headerParts.count >= 1, let epoch = Double(headerParts[0]) else { return nil }

    lines.removeFirst()
    var records: [(Int, Int, Double, Double, Double, Double)] = []
    for line in lines {
      if line.hasPrefix("9999") { break }
      let p = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard p.count == 6,
            let n = Int(p[0]),
            let m = Int(p[1]),
            let gnm = Double(p[2]),
            let hnm = Double(p[3]),
            let dgnm = Double(p[4]),
            let dhnm = Double(p[5])
      else { continue }
      records.append((n, m, gnm, hnm, dgnm, dhnm))
    }

    let s = Self.size
    var c = createMatrix(s, s, 0.0)
    var cd = createMatrix(s, s, 0.0)
    var snorm = [Double](repeating: 0, count: s * s)
    var fn = [Double](repeating: 0, count: s)
    var fm = [Double](repeating: 0, count: s)
    var k = createMatrix(s, s, 0.0)

    for (n, m, gnm, hnm, dgnm, dhnm) in records {
      if m > maxord { break }
      if m > n || m < 0 { return nil }
      c[m][n] = gnm
      cd[m][n] = dgnm
      if m != 0 {
        c[n][m - 1] = hnm
        cd[n][m - 1] = dhnm
      }
    }

    snorm[0] = 1.0
    fm[0] = 0.0
    for n in 1...maxord {
      snorm[n] = snorm[n - 1] * Double(2 * n - 1) / Double(n)
      var j = 2
      var m = 0
      let d1 = 1
      var d2 = (n - m + d1) / d1
      while d2 > 0 {
        k[m][n] = Double((n - 1) * (n - 1) - m * m) / Double((2 * n - 1) * (2 * n - 3))
        if m > 0 {
          let flnmj = Double((n - m + 1) * j) / Double(n + m)
          snorm[n + m * s] = snorm[n + (m - 1) * s] * sqrt(flnmj)
          j = 1
          c[n][m - 1] = snorm[n + m * s] * c[n][m - 1]
          cd[n][m - 1] = snorm[n + m * s] * cd[n][m - 1]
        }
        c[m][n] = snorm[n + m * s] * c[m][n]
        cd[m][n] = snorm[n + m * s] * cd[m][n]
        d2 -= 1
        m += d1
      }
      fn[n] = Double(n + 1)
      fm[n] = Double(n)
    }
    k[1][1] = 0.0

    let coeff = Coefficients(
      epoch: epoch,
      c: c,
      cd: cd,
      k: k,
      fn: fn,
      fm: fm,
      legendreSeed: snorm
    )
    cachedCoefficients = coeff
    return coeff
  }

  private static func evaluate(
    latitudeDeg: Double,
    longitudeDeg: Double,
    altitudeKm: Double,
    decimalYear: Double,
    allowDateOutsideLifespan: Bool
  ) -> FieldResult? {
    guard let coeff = loadCoefficients() else { return nil }

    let dt = decimalYear - coeff.epoch
    if !allowDateOutsideLifespan && (dt < 0 || dt > 5) { return nil }

    let s = Self.size
    var tc = createMatrix(s, s, 0.0)
    var dp = createMatrix(s, s, 0.0)
    var sp = [Double](repeating: 0, count: s)
    var cp = [Double](repeating: 0, count: s)
    var pp = [Double](repeating: 0, count: s)

    sp[0] = 0.0
    cp[0] = 1.0
    pp[0] = 1.0
    dp[0][0] = 0.0

    let a = 6378.137
    let b = 6356.7523142
    let re = 6371.2
    let a2 = a * a
    let b2 = b * b
    let c2 = a2 - b2
    let a4 = a2 * a2
    let b4 = b2 * b2
    let c4 = a4 - b4

    let glon = longitudeDeg
    let glat = latitudeDeg
    let alt = altitudeKm

    let rlon = glon * .pi / 180
    let rlat = glat * .pi / 180
    let srlon = sin(rlon)
    let crlon = cos(rlon)
    let srlat = sin(rlat)
    let crlat = cos(rlat)
    let srlat2 = srlat * srlat
    let crlat2 = crlat * crlat
    sp[1] = srlon
    cp[1] = crlon

    let q = sqrt(a2 - c2 * srlat2)
    let q1 = alt * q
    let q2 = ((q1 + a2) / (q1 + b2)) * ((q1 + a2) / (q1 + b2))
    let ct = srlat / sqrt(q2 * crlat2 + srlat2)
    let st = sqrt(1.0 - ct * ct)
    let r2 = alt * alt + 2.0 * q1 + (a4 - c4 * srlat2) / (q * q)
    let r = sqrt(r2)
    let d = sqrt(a2 * crlat2 + b2 * srlat2)
    let ca = (alt + d) / r
    let sa = c2 * crlat * srlat / (r * d)

    for m in 2...maxord {
      sp[m] = sp[1] * cp[m - 1] + cp[1] * sp[m - 1]
      cp[m] = cp[1] * cp[m - 1] - sp[1] * sp[m - 1]
    }

    var legendre = coeff.legendreSeed

    let aor = re / r
    var ar = aor * aor
    var br = 0.0
    var bt = 0.0
    var bp = 0.0
    var bpp = 0.0

    for n in 1...maxord {
      ar *= aor
      var m = 0
      let d3 = 1
      var d4 = (n + m + d3) / d3
      while d4 > 0 {
        if n == m {
          legendre[pidx(n, m - 1, s)] =
            st * legendre[pidx(n - 1, m - 1, s)]
          dp[m][n] =
            st * dp[m - 1][n - 1]
            + ct * legendre[pidx(n - 1, m - 1, s)]
        } else if n == 1 && m == 0 {
          legendre[pidx(n, m, s)] =
            ct * legendre[pidx(n - 1, m, s)]
          dp[m][n] =
            ct * dp[m][n - 1]
            - st * legendre[pidx(n - 1, m, s)]
        } else if n > 1 && n != m {
          if m > n - 2 {
            legendre[pidx(n - 2, m, s)] = 0.0
          }
          if m > n - 2 {
            dp[m][n - 2] = 0.0
          }
          legendre[pidx(n, m, s)] =
            ct * legendre[pidx(n - 1, m, s)]
            - coeff.k[m][n] * legendre[pidx(n - 2, m, s)]
          dp[m][n] =
            ct * dp[m][n - 1]
            - st * legendre[pidx(n - 1, m, s)]
            - coeff.k[m][n] * dp[m][n - 2]
        }

        tc[m][n] = coeff.c[m][n] + dt * coeff.cd[m][n]
        if m != 0 {
          tc[n][m - 1] = coeff.c[n][m - 1] + dt * coeff.cd[n][m - 1]
        }

        let par = ar * legendre[pidx(n, m, s)]
        let temp1: Double
        let temp2: Double
        if m == 0 {
          temp1 = tc[m][n] * cp[m]
          temp2 = tc[m][n] * sp[m]
        } else {
          temp1 = tc[m][n] * cp[m] + tc[n][m - 1] * sp[m]
          temp2 = tc[m][n] * sp[m] - tc[n][m - 1] * cp[m]
        }
        bt -= ar * temp1 * dp[m][n]
        bp += coeff.fm[m] * temp2 * par
        br += coeff.fn[n] * temp1 * par

        if st == 0.0 && m == 1 {
          if n == 1 {
            pp[n] = pp[n - 1]
          } else {
            pp[n] = ct * pp[n - 1] - coeff.k[m][n] * pp[n - 2]
          }
          let parp = ar * pp[n]
          bpp += coeff.fm[m] * temp2 * parp
        }

        d4 -= 1
        m += d3
      }
    }

    var bpFinal = bp
    if st == 0.0 {
      bpFinal = bpp
    } else {
      bpFinal /= st
    }

    let bx = -bt * ca - br * sa
    let by = bpFinal
    let bzDown = bt * sa - br * ca
    let bh = sqrt(bx * bx + by * by)
    let dec = atan2(by, bx) * 180 / .pi
    let inc = atan2(bzDown, bh) * 180 / .pi

    guard bh.isFinite, dec.isFinite, inc.isFinite else { return nil }
    return FieldResult(
      declinationDegrees: dec,
      inclinationDegrees: inc,
      bx: bx,
      by: by,
      bzDown: bzDown
    )
  }

  private static func pidx(_ n: Int, _ m: Int, _ sz: Int) -> Int {
    n + m * sz
  }

  private static func createMatrix(_ rows: Int, _ cols: Int, _ v: Double) -> [[Double]] {
    [[Double]](repeating: [Double](repeating: v, count: cols), count: rows)
  }

  /// Gregorian UTC decimal year (matches pygeomag expectations for WMM timescale).
  private static func decimalYearUTC(_ date: Date) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let y = cal.component(.year, from: date)
    guard
      let startYear = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
      let startNext = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1))
    else {
      return Double(y)
    }
    let frac = date.timeIntervalSince(startYear) / startNext.timeIntervalSince(startYear)
    return Double(y) + frac
  }
}

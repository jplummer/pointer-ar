import CoreLocation
import Foundation
import simd

/// Cached network-fed aim directions for catalog targets that are not purely analytic ephemerides.
///
/// **JPL Horizons:** Prefer NASA/JPL Horizons observer-centered ephemerides when a body needs high-quality topocentric az/el (or non‑Kepler motion) and local analytic/TLE propagation is insufficient — JWST already uses `ssd.jpl.nasa.gov/api/horizons.api`; extend that pattern for similar targets instead of inventing bespoke orbit integrators here.
@MainActor
final class SatelliteAimStore: ObservableObject {
  /// Fallback GP elements for ISS (NORAD 25544) so aiming can still resolve if network ephemeris fetches fail.
  private static let fallbackISSGP = TLEKeplerPropagator.GPRecord(
    epoch: Date(timeIntervalSince1970: 1_750_800_000),
    meanMotionRevPerDay: 15.49560348,
    eccentricity: 0.0006740,
    inclinationDeg: 51.6392,
    raOfAscNodeDeg: 142.6226,
    argOfPericenterDeg: 30.7654,
    meanAnomalyDeg: 329.3748
  )

  /// Fallback GP elements for HST (NORAD 20580) so aiming can still resolve if network ephemeris fetches fail.
  private static let fallbackHubbleGP = TLEKeplerPropagator.GPRecord(
    epoch: Date(timeIntervalSince1970: 1_745_528_245.771456),
    meanMotionRevPerDay: 15.30170094,
    eccentricity: 0.0002338,
    inclinationDeg: 28.4693,
    raOfAscNodeDeg: 17.1598,
    argOfPericenterDeg: 42.8726,
    meanAnomalyDeg: 317.2368
  )

  /// Explicit agent; some CDNs return empty bodies to generic/default clients.
  private static let satelliteSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpAdditionalHeaders = [
      "User-Agent": "Pointer/1.0 (+https://github.com/jplummer/pointer; iOS satellite ephemeris)",
    ]
    c.timeoutIntervalForRequest = 45
    c.timeoutIntervalForResource = 60
    return URLSession(configuration: c)
  }()

  @Published private(set) var lastISSFetch: Date?
  @Published private(set) var lastHubbleFetch: Date?
  @Published private(set) var lastJwstFetch: Date?
  @Published private(set) var lastISSGP: TLEKeplerPropagator.GPRecord?
  @Published private(set) var lastHubbleGP: TLEKeplerPropagator.GPRecord?

  /// Published so selecting a satellite triggers a redraw when async fetch fills the cache (private caches did not notify `ObservableObject`).
  @Published private(set) var issENU: simd_float3?
  @Published private(set) var hubbleENU: simd_float3?
  @Published private(set) var jwstENU: simd_float3?

  func enuTowardSatelliteRoute(
    _ route: CelestialTarget.SatelliteRoute,
    observer: CLLocationCoordinate2D,
    heightAboveEllipsoidMeters: Double,
    at date: Date
  ) async -> simd_float3? {
    let maxAge: TimeInterval
    let lastFetch: Date?
    switch route {
    case .iss:   maxAge = 1800; lastFetch = lastISSFetch
    case .hubble: maxAge = 1800; lastFetch = lastHubbleFetch
    case .jwst:  maxAge = 3600; lastFetch = lastJwstFetch
    }

    if let last = lastFetch, date.timeIntervalSince(last) < maxAge {
      return staleENU(route: route, observer: observer, heightAboveEllipsoidMeters: heightAboveEllipsoidMeters, at: date)
    }

    switch route {
    case .iss:
      await refreshISS(observer: observer, heightMeters: heightAboveEllipsoidMeters, at: date)
      return issENU
    case .hubble:
      await refreshHubble(observer: observer, heightMeters: heightAboveEllipsoidMeters, at: date)
      return hubbleENU
    case .jwst:
      await refreshJwst(observer: observer, heightMeters: heightAboveEllipsoidMeters, at: date)
      return jwstENU
    }
  }

  func prefetchIfNeeded(
    aimMode: AimSession.AimMode,
    observer: CLLocationCoordinate2D?,
    altitudeMeters: Double?,
    at date: Date
  ) async {
    guard case .celestial(let t) = aimMode,
          t.kind == .satellite,
          let route = t.satelliteRoute,
          let obs = observer
    else { return }
    let h = altitudeMeters ?? 0
    _ = await enuTowardSatelliteRoute(
      route,
      observer: obs,
      heightAboveEllipsoidMeters: h,
      at: date
    )
  }

  func staleENU(
    route: CelestialTarget.SatelliteRoute,
    observer: CLLocationCoordinate2D,
    heightAboveEllipsoidMeters: Double,
    at date: Date
  ) -> simd_float3? {
    switch route {
    case .iss:
      if let gp = lastISSGP,
         let satKm = TLEKeplerPropagator.ecefKilometers(gp: gp, time: date),
         let v = Self.enuFromEcefKm(observer: observer, heightMeters: heightAboveEllipsoidMeters, satelliteEcefKm: satKm) {
        return v
      }
      if let satKm = TLEKeplerPropagator.ecefKilometers(gp: Self.fallbackISSGP, time: date),
         let v = Self.enuFromEcefKm(observer: observer, heightMeters: heightAboveEllipsoidMeters, satelliteEcefKm: satKm) {
        return v
      }
      return issENU
    case .hubble:
      if let gp = lastHubbleGP,
         let satKm = TLEKeplerPropagator.ecefKilometers(gp: gp, time: date),
         let v = Self.enuFromEcefKm(observer: observer, heightMeters: heightAboveEllipsoidMeters, satelliteEcefKm: satKm) {
        return v
      }
      if let satKm = TLEKeplerPropagator.ecefKilometers(gp: Self.fallbackHubbleGP, time: date),
         let v = Self.enuFromEcefKm(observer: observer, heightMeters: heightAboveEllipsoidMeters, satelliteEcefKm: satKm) {
        return v
      }
      return hubbleENU
    case .jwst:
      return jwstENU
    }
  }

  private func refreshISS(observer: CLLocationCoordinate2D, heightMeters: Double, at date: Date) async {
    let urls = [
      URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=json"),
      URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=json"),
    ].compactMap { $0 }

    for url in urls {
      do {
        let (data, _) = try await Self.satelliteSession.data(from: url)
        guard !data.isEmpty, data.first != UInt8(ascii: "<") else { continue }
        let rows = try Self.decodeGpRows(from: data)
        let row: GpRow?
        if url.absoluteString.contains("GROUP=stations") {
          row = rows.first { $0.noradCatId == 25544 }
        } else {
          row = rows.first
        }
        guard let row,
              let iso = GpEpochParser.parseUtc(row.epoch),
              let gp = gpRecord(from: row, epoch: iso),
              let satKm = TLEKeplerPropagator.ecefKilometers(gp: gp, time: date),
              let enu = Self.enuFromEcefKm(observer: observer, heightMeters: heightMeters, satelliteEcefKm: satKm)
        else { continue }
        lastISSGP = gp
        issENU = enu
        lastISSFetch = Date()
        return
      } catch {
        continue
      }
    }

    await refreshISSFromPublicTleApi(observer: observer, heightMeters: heightMeters, at: date)
    guard lastISSGP == nil,
          let satKm = TLEKeplerPropagator.ecefKilometers(gp: Self.fallbackISSGP, time: date),
          let enu = Self.enuFromEcefKm(observer: observer, heightMeters: heightMeters, satelliteEcefKm: satKm)
    else { return }
    lastISSGP = Self.fallbackISSGP
    issENU = enu
    lastISSFetch = Date()
  }

  private func refreshISSFromPublicTleApi(observer: CLLocationCoordinate2D, heightMeters: Double, at date: Date) async {
    guard let url = URL(string: "https://tle.ivanstanojevic.me/api/tle/25544") else { return }
    do {
      let (data, _) = try await Self.satelliteSession.data(from: url)
      guard !data.isEmpty, data.first != UInt8(ascii: "<") else { return }
      let payload = try JSONDecoder().decode(PublicTleApiPayload.self, from: data)
      guard let gp = NoradTwoLineElements.gpRecord(line1: payload.line1, line2: payload.line2),
            let satKm = TLEKeplerPropagator.ecefKilometers(gp: gp, time: date),
            let enu = Self.enuFromEcefKm(observer: observer, heightMeters: heightMeters, satelliteEcefKm: satKm)
      else { return }
      lastISSGP = gp
      issENU = enu
      lastISSFetch = Date()
    } catch {
      return
    }
  }

  private func refreshHubble(observer: CLLocationCoordinate2D, heightMeters: Double, at date: Date) async {
    let urls = [
      URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=20580&FORMAT=json"),
      URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=science&FORMAT=json"),
    ].compactMap { $0 }

    for url in urls {
      do {
        let (data, _) = try await Self.satelliteSession.data(from: url)
        guard !data.isEmpty, data.first != UInt8(ascii: "<") else { continue }
        let rows = try Self.decodeGpRows(from: data)
        let row: GpRow?
        if url.absoluteString.contains("GROUP=science") {
          row = rows.first { $0.noradCatId == 20580 }
        } else {
          row = rows.first
        }
        guard let row,
              let iso = GpEpochParser.parseUtc(row.epoch),
              let gp = gpRecord(from: row, epoch: iso),
              let satKm = TLEKeplerPropagator.ecefKilometers(gp: gp, time: date),
              let enu = Self.enuFromEcefKm(observer: observer, heightMeters: heightMeters, satelliteEcefKm: satKm)
        else { continue }
        lastHubbleGP = gp
        hubbleENU = enu
        lastHubbleFetch = Date()
        return
      } catch {
        continue
      }
    }

    await refreshHubbleFromPublicTleApi(observer: observer, heightMeters: heightMeters, at: date)
    guard lastHubbleGP == nil,
          let satKm = TLEKeplerPropagator.ecefKilometers(gp: Self.fallbackHubbleGP, time: date),
          let enu = Self.enuFromEcefKm(observer: observer, heightMeters: heightMeters, satelliteEcefKm: satKm)
    else { return }
    lastHubbleGP = Self.fallbackHubbleGP
    hubbleENU = enu
    lastHubbleFetch = Date()
  }

  /// CelesTrak `/NORAD/elements` often returns **403 HTML** when rate-limited; NORAD two-line elements from a small public TLE API keep Hubble usable.
  private func refreshHubbleFromPublicTleApi(observer: CLLocationCoordinate2D, heightMeters: Double, at date: Date) async {
    guard let url = URL(string: "https://tle.ivanstanojevic.me/api/tle/20580") else { return }
    do {
      let (data, _) = try await Self.satelliteSession.data(from: url)
      guard !data.isEmpty, data.first != UInt8(ascii: "<") else { return }
      let payload = try JSONDecoder().decode(PublicTleApiPayload.self, from: data)
      guard let gp = NoradTwoLineElements.gpRecord(line1: payload.line1, line2: payload.line2),
            let satKm = TLEKeplerPropagator.ecefKilometers(gp: gp, time: date),
            let enu = Self.enuFromEcefKm(observer: observer, heightMeters: heightMeters, satelliteEcefKm: satKm)
      else { return }
      lastHubbleGP = gp
      hubbleENU = enu
      lastHubbleFetch = Date()
    } catch {
      return
    }
  }

  private func refreshJwst(observer: CLLocationCoordinate2D, heightMeters: Double, at date: Date) async {
    // Horizons geodetic SITE_COORD is **east longitude**, **latitude**, ellipsoid height (km) — see `ssd-api` center-site notes.
    let coordStr = horizonsSiteCoordinateGeodeticString(
      longitudeDeg: observer.longitude,
      latitudeDeg: observer.latitude,
      altitudeKm: heightMeters / 1000
    )

    guard var comp = URLComponents(string: "https://ssd.jpl.nasa.gov/api/horizons.api") else { return }
    let q: [URLQueryItem] = [
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "COMMAND", value: "-170"),
      URLQueryItem(name: "OBJ_DATA", value: "YES"),
      URLQueryItem(name: "MAKE_EPHEM", value: "YES"),
      URLQueryItem(name: "EPHEM_TYPE", value: "OBSERVER"),
      URLQueryItem(name: "CENTER", value: "coord@399"),
      URLQueryItem(name: "COORD_TYPE", value: "GEODETIC"),
      URLQueryItem(name: "SITE_COORD", value: coordStr),
      // With current Horizons.api, redundant ` UT` inside quoted times conflicts unless `TIME_TYPE` is set; send scale here and bare calendar times below.
      URLQueryItem(name: "TIME_TYPE", value: "UT"),
      URLQueryItem(name: "START_TIME", value: horizonsQuotedUtCalendar(date)),
      URLQueryItem(name: "STOP_TIME", value: horizonsQuotedUtCalendar(date.addingTimeInterval(60))),
      URLQueryItem(name: "STEP_SIZE", value: "'1 m'"),
      URLQueryItem(name: "QUANTITIES", value: "'4'"),
    ]
    comp.queryItems = q
    guard let url = comp.url else { return }

    do {
      let (data, _) = try await Self.satelliteSession.data(from: url)
      guard !data.isEmpty,
            let payload = Self.horizonsPayload(from: data),
            payload.errorText.isEmpty,
            let (_, el) = HorizonsAzElevParser.firstAzElevDegrees(from: payload.resultText)
      else {
        return
      }
      let azRad = Float(el.azimuth * Float.pi / 180)
      let altRad = Float(el.elevation * Float.pi / 180)
      let enu = TopocentricAstronomy.enuFromAltitudeAzimuthTrueNorth(
        altitudeRad: altRad,
        azimuthFromNorthRad: azRad
      )
      jwstENU = enu
      lastJwstFetch = Date()
    } catch {
      return
    }
  }

  private func gpRecord(from row: GpRow, epoch: Date) -> TLEKeplerPropagator.GPRecord? {
    guard let mm = row.meanMotionRevPerDay,
          let ecc = row.eccentricity,
          let inc = row.inclinationDeg,
          let raan = row.raOfAscNodeDeg,
          let argp = row.argOfPericenterDeg,
          let ma = row.meanAnomalyDeg
    else { return nil }
    return TLEKeplerPropagator.GPRecord(
      epoch: epoch,
      meanMotionRevPerDay: mm,
      eccentricity: ecc,
      inclinationDeg: inc,
      raOfAscNodeDeg: raan,
      argOfPericenterDeg: argp,
      meanAnomalyDeg: ma
    )
  }

  /// ISS path: satellite position already in **meters** (WGS84 ECEF).
  private static func enuFromEcefMeters(
    observer: CLLocationCoordinate2D,
    heightMeters: Double,
    satelliteEcefMeters: simd_double3
  ) -> simd_float3? {
    let obs = Geodesy.ecefMeters(
      latitude: observer.latitude,
      longitude: observer.longitude,
      heightAboveEllipsoid: heightMeters
    )
    let d = satelliteEcefMeters - obs
    let separation = simd_length(d)
    guard separation > 100 else { return nil }

    let φ = observer.latitude * Double.pi / 180
    let λ = observer.longitude * Double.pi / 180
    let sinφ = sin(φ)
    let cosφ = cos(φ)
    let sinλ = sin(λ)
    let cosλ = cos(λ)

    let east = -sinλ * d.x + cosλ * d.y
    let north = -sinφ * cosλ * d.x - sinφ * sinλ * d.y + cosφ * d.z
    let up = cosφ * cosλ * d.x + cosφ * sinλ * d.y + sinφ * d.z

    let v = simd_float3(Float(north), Float(east), Float(up))
    let len = simd_length(v)
    guard len > 1e-6 else { return nil }
    return simd_normalize(v)
  }

  /// Kepler / TLE path: satellite position in **kilometers** ECEF (e.g. `TLEKeplerPropagator`).
  private static func enuFromEcefKm(
    observer: CLLocationCoordinate2D,
    heightMeters: Double,
    satelliteEcefKm: simd_double3
  ) -> simd_float3? {
    let satMeters = simd_double3(
      satelliteEcefKm.x * 1000,
      satelliteEcefKm.y * 1000,
      satelliteEcefKm.z * 1000
    )
    return enuFromEcefMeters(observer: observer, heightMeters: heightMeters, satelliteEcefMeters: satMeters)
  }

  /// Horizons `SITE_COORD` for Earth: east-longitude (deg), latitude (deg), height above ellipsoid (km).
  private func horizonsSiteCoordinateGeodeticString(longitudeDeg: Double, latitudeDeg: Double, altitudeKm: Double) -> String {
    let lat = max(-90, min(90, latitudeDeg))
    var lon = longitudeDeg.truncatingRemainder(dividingBy: 360)
    if lon > 180 { lon -= 360 }
    if lon <= -180 { lon += 360 }
    let inner = String(format: "%.6f,%.6f,%.6f", lon, lat, altitudeKm)
    return "'" + inner + "'"
  }

  /// Calendar time in UT for Horizons when `TIME_TYPE=UT` is set (do not append ` UT` inside the quoted token).
  private func horizonsQuotedUtCalendar(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MMM-dd HH:mm:ss"
    return "'" + f.string(from: date) + "'"
  }

  private static func decodeGpRows(from data: Data) throws -> [GpRow] {
    let dec = JSONDecoder()
    if let rows = try? dec.decode([GpRow].self, from: data), !rows.isEmpty {
      return rows
    }
    let one = try dec.decode(GpRow.self, from: data)
    return [one]
  }

  private struct PublicTleApiPayload: Decodable {
    let line1: String
    let line2: String
  }

  /// Parses NORAD **two-line element set** classical elements into our Kepler **`GPRecord`** (same simplified propagation as CelesTrak GP JSON).
  private enum NoradTwoLineElements {

    static func gpRecord(line1: String, line2: String) -> TLEKeplerPropagator.GPRecord? {
      guard let epochUtc = epochUtc(fromLine1: line1) else { return nil }
      let tokens = line2.split(whereSeparator: \.isWhitespace).map(String.init)
      guard tokens.count >= 8 else { return nil }
      guard let inc = Double(tokens[2]),
            let raan = Double(tokens[3]),
            let eccInt = Int(tokens[4]),
            let argp = Double(tokens[5]),
            let ma = Double(tokens[6]),
            let mm = Double(tokens[7])
      else { return nil }
      let ecc = Double(eccInt) / 10_000_000
      guard inc.isFinite, raan.isFinite, ecc.isFinite, argp.isFinite, ma.isFinite, mm.isFinite, mm > 0
      else { return nil }
      return TLEKeplerPropagator.GPRecord(
        epoch: epochUtc,
        meanMotionRevPerDay: mm,
        eccentricity: ecc,
        inclinationDeg: inc,
        raOfAscNodeDeg: raan,
        argOfPericenterDeg: argp,
        meanAnomalyDeg: ma
      )
    }

    /// TLE epoch field **`YYDDD.dddddddd`** (UTC), fields 18–32 on line 1.
    private static func epochUtc(fromLine1 line1: String) -> Date? {
      guard let regex = try? NSRegularExpression(pattern: #" (\d{2})(\d{3})\.(\d+)\b"#) else { return nil }
      guard let match = regex.firstMatch(in: line1, range: NSRange(line1.startIndex..., in: line1)),
            match.numberOfRanges >= 4,
            let r1 = Range(match.range(at: 1), in: line1),
            let r2 = Range(match.range(at: 2), in: line1),
            let r3 = Range(match.range(at: 3), in: line1),
            let yy = Int(line1[r1]),
            let ddd = Int(line1[r2]),
            let frac = Double("0." + line1[r3])
      else { return nil }
      guard (1 ... 366).contains(ddd) else { return nil }
      let fullYear = yy < 57 ? 2000 + yy : 1900 + yy
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = TimeZone(secondsFromGMT: 0)!
      guard let jan1Utc = cal.date(from: DateComponents(year: fullYear, month: 1, day: 1)) else { return nil }
      let seconds = TimeInterval((ddd - 1) * 86_400) + frac * 86_400
      return jan1Utc.addingTimeInterval(seconds)
    }
  }

  private static func horizonsPayload(from data: Data) -> (resultText: String, errorText: String)? {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let resultText: String
    if let s = obj["result"] as? String {
      resultText = s
    } else if let sub = obj["result"] {
      resultText = String(describing: sub)
    } else {
      resultText = ""
    }
    let errorText: String
    if let s = obj["error"] as? String {
      errorText = s
    } else if let b = obj["error"] as? Bool, b {
      errorText = "true"
    } else {
      errorText = ""
    }
    return (resultText, errorText)
  }

  private struct GpRow: Decodable {
    let epoch: String
    let noradCatId: Int?
    let meanMotionRevPerDay: Double?
    let eccentricity: Double?
    let inclinationDeg: Double?
    let raOfAscNodeDeg: Double?
    let argOfPericenterDeg: Double?
    let meanAnomalyDeg: Double?

    enum CodingKeys: String, CodingKey {
      case epoch = "EPOCH"
      case noradCatId = "NORAD_CAT_ID"
      case meanMotionRevPerDay = "MEAN_MOTION"
      case eccentricity = "ECCENTRICITY"
      case inclinationDeg = "INCLINATION"
      case raOfAscNodeDeg = "RA_OF_ASC_NODE"
      case argOfPericenterDeg = "ARG_OF_PERICENTER"
      case meanAnomalyDeg = "MEAN_ANOMALY"
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      epoch = try c.decode(String.self, forKey: .epoch)
      noradCatId = Self.decodeOptionalInt(c, key: .noradCatId)
      meanMotionRevPerDay = Self.decodeOptionalDouble(c, key: .meanMotionRevPerDay)
      eccentricity = Self.decodeOptionalDouble(c, key: .eccentricity)
      inclinationDeg = Self.decodeOptionalDouble(c, key: .inclinationDeg)
      raOfAscNodeDeg = Self.decodeOptionalDouble(c, key: .raOfAscNodeDeg)
      argOfPericenterDeg = Self.decodeOptionalDouble(c, key: .argOfPericenterDeg)
      meanAnomalyDeg = Self.decodeOptionalDouble(c, key: .meanAnomalyDeg)
    }

    private static func decodeOptionalDouble(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
      if let v = try? c.decode(Double.self, forKey: key) { return v }
      if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
      return nil
    }

    private static func decodeOptionalInt(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
      if let v = try? c.decode(Int.self, forKey: key) { return v }
      if let s = try? c.decode(String.self, forKey: key) { return Int(s) }
      return nil
    }
  }
}

private enum Iso8601FloatingDateParser {
  static func parse(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: raw) { return d }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: raw)
  }
}

/// CelesTrak GP JSON often uses `2026-04-19T17:09:53.755200` **without** a `Z` offset; `ISO8601DateFormatter` rejects that on Apple platforms.
private enum GpEpochParser {
  static func parseUtc(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let d = Iso8601FloatingDateParser.parse(trimmed) { return d }
    if let d = Iso8601FloatingDateParser.parse(trimmed + "Z") { return d }
    let posix = Locale(identifier: "en_US_POSIX")
    let formats = [
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
      "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
      "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd'T'HH:mm:ss",
    ]
    let f = DateFormatter()
    f.locale = posix
    f.timeZone = TimeZone(secondsFromGMT: 0)
    for format in formats {
      f.dateFormat = format
      if let d = f.date(from: trimmed) { return d }
    }
    return nil
  }
}

private enum HorizonsAzElevParser {

  struct AzElDeg {
    let azimuth: Float
    let elevation: Float
  }

  static func firstAzElevDegrees(from text: String) -> (String, AzElDeg)? {
    guard let range = text.range(of: "$$SOE"),
          let endRange = text.range(of: "$$EOE"),
          range.upperBound < endRange.lowerBound
    else { return nil }

    let block = String(text[range.upperBound..<endRange.lowerBound])
    for line in block.split(whereSeparator: \.isNewline) {
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
      // Horizons often prints `YYYY-Mon-DD HH:MN A az el` (5+ tokens) but some configs omit the `A` column (4 tokens).
      guard parts.count >= 4 else { continue }
      guard let az = Float(parts[parts.count - 2]),
            let el = Float(parts[parts.count - 1]),
            az.isFinite,
            el.isFinite
      else { continue }
      return (String(line), AzElDeg(azimuth: az, elevation: el))
    }
    return nil
  }
}

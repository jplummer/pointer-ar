import Foundation

struct CelestialTargetsPayload: Decodable {
  let schemaVersion: Int
  let targets: [CelestialTarget]
}

struct CelestialTarget: Codable, Identifiable, Hashable {
  let id: String
  let displayName: String
  let group: String
  let notes: String
  let sources: [String]
  let kind: Kind
  /// ICRS/J2000-style catalog (hours, degrees); only used for `fixed_star`.
  let raHours: Double?
  let decDegrees: Double?
  /// Only for `satellite` entries.
  let satelliteRoute: SatelliteRoute?

  enum Kind: String, Codable {
    case sun
    case moon
    case fixed_star
    case magnetic_north
    case satellite
  }

  enum SatelliteRoute: String, Codable, CaseIterable {
    case iss
    case hubble
    case jwst
  }
}

enum CelestialTargetsBundle {
  static func loadTargets() -> [CelestialTarget] {
    guard let url = Bundle.main.url(forResource: "CelestialTargets", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(CelestialTargetsPayload.self, from: data)
    else {
      return []
    }
    return payload.targets
  }
}

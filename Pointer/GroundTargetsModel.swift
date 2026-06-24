import Foundation

struct GroundTargetsPayload: Decodable {
  let schemaVersion: Int
  let targets: [GroundTarget]
}

struct GroundTarget: Decodable, Identifiable, Hashable {
  let id: String
  let displayName: String
  let group: String
  let latitude: Double
  let longitude: Double
  let notes: String
  let sources: [String]
}

/// Anchor class so `Bundle(for:)` resolves the app module bundle (matches SwiftUI previews / tests better than `Bundle.main` alone).
private final class GroundTargetsBundleAnchor: NSObject {}

enum GroundTargetsBundle {

  /// Last-resort catalog if no JSON is bundled or decoding fails (keeps Previews / partial targets from crashing).
  private static let embeddedFallbackData = Data(
    """
    {
      "schemaVersion": 1,
      "targets": [
        {
          "id": "fallback.north_pole",
          "displayName": "Geographic North Pole",
          "group": "seed_plan",
          "latitude": 90.0,
          "longitude": 0.0,
          "notes": "Embedded fallback — GroundTargets.json was missing or invalid in the bundle.",
          "sources": ["https://en.wikipedia.org/wiki/North_Pole"]
        }
      ]
    }
    """.utf8
  )

  static func loadTargets() -> [GroundTarget] {
    let bundles: [Bundle] = [Bundle.main, Bundle(for: GroundTargetsBundleAnchor.self)]
    for bundle in bundles {
      guard let url = bundle.url(forResource: "GroundTargets", withExtension: "json"),
            let data = try? Data(contentsOf: url)
      else { continue }

      if let targets = decodeTargets(from: data) {
        if !targets.isEmpty {
          return targets
        }
      }
    }

    if let targets = decodeTargets(from: embeddedFallbackData) {
      #if DEBUG
      print(
        "GroundTargets.json missing or failed to decode — using embedded fallback. Check target → Build Phases → Copy Bundle Resources and JSON syntax."
      )
      #endif
      return targets
    }

    return []
  }

  private static func decodeTargets(from data: Data) -> [GroundTarget]? {
    do {
      let payload = try JSONDecoder().decode(GroundTargetsPayload.self, from: data)
      return payload.targets
    } catch {
      #if DEBUG
      print("GroundTargets.json decode failed: \(error)")
      #endif
      return nil
    }
  }
}

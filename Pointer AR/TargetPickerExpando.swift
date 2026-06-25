import SwiftUI

/// Catalog selection: **ground** (WGS84) or **celestial** (Sun, fixed stars, …).
final class AimSession: ObservableObject {
  enum AimMode: Equatable {
    case ground(GroundTarget)
    case celestial(CelestialTarget)

    var title: String {
      switch self {
      case .ground(let t): return t.displayName
      case .celestial(let t): return t.displayName
      }
    }

    /// Stable id for `ScrollViewReader.scrollTo`.
    var pickableId: String {
      switch self {
      case .ground(let g): return "ground:\(g.id)"
      case .celestial(let c): return "cel:\(c.id)"
      }
    }
  }

  @Published var pickerExpanded = false
  @Published var aimMode: AimMode {
    didSet {
      UserDefaults.standard.set(aimMode.pickableId, forKey: Self.lastTargetKey)
    }
  }

  let groundCatalog: [GroundTarget]
  let celestialCatalog: [CelestialTarget]

  private static let lastTargetKey = "pointer.lastSelectedTarget"

  private static let groundGroupOrder = [
    "places",
    "poles",
  ]

  init() {
    groundCatalog = GroundTargetsBundle.loadTargets()
    celestialCatalog = CelestialTargetsBundle.loadTargets()

    let defaultMode: AimMode
    if let sun = celestialCatalog.first(where: { $0.kind == .sun }) {
      defaultMode = .celestial(sun)
    } else if let firstCelestial = celestialCatalog.first {
      defaultMode = .celestial(firstCelestial)
    } else if let firstGround = groundCatalog.first {
      defaultMode = .ground(firstGround)
    } else {
      preconditionFailure("Both GroundTargets.json and CelestialTargets.json failed to load any targets.")
    }

    if let savedId = UserDefaults.standard.string(forKey: Self.lastTargetKey),
       let restored = Self.findTarget(pickableId: savedId, ground: groundCatalog, celestial: celestialCatalog) {
      aimMode = restored
    } else {
      aimMode = defaultMode
    }
  }

  private static func findTarget(pickableId: String, ground: [GroundTarget], celestial: [CelestialTarget]) -> AimMode? {
    if pickableId.hasPrefix("ground:") {
      let id = String(pickableId.dropFirst("ground:".count))
      if let target = ground.first(where: { $0.id == id }) {
        return .ground(target)
      }
    } else if pickableId.hasPrefix("cel:") {
      let id = String(pickableId.dropFirst("cel:".count))
      if let target = celestial.first(where: { $0.id == id }) {
        return .celestial(target)
      }
    }
    return nil
  }

  private static let celestialGroupOrder = [
    "celestial_sky",
    "celestial_orbit",
  ]

  private static let skyOrder = [
    "sky.sun", "sky.mercury", "sky.venus", "sky.moon",
    "sky.mars", "sky.jupiter", "sky.saturn", "sky.polaris",
  ]

  var celestialSections: [(key: String, title: String, targets: [CelestialTarget])] {
    guard !celestialCatalog.isEmpty else { return [] }
    let grouped = Dictionary(grouping: celestialCatalog, by: \.group)
    return Self.celestialGroupOrder.compactMap { key in
      guard let list = grouped[key], !list.isEmpty else { return nil }
      let sorted: [CelestialTarget]
      if key == "celestial_sky" {
        let order = Self.skyOrder
        sorted = list.sorted { a, b in
          let ai = order.firstIndex(of: a.id) ?? Int.max
          let bi = order.firstIndex(of: b.id) ?? Int.max
          return ai < bi
        }
      } else {
        sorted = list.sorted {
          $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
      }
      return (key, Self.celestialSectionTitle(key), sorted)
    }
  }

  private static func celestialSectionTitle(_ key: String) -> String {
    switch key {
    case "celestial_sky": return "Sky"
    case "celestial_orbit": return "Satellites & spacecraft"
    default:
      return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  /// Celestial entries grouped under **More places** (same `seed_plan` key as ground seeds).
  var morePlacesCelestialTargets: [CelestialTarget] {
    celestialCatalog
      .filter { $0.group == "seed_plan" }
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  var groupedGroundCatalog: [(key: String, title: String, targets: [GroundTarget])] {
    let grouped = Dictionary(grouping: groundCatalog, by: \.group)
    return Self.groundGroupOrder.compactMap { key in
      guard let list = grouped[key], !list.isEmpty else { return nil }
      let sorted = list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      return (key, Self.groundSectionTitle(key), sorted)
    }
  }

  private static func groundSectionTitle(_ key: String) -> String {
    switch key {
    case "places": return "Places"
    case "poles": return "Poles"
    default: return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}

struct TargetPickerExpando: View {
  @ObservedObject var session: AimSession

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.28)) {
          session.pickerExpanded.toggle()
        }
      } label: {
        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Pointing at")
              .font(.caption.weight(.semibold))
              .tracking(0.6)
              .foregroundStyle(Color.white.opacity(0.92))
            Text(session.aimMode.title)
              .font(.title3.weight(.bold))
              .foregroundStyle(Color.white)
              .multilineTextAlignment(.leading)
              .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)


          }
          Spacer(minLength: 8)
          Image(systemName: session.pickerExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
            .font(.title2)
            .foregroundStyle(Color.white.opacity(0.88))
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(.plain)

      if session.pickerExpanded {
        Divider()
          .overlay(Color.white.opacity(0.14))
          .padding(.vertical, 12)

        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              ForEach(session.celestialSections, id: \.key) { section in
                celestialSection(title: section.title, targets: section.targets)
              }
              ForEach(session.groupedGroundCatalog, id: \.key) { section in
                if section.key == "seed_plan" {
                  morePlacesSection(
                    title: section.title,
                    celestialExtras: session.morePlacesCelestialTargets,
                    groundTargets: section.targets
                  )
                } else {
                  groundSection(title: section.title, targets: section.targets)
                }
              }
            }
            .padding(.bottom, 6)
            .onAppear {
              scrollSelectionIntoView(proxy: proxy)
            }
          }
          .frame(maxHeight: 320)
        }
      }
    }
    .padding(14)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.black.opacity(0.62))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }
    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Pointing at, \(session.aimMode.title)")
  }

  private func scrollSelectionIntoView(proxy: ScrollViewProxy) {
    let id = session.aimMode.pickableId
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(32))
      withAnimation(.easeInOut(duration: 0.28)) {
        proxy.scrollTo(id, anchor: .center)
      }
    }
  }

  private func celestialSection(title: String, targets: [CelestialTarget]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(title)
      ForEach(targets) { target in
        selectRow(
          title: target.displayName,
          subtitle: nil,
          selected: {
            if case .celestial(let t) = session.aimMode { return t.id == target.id }
            return false
          }()
        ) {
          session.aimMode = .celestial(target)
          session.pickerExpanded = false
        }
        .id("cel:\(target.id)")
      }
    }
  }

  private func morePlacesSection(
    title: String,
    celestialExtras: [CelestialTarget],
    groundTargets: [GroundTarget]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(title)
      ForEach(celestialExtras) { target in
        selectRow(
          title: target.displayName,
          subtitle: nil,
          selected: {
            if case .celestial(let t) = session.aimMode { return t.id == target.id }
            return false
          }()
        ) {
          session.aimMode = .celestial(target)
          session.pickerExpanded = false
        }
        .id("cel:\(target.id)")
      }
      ForEach(groundTargets) { target in
        selectRow(
          title: target.displayName,
          subtitle: nil,
          selected: {
            if case .ground(let t) = session.aimMode { return t.id == target.id }
            return false
          }()
        ) {
          session.aimMode = .ground(target)
          session.pickerExpanded = false
        }
        .id("ground:\(target.id)")
      }
    }
  }

  private func groundSection(title: String, targets: [GroundTarget]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(title)
      ForEach(targets) { target in
        selectRow(
          title: target.displayName,
          subtitle: nil,
          selected: {
            if case .ground(let t) = session.aimMode { return t.id == target.id }
            return false
          }()
        ) {
          session.aimMode = .ground(target)
          session.pickerExpanded = false
        }
        .id("ground:\(target.id)")
      }
    }
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(Color.white.opacity(0.72))
      .textCase(.uppercase)
      .tracking(0.5)
  }

  private func selectRow(title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.leading)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(Color.white.opacity(0.65))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Selected")
        }
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
      }
    }
    .buttonStyle(.plain)
  }
}

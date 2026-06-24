import CoreLocation
import SwiftUI

/// Device GPS, selected target, and hints (great-circle vs celestial altitude/azimuth).
struct PointerInfoSheet: View {
  @ObservedObject var location: LocationService
  @ObservedObject var aimSession: AimSession
  @ObservedObject var overlaySettings: PointerDisplaySettings
  var openSettings: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          deviceLocationSection
        } header: {
          Text("This device")
        }

        Section {
          targetSection
        } header: {
          Text("Selected target")
        }

        Section {
          relativeSection
        } header: {
          Text("Relative to you")
        } footer: {
          footerCopy
            .font(.caption)
        }

        Section {
          Toggle("Show arrow", isOn: binding(\.showArrow))
          Toggle("Show compass bezel", isOn: binding(\.showAzimuthDisk))
          Toggle("Show azimuth readout", isOn: binding(\.showAzimuthNumber))
          Toggle("Show elevation readout", isOn: binding(\.showElevationNumber))
        } header: {
          Text("On-screen overlay")
        }

        Section {
          Text("Heading accuracy may be reduced inside vehicles, near large metal objects, or close to strong magnetic fields. The compass uses your device's magnetometer, which is sensitive to nearby interference.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
          Text("Heading accuracy")
        }
      }
      .navigationTitle("Details")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }

  private var footerCopy: Text {
    switch aimSession.aimMode {
    case .ground:
      return Text(
        "Distance and initial bearing use a spherical-Earth great circle. The arrow aims along the straight chord in WGS84 (surface points → ECEF → local east/north/up), so distant targets pick up a slight tilt below the astronomical horizon."
      )
    case .celestial(let t):
      switch t.kind {
      case .satellite:
        return Text(
          "Network ephemerides (CelesTrak/ISS API or JPL Horizons) with your GPS. Hubble uses a coarse Kepler model; JWST uses JPL azimuth and elevation at your site. Expect errors larger than compass noise — not for mission planning."
        )
      case .magnetic_north:
        return Text(
          "Magnetic north uses WMM-2025 declination, inclination (dip), and the full field direction at your latitude, longitude, and ellipsoid height. The arrow is drawn in a true-north Core Motion frame; compare to a calibrated magnetometer separately."
        )
      case .sun, .moon, .fixed_star:
        return Text(
          "Altitude and azimuth use your GPS position and current UTC with a simplified ephemeris (Sun/Moon) or catalog RA/Dec (stars). Refraction and high-precision reductions are omitted."
        )
      }
    }
  }

  @ViewBuilder
  private var deviceLocationSection: some View {
    switch location.authorizationStatus {
    case .notDetermined:
      Label("Waiting for permission — respond to the system location prompt.", systemImage: "location.circle")
    case .restricted:
      restrictedLabel(isRestricted: true)
    case .denied:
      restrictedLabel(isRestricted: false)
    case .authorizedAlways, .authorizedWhenInUse:
      if let fix = location.lastLocation {
        VStack(alignment: .leading, spacing: 8) {
          Text(formatCoordinateLine(fix))
            .font(.body.monospacedDigit())
          Text("Horizontal accuracy ±\(Int(fix.horizontalAccuracy)) m")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let err = location.lastError {
            Text(err.localizedDescription)
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      } else {
        Label("Authorized — waiting for first GPS fix.", systemImage: "antenna.radiowaves.left.and.right")
      }
    @unknown default:
      Text("Unknown authorization state.")
    }
  }

  private func restrictedLabel(isRestricted: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(isRestricted ? "Location is restricted on this device." : "Location access was denied for Pointer.")
      Button("Open Settings", action: openSettings)
        .buttonStyle(.borderedProminent)
    }
  }

  @ViewBuilder
  private var targetSection: some View {
    switch aimSession.aimMode {
    case .ground(let t):
      VStack(alignment: .leading, spacing: 8) {
        Text(t.displayName)
          .font(.headline)
        Text(formatLatLon(latitude: t.latitude, longitude: t.longitude))
          .font(.body.monospacedDigit())
        Text(t.notes)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .celestial(let t):
      VStack(alignment: .leading, spacing: 8) {
        Text(t.displayName)
          .font(.headline)
        Text(t.notes)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var relativeSection: some View {
    switch aimSession.aimMode {
    case .ground(let t):
      groundRelativeContent(target: t)
    case .celestial(let t):
      celestialRelativeContent(target: t)
    }
  }

  @ViewBuilder
  private func groundRelativeContent(target: GroundTarget) -> some View {
    if location.isAuthorized, let fix = location.lastLocation {
      let from = fix.coordinate
      let to = CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude)
      let origin = CLLocation(latitude: from.latitude, longitude: from.longitude)
      let dest = CLLocation(latitude: to.latitude, longitude: to.longitude)
      let meters = origin.distance(from: dest)
      let bearing = Geodesy.initialBearingDegrees(from: from, to: to)

      VStack(alignment: .leading, spacing: 8) {
        if meters >= 1000 {
          Text("\(String(format: "%.2f", meters / 1000)) km apart (great-circle)")
        } else {
          Text("\(Int(round(meters))) m apart (great-circle)")
        }
        Text("Initial bearing \(bearingFormatted(bearing)) (clockwise from north)")
          .font(.body.monospacedDigit())
      }
    } else if !location.isAuthorized {
      Text("Allow location to compute distance and bearing toward this place.")
        .foregroundStyle(.secondary)
    } else {
      Text("Waiting for a GPS fix to compute distance and bearing.")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func celestialRelativeContent(target: CelestialTarget) -> some View {
    if location.isAuthorized, let fix = location.lastLocation {
      let now = Date()
      if target.kind == .satellite {
        Text(
          "Ephemeris is fetched over the network while this target is selected (see footer). Allow a short moment after picking ISS, Hubble, or JWST."
        )
        .foregroundStyle(.secondary)
      } else if target.kind == .magnetic_north,
                let survey = WorldMagneticModel.geomagneticSurvey(
                  latitudeDeg: fix.coordinate.latitude,
                  longitudeDeg: fix.coordinate.longitude,
                  heightKilometers: fix.altitude / 1000,
                  at: now
                ) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Magnetic declination \(angleFormatted(survey.declinationDegrees))° east of true north")
            .font(.body.monospacedDigit())
          Text("Magnetic inclination (dip) \(angleFormatted(survey.inclinationDegrees))° below horizontal")
            .font(.body.monospacedDigit())
          Text("Computed at \(utcTimeFormatter.string(from: now)) UTC · WMM-2025 · ellipsoid height \(Int(round(fix.altitude))) m")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let horiz = TopocentricAstronomy.apparentHorizontalDegrees(
        target: target,
        observer: fix.coordinate,
        at: now,
        ellipsoidHeightMeters: fix.altitude
      ) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Altitude \(angleFormatted(horiz.altitudeDeg)) (mathematical horizon)")
            .font(.body.monospacedDigit())
          Text("Azimuth \(angleFormatted(horiz.azimuthDeg))° (clockwise from true north)")
            .font(.body.monospacedDigit())
          Text("Computed at \(utcTimeFormatter.string(from: now)) UTC")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("This target is not available in the current build.")
          .foregroundStyle(.secondary)
      }
    } else if !location.isAuthorized {
      Text("Allow location to compute sky direction from your position.")
        .foregroundStyle(.secondary)
    } else {
      Text("Waiting for a GPS fix to compute altitude and azimuth.")
        .foregroundStyle(.secondary)
    }
  }

  private var utcTimeFormatter: DateFormatter {
    let f = DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }

  private func formatCoordinateLine(_ fix: CLLocation) -> String {
    formatLatLon(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
  }

  private func formatLatLon(latitude: Double, longitude: Double) -> String {
    let latH = latitude >= 0 ? "N" : "S"
    let lonH = longitude >= 0 ? "E" : "W"
    return String(
      format: "%.6f° %@ · %.6f° %@",
      abs(latitude), latH, abs(longitude), lonH
    )
  }

  private func bearingFormatted(_ degrees: Double) -> String {
    String(format: "%.1f°", degrees)
  }

  private func angleFormatted(_ degrees: Double) -> String {
    String(format: "%.1f°", degrees)
  }

  private func binding(_ keyPath: ReferenceWritableKeyPath<PointerDisplaySettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { overlaySettings[keyPath: keyPath] },
      set: { overlaySettings[keyPath: keyPath] = $0 }
    )
  }
}

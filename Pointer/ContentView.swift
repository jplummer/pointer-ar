import CoreLocation
import SwiftUI
import UIKit
import simd

enum WaitReason {
  case notDetermined
  case denied
  case waitingForGPS
  case loadingEphemeris
  case reacquiringGPS
  case none

  var label: String? {
    switch self {
    case .notDetermined: return "Location access needed"
    case .denied: return nil
    case .waitingForGPS: return "Finding position..."
    case .loadingEphemeris: return "Loading orbit data..."
    case .reacquiringGPS: return "Reacquiring position..."
    case .none: return nil
    }
  }

  var iconName: String? {
    switch self {
    case .notDetermined: return "location.slash"
    case .denied: return nil
    case .waitingForGPS, .reacquiringGPS: return "antenna.radiowaves.left.and.right"
    case .loadingEphemeris: return "arrow.down.circle"
    case .none: return nil
    }
  }

  var spinnerDuration: Double {
    switch self {
    case .loadingEphemeris: return 2.0
    default: return 1.0
    }
  }
}

@MainActor
struct ContentView: View {
  @StateObject private var aimSession = AimSession()
  @StateObject private var location = LocationService()
  @StateObject private var satelliteStore = SatelliteAimStore()
  @StateObject private var overlaySettings = PointerDisplaySettings()
  @StateObject private var previewRotationSync = PreviewRotationState()
  @State private var isInfoPresented = false
  @State private var arrowSceneReady = false
  /// True once the app has received at least one GPS fix this session.
  @State private var hadGPSFix = false
  /// Branded cover shown during initialization; dismissed when SceneKit renders.
  @State private var showBrandedCover = true
  @State private var brandedCoverMinElapsed = false
  /// Camera opacity animates from 0 to 1 when the branded cover dismisses.
  @State private var cameraOpacity: Double = 0
  /// Debounces satellite ephemeris refetch when GPS moves; pointer math still uses the latest fix immediately.
  @State private var satellitePrefetchDebounceTask: Task<Void, Never>?
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { timeline in
      let _ = (
        satelliteStore.issENU,
        satelliteStore.hubbleENU,
        satelliteStore.jwstENU,
        satelliteStore.lastISSGP,
        satelliteStore.lastHubbleGP
      )
      let _ = (
        overlaySettings.showArrow,
        overlaySettings.showAzimuthDisk,
        overlaySettings.showAzimuthNumber,
        overlaySettings.showElevationNumber
      )
      let satelliteENU = satelliteArrowENU(at: timeline.date)
      let aimReady = arrowDirectionResolved(satelliteENU: satelliteENU, at: timeline.date)
      let satWait = satelliteEphemerisWait(satelliteENU: satelliteENU)
      let orientationRingShowsWait =
        !arrowSceneReady || satWait || !aimReady
      let waitReason = computeWaitReason(satelliteENU: satelliteENU, aimReady: aimReady)

      ZStack {
        CameraPreviewView(previewRotation: previewRotationSync)
          .ignoresSafeArea()
          .opacity(cameraOpacity)

        ArrowSceneView(
          aimMode: aimSession.aimMode,
          pickableId: aimSession.aimMode.pickableId,
          userCoordinate: location.lastLocation?.coordinate,
          aimInstant: timeline.date,
          satelliteENU: satelliteENU,
          observerEllipsoidHeightMeters: location.lastLocation?.altitude ?? 0,
          overlaySettings: overlaySettings,
          previewRotation: previewRotationSync,
          sceneRenderingReady: arrowSceneReady,

          orientationRingShowsWait: orientationRingShowsWait,
          spinnerDuration: waitReason.spinnerDuration,
          isSceneReady: $arrowSceneReady
        )
        .ignoresSafeArea()
        .task(id: aimSession.aimMode.pickableId) {
          await prefetchSatelliteEphemeris(at: Date())
        }
        .onChange(of: timeline.date) { _, date in
          Task {
            await prefetchSatelliteEphemeris(at: date)
          }
        }
        .onChange(of: location.lastLocation?.timestamp) { _, newValue in
          if newValue != nil && !hadGPSFix {
            hadGPSFix = true
          }
          satellitePrefetchDebounceTask?.cancel()
          satellitePrefetchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await prefetchSatelliteEphemeris(at: Date())
          }
        }

        VStack(spacing: 0) {
          TargetPickerExpando(session: aimSession)
            .padding(.horizontal, 16)
            .padding(.top, 12)

          Spacer(minLength: 0)

          if waitReason == .denied && !showBrandedCover {
            authDeniedPanel
          }

          waitReasonLabel(waitReason)

          azimuthElevationReadout(
            timelineDate: timeline.date,
            satelliteENU: satelliteENU,
            aimReady: aimReady
          )

          HStack {
            infoButton
            Spacer(minLength: 0)
          }
          .padding(.leading, 12)
          .padding(.bottom, 16)
        }
        if showBrandedCover {
          brandedCoverView
            .transition(.opacity)
        }
      }
    }
    .onAppear {
      location.begin()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        location.begin()
      } else {
        location.stop()
      }
    }
    .task {
      try? await Task.sleep(for: .seconds(1))
      brandedCoverMinElapsed = true
      dismissBrandedCoverIfReady()
    }
    .task {
      try? await Task.sleep(for: .seconds(3))
      if !arrowSceneReady {
        arrowSceneReady = true
      }
      dismissBrandedCoverIfReady()
    }
    .onChange(of: arrowSceneReady) { _, ready in
      if ready {
        dismissBrandedCoverIfReady()
      }
    }
    .sheet(isPresented: $isInfoPresented) {
      PointerInfoSheet(
        location: location,
        aimSession: aimSession,
        overlaySettings: overlaySettings,
        openSettings: {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
          }
        }
      )
    }
  }

  @ViewBuilder
  private func azimuthElevationReadout(
    timelineDate: Date,
    satelliteENU: simd_float3?,
    aimReady: Bool
  ) -> some View {
    if arrowSceneReady,
       aimReady,
       overlaySettings.showAzimuthNumber || overlaySettings.showElevationNumber,
       let fix = location.lastLocation,
       let ae = AimHorizonAngles.azimuthElevationDegrees(
         aimMode: aimSession.aimMode,
         userCoordinate: fix.coordinate,
         aimInstant: timelineDate,
         satelliteENU: satelliteENU,
         ellipsoidHeightMeters: fix.altitude
       ) {
      VStack(spacing: 6) {
        HStack(spacing: 18) {
          if overlaySettings.showAzimuthNumber {
            Text("Az \(formatAzimuthDegrees(ae.azimuthDeg))")
              .font(.subheadline.weight(.semibold).monospacedDigit())
              .foregroundStyle(.white)
          }
          if overlaySettings.showElevationNumber {
            Text("El \(formatElevationDegrees(ae.elevationDeg))")
              .font(.subheadline.weight(.semibold).monospacedDigit())
              .foregroundStyle(.white)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
          Capsule(style: .continuous)
            .fill(Color.black.opacity(0.52))
            .overlay {
              Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
        }

        if headingUnreliable(computedAzDeg: ae.azimuthDeg) {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
            Text("Azimuth may be off — magnetic interference")
              .font(.caption2.weight(.medium))
          }
          .foregroundStyle(.yellow.opacity(0.85))
          .transition(.opacity)
        }
      }
      .padding(.bottom, 8)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Azimuth and elevation readout")
    }
  }

  private func headingUnreliable(computedAzDeg: Double) -> Bool {
    guard let heading = location.lastHeading else { return false }
    return heading.headingAccuracy < 0 || heading.headingAccuracy > 50
  }

  private func formatAzimuthDegrees(_ deg: Double) -> String {
    String(format: "%.0f°", deg)
  }

  private func formatElevationDegrees(_ deg: Double) -> String {
    String(format: "%+.0f°", deg)
  }

  private func arrowDirectionResolved(satelliteENU: simd_float3?, at date: Date) -> Bool {
    switch aimSession.aimMode {
    case .ground(let target):
      guard let fix = location.lastLocation else { return false }
      let dest = CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude)
      let origin = CLLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
      let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
      guard origin.distance(from: destLoc) >= 3 else { return false }
      return Geodesy.trueNorthENUChordUnit(from: fix.coordinate, to: dest) != nil

    case .celestial(let t):
      guard let fix = location.lastLocation else { return false }
      if t.kind == .satellite {
        return satelliteENU != nil
      }
      if TopocentricAstronomy.apparentHorizontalDegrees(
        target: t,
        observer: fix.coordinate,
        at: date,
        ellipsoidHeightMeters: fix.altitude
      ) != nil {
        return true
      }
      return TopocentricAstronomy.enuForCelestialCatalog(
        t,
        observer: fix.coordinate,
        at: date,
        ellipsoidHeightMeters: fix.altitude
      ) != nil
    }
  }

  private func satelliteEphemerisWait(satelliteENU: simd_float3?) -> Bool {
    guard arrowSceneReady else { return false }
    guard case .celestial(let t) = aimSession.aimMode,
          t.kind == .satellite,
          t.satelliteRoute != nil,
          location.lastLocation != nil
    else { return false }
    return satelliteENU == nil
  }

  private func prefetchSatelliteEphemeris(at date: Date) async {
    await satelliteStore.prefetchIfNeeded(
      aimMode: aimSession.aimMode,
      observer: location.lastLocation?.coordinate,
      altitudeMeters: location.lastLocation?.altitude,
      at: date
    )
  }

  private func satelliteArrowENU(at date: Date) -> simd_float3? {
    guard case .celestial(let t) = aimSession.aimMode,
          t.kind == .satellite,
          let route = t.satelliteRoute,
          let fix = location.lastLocation
    else { return nil }
    return satelliteStore.staleENU(
      route: route,
      observer: fix.coordinate,
      heightAboveEllipsoidMeters: fix.altitude,
      at: date
    )
  }

  private func computeWaitReason(satelliteENU: simd_float3?, aimReady: Bool) -> WaitReason {
    if !location.isAuthorized {
      if location.authorizationStatus == .notDetermined {
        return .notDetermined
      }
      return .denied
    }
    if location.lastLocation == nil {
      return hadGPSFix ? .reacquiringGPS : .waitingForGPS
    }
    if let loc = location.lastLocation, Date().timeIntervalSince(loc.timestamp) > 30 {
      return .reacquiringGPS
    }
    if satelliteEphemerisWait(satelliteENU: satelliteENU) {
      return .loadingEphemeris
    }
    if !aimReady {
      return .waitingForGPS
    }
    return .none
  }

  @ViewBuilder
  private func waitReasonLabel(_ reason: WaitReason) -> some View {
    if let text = reason.label, !showBrandedCover {
      HStack(spacing: 8) {
        if let icon = reason.iconName {
          Image(systemName: icon)
            .font(.caption)
        }
        Text(text)
          .font(.caption.weight(.medium))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background {
        Capsule(style: .continuous)
          .fill(Color.black.opacity(0.52))
          .overlay {
            Capsule(style: .continuous)
              .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
          }
      }
      .transition(.opacity)
    }
  }

  private var authDeniedPanel: some View {
    VStack(spacing: 16) {
      Image(systemName: "location.slash")
        .font(.title2)
        .foregroundStyle(.white.opacity(0.7))
      Text("Pointer needs your location to calculate direction. Open Settings and enable Location Services for this app.")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.9))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          openURL(url)
        }
      } label: {
        Text("Open Settings")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
          .background {
            Capsule(style: .continuous)
              .fill(Color.white.opacity(0.18))
              .overlay {
                Capsule(style: .continuous)
                  .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
              }
          }
      }
      .buttonStyle(.plain)
    }
    .padding(24)
    .frame(maxWidth: 300)
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.black.opacity(0.72))
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }
    .transition(.opacity)
  }

  private func dismissBrandedCoverIfReady() {
    guard showBrandedCover, brandedCoverMinElapsed, arrowSceneReady else { return }
    withAnimation(.easeInOut(duration: 0.4)) {
      showBrandedCover = false
      cameraOpacity = 1
    }
  }

  private var brandedCoverView: some View {
    ZStack {
      Color.black
      VStack(spacing: 12) {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(.white.opacity(0.9))
        Text("Pointer")
          .font(.title2.weight(.medium))
          .foregroundStyle(.white.opacity(0.9))
      }
    }
    .ignoresSafeArea()
  }

  private var infoButton: some View {
    Button {
      isInfoPresented = true
    } label: {
      Image(systemName: "info.circle.fill")
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.white)
        .padding(10)
        .background {
          Circle()
            .fill(Color.black.opacity(0.55))
            .overlay {
              Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Details: location, target, and settings")
  }
}

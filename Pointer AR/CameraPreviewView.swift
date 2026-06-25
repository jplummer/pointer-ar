import AVFoundation
import Combine
import OSLog
import SwiftUI
import UIKit

/// Published **`videoRotationAngle`** target (degrees) from `AVCaptureDevice.RotationCoordinator`, for aligning SceneKit with the preview layer (Option B). Updated on the main queue only.
final class PreviewRotationState: ObservableObject {
  @Published private(set) var videoRotationDegrees: CGFloat = 0

  func setVideoRotationDegrees(_ degrees: CGFloat) {
    guard abs(videoRotationDegrees - degrees) > 0.01 else { return }
    videoRotationDegrees = degrees
  }
}

/// Live camera backdrop (rear wide). Session starts after video authorization.
struct CameraPreviewView: UIViewRepresentable {
  @ObservedObject var previewRotation: PreviewRotationState

  func makeCoordinator() -> Coordinator {
    Coordinator(previewRotation: previewRotation)
  }

  func makeUIView(context: Context) -> UIView {
#if targetEnvironment(simulator)
    let placeholder = UIView()
    placeholder.backgroundColor = .black
    return placeholder
#else
    let host = PreviewHost()
    host.rotationOwner = context.coordinator
    context.coordinator.previewHost = host
    context.coordinator.previewLayer = host.previewLayer
    context.coordinator.configureIfAuthorized()
    return host
#endif
  }

  func updateUIView(_ uiView: UIView, context: Context) {}

  static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
#if !targetEnvironment(simulator)
    coordinator.shutdown()
#endif
  }

  final class Coordinator {
    private let previewRotation: PreviewRotationState
    let session = AVCaptureSession()

    init(previewRotation: PreviewRotationState) {
      self.previewRotation = previewRotation
    }
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    weak var previewHost: PreviewHost?
    private var configured = false
    private var captureDevice: AVCaptureDevice?
    /// Keeps preview rotation aligned with gravity / device motion (same idea as SceneKit’s stabilized frame).
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// Recreate `RotationCoordinator` when scene orientation or aspect changes so preview angles stay coherent (stale coordinator can disagree across transitions).
    private var lastRotationLayoutKey: (landscape: Bool, ioRaw: Int)?
#if DEBUG
    private var rotationRefreshCount = 0
    private static let rotationLog = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "Pointer",
      category: "CameraRotation"
    )
#endif

    func configureIfAuthorized() {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        configureSessionAndRun()
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async {
            guard granted else { return }
            self.configureSessionAndRun()
          }
        }
      default:
        break
      }
    }

    func configureSessionAndRun() {
      guard !configured else {
        DispatchQueue.global(qos: .userInitiated).async { [session] in
          if !session.isRunning {
            session.startRunning()
          }
        }
        DispatchQueue.main.async { [weak self] in
          self?.refreshPreviewRotation(source: "configureSessionAndRun(alreadyConfigured)")
        }
        return
      }

      session.beginConfiguration()
      session.sessionPreset = .high

      guard
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
        let input = try? AVCaptureDeviceInput(device: device),
        session.canAddInput(input)
      else {
        session.commitConfiguration()
        return
      }
      session.addInput(input)
      session.commitConfiguration()
      configured = true
      captureDevice = device

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.previewLayer?.session = self.session
        self.rebuildRotationCoordinatorIfNeeded(source: "configureSessionAndRun(firstConfig)")
        self.refreshPreviewRotation(source: "configureSessionAndRun(firstConfig)")
      }

      DispatchQueue.global(qos: .userInitiated).async { [session] in
        if !session.isRunning {
          session.startRunning()
        }
      }
    }

    /// Uses `AVCaptureDevice.RotationCoordinator` so preview rotation tracks **horizon level** preview angles (avoids manual UI-orientation mapping errors in landscape).
    private func rebuildRotationCoordinatorIfNeeded(source: String) {
      guard let device = captureDevice,
            let layer = previewLayer
      else {
        rotationCoordinator = nil
#if DEBUG
        Self.rotationLog.debug("rebuildRotationCoordinator skipped (\(source)) — missing device or layer")
#endif
        return
      }
      rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
#if DEBUG
      Self.rotationLog.debug("rebuildRotationCoordinator (\(source)) — created new RotationCoordinator")
#endif
    }

    func refreshPreviewRotation(source: String) {
      guard let connection = previewLayer?.connection else {
#if DEBUG
        Self.rotationLog.debug("refreshPreviewRotation (\(source)) — no connection")
#endif
        return
      }

      let host = previewHost
      let bounds = host?.bounds ?? .zero
      let scene = host?.window?.windowScene
      let landscape = bounds.width > bounds.height
      let ioRaw = scene?.interfaceOrientation.rawValue ?? -1
      let layoutKey = (landscape: landscape, ioRaw: ioRaw)
      if lastRotationLayoutKey?.landscape != layoutKey.landscape || lastRotationLayoutKey?.ioRaw != layoutKey.ioRaw {
        lastRotationLayoutKey = layoutKey
        rotationCoordinator = nil
        rebuildRotationCoordinatorIfNeeded(source: "refreshPreviewRotation(layoutKeyChanged)")
      } else if rotationCoordinator == nil {
        rebuildRotationCoordinatorIfNeeded(source: "refreshPreviewRotation(coordinatorNil)")
      }
      guard let coord = rotationCoordinator else {
#if DEBUG
        Self.rotationLog.debug("refreshPreviewRotation (\(source)) — still no RotationCoordinator")
#endif
        return
      }

      let previewAngle = coord.videoRotationAngleForHorizonLevelPreview
      let captureAngle = coord.videoRotationAngleForHorizonLevelCapture
      let prevApplied = connection.videoRotationAngle
      let supported = connection.isVideoRotationAngleSupported(previewAngle)

      let io = scene?.interfaceOrientation
      let ioDesc = io.map { String(describing: $0) } ?? "nil"
      let sessionRunning = session.isRunning

#if DEBUG
      rotationRefreshCount += 1
      let n = rotationRefreshCount
      let delta = abs(prevApplied - previewAngle)
      if n <= 50 || delta > 0.25 || !supported {
        Self.rotationLog.debug(
          "refresh #\(n) source=\(source) sessionRunning=\(sessionRunning) uiBounds=\(Int(bounds.width))x\(Int(bounds.height)) interfaceOrientation=\(ioDesc) prevAngle=\(String(format: "%.2f", prevApplied))° targetPreview=\(String(format: "%.2f", previewAngle))° targetCapture=\(String(format: "%.2f", captureAngle))° supported=\(supported) delta=\(String(format: "%.2f", delta))°"
        )
      }
#endif

      guard supported else {
#if DEBUG
        Self.rotationLog.error("refreshPreviewRotation — angle \(previewAngle)° not supported on connection")
#endif
        return
      }

      previewRotation.setVideoRotationDegrees(CGFloat(previewAngle))

      if abs(prevApplied - previewAngle) < 0.01 {
#if DEBUG
        if rotationRefreshCount <= 8 {
          Self.rotationLog.debug("refreshPreviewRotation — skip apply (already ~\(String(format: "%.2f", previewAngle))°)")
        }
#endif
        return
      }

      connection.videoRotationAngle = previewAngle
#if DEBUG
      Self.rotationLog.notice(
        "APPLIED videoRotationAngle \(String(format: "%.2f", previewAngle))° (was \(String(format: "%.2f", prevApplied))°) source=\(source)"
      )
#endif
    }

    func shutdown() {
      DispatchQueue.global(qos: .userInitiated).async { [session] in
        if session.isRunning {
          session.stopRunning()
        }
      }
    }

    deinit {
      shutdown()
    }
  }

  final class PreviewHost: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    weak var rotationOwner: Coordinator?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = false
      backgroundColor = .black
      previewLayer.videoGravity = .resizeAspectFill
      layer.insertSublayer(previewLayer, at: 0)
    }

    required init?(coder: NSCoder) {
      nil
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      previewLayer.frame = bounds
      rotationOwner?.refreshPreviewRotation(source: "PreviewHost.layoutSubviews")
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      rotationOwner?.refreshPreviewRotation(source: "PreviewHost.didMoveToWindow")
    }
  }
}

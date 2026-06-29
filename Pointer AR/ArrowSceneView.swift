import CoreLocation
import CoreMotion
import SceneKit
import SwiftUI
import UIKit
import simd

/// Core Motion + SceneKit overlay for aim direction.
///
/// **Camera lock:** `videoRotationAngle` rotates pixels inside the preview layer. The SceneKit scene lives in **portrait window** axes, while the connection reports ~**90°** in portrait (sensor vs window). Use **`transform` = rotation by (angle − 90°)** so portrait stays **identity** and landscape applies only the **delta** from portrait-up — full angle would double the portrait correction and read as a vertical azimuth disc.
///
/// **World:** `simd_inverse(device)` on the stabilized root keeps ENU aim/tangent plane stable while the phone moves.
struct ArrowSceneView: UIViewRepresentable {
  var aimMode: AimSession.AimMode
  var pickableId: String
  var userCoordinate: CLLocationCoordinate2D?
  /// UTC instant for Sun / star-field rotation (pass from `TimelineView`).
  var aimInstant: Date
  /// Populated for catalog entries that use HTTPS ephemerides (ISS / Hubble / JWST).
  var satelliteENU: simd_float3?
  /// WGS84 ellipsoid height for magnetic-field evaluation (GPS altitude when available).
  var observerEllipsoidHeightMeters: Double
  @ObservedObject var overlaySettings: PointerDisplaySettings
  /// Same **`videoRotationAngle`** basis as `AVCaptureVideoPreviewLayer` so the overlay stays locked to the camera image (Option B).
  @ObservedObject var previewRotation: PreviewRotationState
  /// First SceneKit frame has been rendered.
  var sceneRenderingReady: Bool
  /// Valid aim direction for the current target (GPS + geometry / ephemeris as required).

  /// When true, show the flat wait spinner (not the azimuth plate): scene not ready, satellite ephemeris still loading, aim not resolved yet, or target change until the first successful az/el for that selection (`ContentView`).
  var orientationRingShowsWait: Bool
  /// Spinner revolution duration in seconds (1.0 for GPS wait, 2.0 for ephemeris load).
  var spinnerDuration: Double
  @Binding var isSceneReady: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.isOpaque = false
    view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X
    view.allowsCameraControl = false

    let scene = SCNScene()
    scene.background.contents = UIColor.clear
    view.scene = scene
    view.autoenablesDefaultLighting = true

    // Capture coordinator early so the background handler can reset motion state.
    let coordinator = context.coordinator

    // On background: reset motionStarted so the next sync() call restarts
    // CMMotionManager, which stops delivering updates when the app is suspended.
    // We do NOT pause isPlaying here — toggling the SceneKit play state can leave
    // the Metal render pipeline in a state where depth writes work but color output
    // fails on resume (arrow invisible but still cutting holes in the disc). Since
    // this app has no background modes, iOS suspends it immediately on background
    // anyway, so isPlaying = false accomplishes nothing except creating the problem.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak coordinator] _ in coordinator?.motionStarted = false }
    // Keep SceneKit advancing SCNActions; otherwise wait-spinner animation can appear frozen.
    view.isPlaying = true

    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.position = SCNVector3(0, 0, 6)
    cameraNode.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    scene.rootNode.addChildNode(cameraNode)

    let stabilized = SCNNode()
    scene.rootNode.addChildNode(stabilized)

    let flatSpinner = Coordinator.buildFlatDiskSpinnerNode()
    stabilized.addChildNode(flatSpinner)

    let horizon = Coordinator.buildHorizonDiskNode()
    stabilized.addChildNode(horizon)

    let arrow = Coordinator.buildArrowNode()
    stabilized.addChildNode(arrow)

    coordinator.arrowNode = arrow
    coordinator.flatDiskSpinnerRoot = flatSpinner
    coordinator.horizonDiskRoot = horizon
    coordinator.targetAzimuthPivot = horizon.childNode(withName: "targetAzimuthPivot", recursively: true)
    coordinator.stabilizedNode = stabilized
    coordinator.readyBinding = $isSceneReady
    coordinator.sync(
      aimMode: aimMode,
      pickableId: pickableId,
      userCoordinate: userCoordinate,
      aimInstant: aimInstant,
      satelliteENU: satelliteENU,
      observerEllipsoidHeightMeters: observerEllipsoidHeightMeters,
      overlaySettings: overlaySettings,
      sceneRenderingReady: sceneRenderingReady,

      orientationRingShowsWait: orientationRingShowsWait,
      spinnerDuration: spinnerDuration
    )
    Self.applyPreviewVideoAngleToViewTransform(view, degrees: previewRotation.videoRotationDegrees)
    view.delegate = coordinator
    return view
  }

  func updateUIView(_ uiView: SCNView, context: Context) {
    Self.applyPreviewVideoAngleToViewTransform(uiView, degrees: previewRotation.videoRotationDegrees)
    context.coordinator.readyBinding = $isSceneReady
    context.coordinator.sync(
      aimMode: aimMode,
      pickableId: pickableId,
      userCoordinate: userCoordinate,
      aimInstant: aimInstant,
      satelliteENU: satelliteENU,
      observerEllipsoidHeightMeters: observerEllipsoidHeightMeters,
      overlaySettings: overlaySettings,
      sceneRenderingReady: sceneRenderingReady,

      orientationRingShowsWait: orientationRingShowsWait,
      spinnerDuration: spinnerDuration
    )
  }

  /// Maps connection angle to **`SCNView.transform`**: subtract portrait baseline **90°** so overlay rotation matches camera **without** re-applying the portrait sensor/window correction on top of SceneKit’s portrait layout.
  private static func applyPreviewVideoAngleToViewTransform(_ scnView: SCNView, degrees: CGFloat) {
#if targetEnvironment(simulator)
    scnView.transform = .identity
#else
    let relativeDegrees = degrees - 90
    let radians = relativeDegrees * (.pi / 180)
    if abs(radians) < 0.0005 {
      scnView.transform = .identity
      return
    }
    scnView.transform = CGAffineTransform(rotationAngle: radians)
#endif
  }

  final class Coordinator: NSObject, SCNSceneRendererDelegate {
    fileprivate let motionManager = MotionController()
    weak var arrowNode: SCNNode?
    weak var flatDiskSpinnerRoot: SCNNode?
    weak var horizonDiskRoot: SCNNode?
    weak var targetAzimuthPivot: SCNNode?
    weak var stabilizedNode: SCNNode?
    var readyBinding: Binding<Bool>?
    private var postedFirstFrame = false
    fileprivate var motionStarted = false
    private var hasReceivedAttitude = false
    private var lastPickableId: String?
    private var lastSpinnerDuration: Double = 1.0

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
      guard !postedFirstFrame else { return }
      postedFirstFrame = true
      DispatchQueue.main.async { [weak self] in
        self?.readyBinding?.wrappedValue = true
      }
    }

    deinit {
      motionManager.stopUpdates()
    }

    func sync(
      aimMode: AimSession.AimMode,
      pickableId: String,
      userCoordinate: CLLocationCoordinate2D?,
      aimInstant: Date,
      satelliteENU: simd_float3?,
      observerEllipsoidHeightMeters: Double,
      overlaySettings: PointerDisplaySettings,
      sceneRenderingReady: Bool,

      orientationRingShowsWait: Bool,
      spinnerDuration: Double
    ) {
      guard let arrow = arrowNode, let stabilized = stabilizedNode else { return }

      if pickableId != lastPickableId {
        lastPickableId = pickableId
      }

      let rawENU = Self.aimDirectionENU(
        aimMode: aimMode,
        userCoordinate: userCoordinate,
        aimInstant: aimInstant,
        satelliteENU: satelliteENU,
        observerEllipsoidHeightMeters: observerEllipsoidHeightMeters
      )
      // Core Motion .xTrueNorthZVertical: +X north, +Y west, +Z up.
      // Our ENU vectors use +Y east, so negate Y for the rendering frame.
      let aimENU = rawENU.map { simd_float3($0.x, -$0.y, $0.z) }

      let ready = aimENU != nil && hasReceivedAttitude && sceneRenderingReady
      let showWait = orientationRingShowsWait && !ready && hasReceivedAttitude

      if let dir = aimENU, ready {
        arrow.simdOrientation = Self.quaternionAligning(
          from: simd_normalize(simd_float3(0, 1, 0)),
          to: simd_normalize(dir)
        )
      }

      arrow.isHidden = !ready || !overlaySettings.showArrow
      flatDiskSpinnerRoot?.isHidden = !showWait

      if showWait && spinnerDuration != lastSpinnerDuration {
        lastSpinnerDuration = spinnerDuration
        if let diskNode = flatDiskSpinnerRoot?.childNode(withName: "flatSpinnerDisc", recursively: true) {
          diskNode.removeAllActions()
          let spin = SCNAction.repeatForever(
            SCNAction.rotateBy(x: 0, y: 0, z: CGFloat.pi * 2, duration: spinnerDuration)
          )
          diskNode.runAction(spin)
        }
      }

      let showBezel = ready && overlaySettings.showAzimuthDisk
      Self.updateHorizonDisk(
        root: horizonDiskRoot,
        targetAzimuthPivot: targetAzimuthPivot,
        aimENU: aimENU ?? simd_float3(1, 0, 0),
        showAzimuthPlate: showBezel
      )

      if !motionStarted {
        motionStarted = true
        motionManager.restart(referenceFrame: .xTrueNorthZVertical) { [weak self] attitude in
          self?.hasReceivedAttitude = true
          Self.applyDeviceStabilization(stabilized: stabilized, attitude: attitude)
        }
      }
    }

    /// Level the overlay’s world frame with gravity / heading only — preview alignment is **`SCNView.transform`**, same numeric angle as the camera connection.
    private static func applyDeviceStabilization(stabilized: SCNNode, attitude: CMAttitude) {
      let q = attitude.quaternion
      let device = simd_quaternion(Float(q.x), Float(q.y), Float(q.z), Float(q.w))
      stabilized.simdOrientation = simd_inverse(device)
    }

    /// Rotation taking unit vector `from` onto unit vector `to`.
    static func quaternionAligning(from: simd_float3, to: simd_float3) -> simd_quatf {
      let a = simd_normalize(from)
      let b = simd_normalize(to)
      let c = simd_cross(a, b)
      let d = simd_dot(a, b)
      let epsilon: Float = 1e-6
      if simd_length(c) < epsilon {
        if d > 0 {
          return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let ortho =
          abs(a.x) < 0.9 ? simd_normalize(simd_cross(a, simd_float3(1, 0, 0))) : simd_normalize(simd_cross(a, simd_float3(0, 1, 0)))
        return simd_quaternion(Float.pi, ortho)
      }
      let axis = simd_normalize(c)
      let angle = acos(max(-1, min(1, d)))
      return simd_quaternion(angle, axis)
    }

    /// ENU direction toward the target in true-north coordinates: +X north, +Y east, +Z up.
    /// Returns nil when the direction can't be computed (no GPS, degenerate, etc.).
    private static func aimDirectionENU(
      aimMode: AimSession.AimMode,
      userCoordinate: CLLocationCoordinate2D?,
      aimInstant: Date,
      satelliteENU: simd_float3?,
      observerEllipsoidHeightMeters: Double
    ) -> simd_float3? {
      guard let userCoordinate else { return nil }
      switch aimMode {
      case .ground(let target):
        let destCoord = CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude)
        let origin = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let dest = CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude)
        guard origin.distance(from: dest) >= 3 else { return nil }
        return Geodesy.trueNorthENUChordUnit(from: userCoordinate, to: destCoord)
      case .celestial(let target):
        if target.kind == .satellite {
          return satelliteENU
        }
        return TopocentricAstronomy.enuForCelestialCatalog(
          target,
          observer: userCoordinate,
          at: aimInstant,
          ellipsoidHeightMeters: observerEllipsoidHeightMeters
        )
      }
    }

    private static func updateHorizonDisk(
      root: SCNNode?,
      targetAzimuthPivot: SCNNode?,
      aimENU: simd_float3,
      showAzimuthPlate: Bool
    ) {
      guard let root, let pivot = targetAzimuthPivot else { return }
      root.isHidden = !showAzimuthPlate
      guard showAzimuthPlate else { return }

      let d = simd_normalize(aimENU)
      let hz = hypot(Double(d.x), Double(d.y))
      if hz < 0.04 {
        pivot.isHidden = true
        return
      }
      pivot.isHidden = false
      let az = atan2(Double(d.y), Double(d.x))
      pivot.eulerAngles = SCNVector3(0, 0, Float(az))
    }

    // MARK: - Geometry constants (from Pointer arrow study)

    private static let bezelRadius: CGFloat = 1.55
    private static let bezelThickness: CGFloat = 0.013
    private static let accent = UIColor(red: 0.839, green: 0.239, blue: 0.212, alpha: 1) // 0xd63d36
    private static let bodyColor = UIColor(red: 0.906, green: 0.922, blue: 0.925, alpha: 1) // 0xe7ebec
    private static let tickColor = UIColor(red: 0.078, green: 0.102, blue: 0.114, alpha: 1) // 0x141a1d

    // MARK: - Fletched dart (concept C)

    static func buildArrowNode() -> SCNNode {
      let body = SCNMaterial()
      body.diffuse.contents = bodyColor
      body.specular.contents = UIColor(white: 0.17, alpha: 1)
      body.shininess = 26
      body.lightingModel = .phong

      let accentMat = SCNMaterial()
      accentMat.diffuse.contents = accent
      accentMat.specular.contents = UIColor(red: 0.25, green: 0.14, blue: 0.12, alpha: 1)
      accentMat.shininess = 32
      accentMat.lightingModel = .phong

      let shaftLen: Float = 1.9, shaftR: Float = 0.06
      let tipR: Float = 0.16, tipLen: Float = 0.8
      let cutFrac: Float = 0.24
      let frustumLen = tipLen * (1 - cutFrac)
      let pointLen = tipLen * cutFrac
      let rCut = tipR * cutFrac

      let shaft = SCNCylinder(radius: CGFloat(shaftR), height: CGFloat(shaftLen))
      shaft.radialSegmentCount = 48
      shaft.firstMaterial = body
      let shaftNode = SCNNode(geometry: shaft)
      shaftNode.position = SCNVector3(0, shaftLen / 2, 0)

      let frustum = SCNCone(topRadius: CGFloat(rCut), bottomRadius: CGFloat(tipR), height: CGFloat(frustumLen))
      frustum.radialSegmentCount = 48
      frustum.firstMaterial = body
      let frustumNode = SCNNode(geometry: frustum)
      frustumNode.position = SCNVector3(0, shaftLen + frustumLen / 2, 0)

      let point = SCNCone(topRadius: 0, bottomRadius: CGFloat(rCut), height: CGFloat(pointLen))
      point.radialSegmentCount = 48
      point.firstMaterial = accentMat
      let pointNode = SCNNode(geometry: point)
      pointNode.position = SCNVector3(0, shaftLen + frustumLen + pointLen / 2, 0)

      // 4 swept vanes at the tail — positioned at the bottom of the shaft
      let finLen: Float = 0.5, finSpan: Float = 0.08, finT: Float = 0.024
      let vaneContainer = SCNNode()
      vaneContainer.position = SCNVector3(0, -shaftLen / 2, 0)
      shaftNode.addChildNode(vaneContainer)
      for i in 0 ..< 4 {
        let angle = Float(i) * .pi / 2
        let vaneNode = buildSweptVane(
          shaftRadius: shaftR, finLen: finLen, span: finSpan, thickness: finT,
          material: accentMat
        )
        vaneNode.simdEulerAngles = simd_float3(0, angle, 0)
        vaneContainer.addChildNode(vaneNode)
      }

      let inner = SCNNode()
      inner.addChildNode(shaftNode)
      inner.addChildNode(frustumNode)
      inner.addChildNode(pointNode)

      // Recenter on bounding box
      let (mn, mx) = inner.boundingBox
      let cy = (mn.y + mx.y) / 2
      inner.position = SCNVector3(0, -cy, 0)

      // Light pinned to the arrow's own frame
      let keyLight = SCNLight()
      keyLight.type = .directional
      keyLight.intensity = 920
      keyLight.color = UIColor.white
      let keyNode = SCNNode()
      keyNode.light = keyLight
      keyNode.position = SCNVector3(5, 9, 6)
      keyNode.look(at: SCNVector3(0, 0, 0))

      let fillLight = SCNLight()
      fillLight.type = .directional
      fillLight.intensity = 340
      fillLight.color = UIColor.white
      let fillNode = SCNNode()
      fillNode.light = fillLight
      fillNode.position = SCNVector3(-6, 1.5, -5)
      fillNode.look(at: SCNVector3(0, 0, 0))

      let root = SCNNode()
      root.addChildNode(inner)
      root.addChildNode(keyNode)
      root.addChildNode(fillNode)
      root.renderingOrder = 0
      return root
    }

    private static func buildSweptVane(
      shaftRadius: Float, finLen: Float, span: Float, thickness: Float,
      material: SCNMaterial
    ) -> SCNNode {
      let innerX = shaftRadius - 0.035
      let outerX = shaftRadius + span

      let path = UIBezierPath()
      path.move(to: CGPoint(x: CGFloat(innerX), y: -0.05))
      path.addLine(to: CGPoint(x: CGFloat(innerX), y: CGFloat(finLen)))
      path.addLine(to: CGPoint(x: CGFloat(shaftRadius + span * 0.55), y: CGFloat(finLen * 0.58)))
      path.addLine(to: CGPoint(x: CGFloat(outerX), y: 0.05))
      path.addLine(to: CGPoint(x: CGFloat(outerX), y: -0.05))
      path.close()

      let shape = SCNShape(path: path, extrusionDepth: CGFloat(thickness))
      shape.firstMaterial = material
      let node = SCNNode(geometry: shape)
      // Position at shaft bottom (SCNCylinder is centered, so bottom is -height/2)
      node.position = SCNVector3(0, 0, Float(-thickness / 2))
      return node
    }

    // MARK: - Compass bezel (from study §05)

    private static func bezelDiskTexture() -> UIImage {
      let side: CGFloat = 1024
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
      return renderer.image { ctx in
        let center = CGPoint(x: side / 2, y: side / 2)
        let outerR = side / 2 - 2
        let N = 72

        UIColor.clear.setFill()
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: side, height: side)))

        // Translucent membrane — flat white, carried all the way to center
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(arcCenter: center, radius: outerR, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

        let tickDark = UIColor(red: 0.078, green: 0.102, blue: 0.114, alpha: 1)

        // Cardinal crosshair lines (0°, 90°, 180°, 270°) from center to rim
        let crosshairWidth: CGFloat = 1.4
        let zeroTickInner = outerR - 0.30 * outerR / CGFloat(bezelRadius)
        for qi in 0 ..< 4 {
          let angle = CGFloat(qi) * .pi / 2 - .pi / 2
          let isZero = (qi == 0)
          let outer: CGFloat = isZero ? zeroTickInner - 4.0 : outerR
          let p1 = CGPoint(x: center.x, y: center.y)
          let p2 = CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle))
          let line = UIBezierPath()
          line.move(to: p1)
          line.addLine(to: p2)
          line.lineWidth = crosshairWidth
          line.lineCapStyle = .butt
          tickDark.withAlphaComponent(0.28).setStroke()
          line.stroke()
        }

        // Tick marks: 72 positions (every 5°), major every 45°, medium every 15°
        for i in 0 ..< N {
          let deg = CGFloat(i) * 5
          let angle = deg * .pi / 180 - .pi / 2
          let cardinal = (i % 18 == 0)
          let major = (i % 9 == 0)
          let med = (i % 3 == 0)

          let depth: CGFloat = cardinal ? 0.28 : major ? 0.20 : med ? 0.11 : 0.06
          let width: CGFloat = cardinal ? 2.8 : major ? 2.5 : med ? 1.8 : 1.2
          let alpha: CGFloat = cardinal ? 0.95 : major ? 0.92 : med ? 0.72 : 0.48

          let scale = outerR / CGFloat(bezelRadius)
          let tickOuter = outerR
          let tickInner = tickOuter - depth * scale

          let p1 = CGPoint(x: center.x + tickInner * cos(angle), y: center.y + tickInner * sin(angle))
          let p2 = CGPoint(x: center.x + tickOuter * cos(angle), y: center.y + tickOuter * sin(angle))

          let tick = UIBezierPath()
          tick.move(to: p1)
          tick.addLine(to: p2)
          tick.lineWidth = width
          tick.lineCapStyle = .butt
          tickDark.withAlphaComponent(alpha).setStroke()
          tick.stroke()
        }

        // Double tick at 0° — tighter gap, interrupts the N-S crosshair
        let zeroDepth: CGFloat = 0.30
        let scale = outerR / CGFloat(bezelRadius)
        for offset: CGFloat in [-0.012, 0.012] {
          let angle = offset - .pi / 2
          let outer = outerR
          let inner = outer - zeroDepth * scale
          let tick = UIBezierPath()
          tick.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
          tick.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
          tick.lineWidth = 2.2
          tick.lineCapStyle = .butt
          tickDark.withAlphaComponent(0.97).setStroke()
          tick.stroke()
        }
      }
    }

    private static func clearMaterial() -> SCNMaterial {
      let m = SCNMaterial()
      m.diffuse.contents = UIColor.clear
      m.lightingModel = .constant
      m.writesToDepthBuffer = false
      return m
    }

    static func buildHorizonDiskNode() -> SCNNode {
      let root = SCNNode()
      root.name = "horizonDiskRoot"

      let side = bezelRadius * 2
      let plane = SCNPlane(width: side, height: side)
      let diskMat = SCNMaterial()
      diskMat.diffuse.contents = bezelDiskTexture()
      diskMat.lightingModel = .constant
      diskMat.isDoubleSided = true
      diskMat.writesToDepthBuffer = false
      plane.firstMaterial = diskMat

      let diskNode = SCNNode(geometry: plane)
      diskNode.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
      diskNode.name = "horizonDisk"
      diskNode.renderingOrder = 1
      root.addChildNode(diskNode)

      // Target azimuth caret — slim triangle pointing outward to the rim
      let pivot = SCNNode()
      pivot.name = "targetAzimuthPivot"
      root.addChildNode(pivot)

      let cR = CGFloat(bezelRadius)
      let caretPath = UIBezierPath()
      caretPath.move(to: CGPoint(x: cR - 0.02, y: 0))
      caretPath.addLine(to: CGPoint(x: cR - 0.28, y: 0.085))
      caretPath.addLine(to: CGPoint(x: cR - 0.28, y: -0.085))
      caretPath.close()
      let caretShape = SCNShape(path: caretPath, extrusionDepth: 0.01)
      let caretMat = SCNMaterial()
      caretMat.diffuse.contents = tickColor
      caretMat.lightingModel = .constant
      caretMat.isDoubleSided = true
      caretMat.writesToDepthBuffer = false
      caretShape.firstMaterial = caretMat

      let caretNode = SCNNode(geometry: caretShape)
      caretNode.name = "bearingCaret"
      caretNode.position = SCNVector3(0, 0.005, 0)
      caretNode.renderingOrder = 2
      pivot.addChildNode(caretNode)
      pivot.renderingOrder = 2

      return root
    }

    // MARK: - Sweep spinner (from study §06)

    private static func sweepSpinnerTexture() -> UIImage {
      let side: CGFloat = 512
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
      return renderer.image { ctx in
        let center = CGPoint(x: side / 2, y: side / 2)
        let outerR = side / 2 - 4
        let tubeW: CGFloat = 3.0

        UIColor.clear.setFill()
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: side, height: side)))

        // Faint base ring
        let ring = UIBezierPath(arcCenter: center, radius: outerR, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        ring.lineWidth = tubeW
        UIColor.white.withAlphaComponent(0.3).setStroke()
        ring.stroke()

        // Bright sweep arc (12% of circumference) + leading tick
        let arcFrac: CGFloat = 0.12
        let arcStart: CGFloat = -.pi / 2
        let arcEnd = arcStart + arcFrac * 2 * .pi
        let sweep = UIBezierPath(arcCenter: center, radius: outerR, startAngle: arcStart, endAngle: arcEnd, clockwise: true)
        sweep.lineWidth = tubeW * 2.5
        UIColor.white.withAlphaComponent(0.9).setStroke()
        sweep.stroke()

      }
    }

    static func buildFlatDiskSpinnerNode() -> SCNNode {
      let root = SCNNode()
      root.name = "flatDiskSpinnerRoot"
      root.position = SCNVector3(0, 0, 0.013)

      let side = bezelRadius * 2
      let plane = SCNPlane(width: side, height: side)
      let mat = SCNMaterial()
      mat.diffuse.contents = sweepSpinnerTexture()
      mat.lightingModel = .constant
      mat.isDoubleSided = true
      mat.writesToDepthBuffer = false
      plane.firstMaterial = mat

      let diskNode = SCNNode(geometry: plane)
      diskNode.name = "flatSpinnerDisc"
      diskNode.eulerAngles = SCNVector3(0, 0, 0)
      diskNode.renderingOrder = 2
      root.addChildNode(diskNode)

      let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 0, z: CGFloat.pi * 2, duration: 1.0))
      diskNode.runAction(spin)

      root.renderingOrder = 5
      return root
    }
  }

  final class MotionController {
    private let motion = CMMotionManager()

    func restart(referenceFrame: CMAttitudeReferenceFrame, handler: @escaping (CMAttitude) -> Void) {
      motion.stopDeviceMotionUpdates()
      guard motion.isDeviceMotionAvailable else { return }
      motion.deviceMotionUpdateInterval = 1.0 / 60.0
      motion.startDeviceMotionUpdates(using: referenceFrame, to: .main) { data, _ in
        guard let attitude = data?.attitude else { return }
        handler(attitude)
      }
    }

    func stopUpdates() {
      motion.stopDeviceMotionUpdates()
    }
  }
}

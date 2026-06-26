#if DEBUG
import SceneKit
import SwiftUI
import simd

/// Static SceneKit arrow overlay for screenshot composition.
/// Reuses ArrowSceneView.Coordinator geometry builders; no sensor wiring.
struct ScreenshotArrowView: UIViewRepresentable {
    var config: ScreenshotConfig

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = true

        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        view.scene = scene

        // Camera — identical to production
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 6)
        cameraNode.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        scene.rootNode.addChildNode(cameraNode)

        // Stabilized node: simulates device held level at deviceAzimuthDeg heading.
        // Different per scene so bezel/north orientation varies across screenshots.
        let stabilized = SCNNode()
        stabilized.simdOrientation = config.stabilizationOrientation
        scene.rootNode.addChildNode(stabilized)

        // Spinner: hidden — no wait state in screenshot mode
        let spinner = ArrowSceneView.Coordinator.buildFlatDiskSpinnerNode()
        spinner.isHidden = true
        stabilized.addChildNode(spinner)

        // Horizon disk (compass bezel)
        let horizon = ArrowSceneView.Coordinator.buildHorizonDiskNode()
        stabilized.addChildNode(horizon)

        // Arrow
        let arrow = ArrowSceneView.Coordinator.buildArrowNode()
        stabilized.addChildNode(arrow)

        // Arrow orientation: ENU az/el → Core Motion frame (negate Y: east→west) → quaternion.
        // Production code in ArrowSceneView.Coordinator.sync() does the same negate.
        let enu = config.enuDirection
        let cmDir = simd_normalize(simd_float3(enu.x, -enu.y, enu.z))
        arrow.simdOrientation = ArrowSceneView.Coordinator.quaternionAligning(
            from: simd_normalize(simd_float3(0, 1, 0)),
            to: cmDir
        )

        // Bezel caret: position target azimuth pivot (mirrors updateHorizonDisk in production)
        if let pivot = horizon.childNode(withName: "targetAzimuthPivot", recursively: true) {
            let hz = hypot(Double(cmDir.x), Double(cmDir.y))
            if hz >= 0.04 {
                let az = atan2(Double(cmDir.y), Double(cmDir.x))
                pivot.eulerAngles = SCNVector3(0, 0, Float(az))
                pivot.isHidden = false
            } else {
                pivot.isHidden = true
            }
        }

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
#endif

#if DEBUG
import SceneKit
import SwiftUI
import simd

/// Renders background photo + 3D disc/arrow (+ optional picker dim) to a UIImage
/// via SCNRenderer. Baking everything into one opaque render avoids both Metal-
/// occlusion of SwiftUI siblings and frame-placement ambiguity.
struct ScreenshotArrowView: View {
    var config: ScreenshotConfig
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard image == nil else { return }
            let screen = UIScreen.main
            let pts  = screen.bounds.size
            let px   = CGSize(width: pts.width * screen.scale,
                              height: pts.height * screen.scale)
            image = Self.render(config: config, pointSize: pts, pixelSize: px,
                                scale: screen.scale)
        }
    }

    // Center-crop a photo to the target aspect ratio so SceneKit's stretch-to-fill
    // doesn't distort it when used as scene.background.contents.
    private static func cropToFill(photo: UIImage, targetAspect: CGFloat) -> UIImage {
        let w = photo.size.width, h = photo.size.height
        let imgAspect = w / h
        let cropRect: CGRect
        if imgAspect > targetAspect {
            let cw = h * targetAspect
            cropRect = CGRect(x: (w - cw) / 2, y: 0, width: cw, height: h)
        } else {
            let ch = w / targetAspect
            cropRect = CGRect(x: 0, y: (h - ch) / 2, width: w, height: ch)
        }
        let s = photo.scale
        let scaled = CGRect(x: cropRect.minX * s, y: cropRect.minY * s,
                             width: cropRect.width * s, height: cropRect.height * s)
        guard let cg = photo.cgImage?.cropping(to: scaled) else { return photo }
        return UIImage(cgImage: cg, scale: s, orientation: photo.imageOrientation)
    }

    private static func render(config: ScreenshotConfig,
                                pointSize: CGSize,
                                pixelSize: CGSize,
                                scale: CGFloat) -> UIImage? {
        let scene = SCNScene()

        // Background photo baked in; crop to viewport aspect so SceneKit's
        // stretch-to-fill produces no distortion.
        if let path = Bundle.main.path(forResource: config.backgroundImage, ofType: "jpg"),
           let photo = UIImage(contentsOfFile: path) {
            scene.background.contents = cropToFill(
                photo: photo,
                targetAspect: pixelSize.width / pixelSize.height
            )
        } else {
            scene.background.contents = UIColor(red: 0.3, green: 0.2, blue: 0.7, alpha: 1)
        }

        // Camera — identical to production
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 6)
        cameraNode.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        scene.rootNode.addChildNode(cameraNode)

        // Stabilized node
        let stabilized = SCNNode()
        stabilized.simdOrientation = config.stabilizationOrientation
        scene.rootNode.addChildNode(stabilized)

        let spinner = ArrowSceneView.Coordinator.buildFlatDiskSpinnerNode()
        spinner.isHidden = true
        stabilized.addChildNode(spinner)

        let horizon = ArrowSceneView.Coordinator.buildHorizonDiskNode()
        stabilized.addChildNode(horizon)

        let arrow = ArrowSceneView.Coordinator.buildArrowNode()
        stabilized.addChildNode(arrow)

        let enu   = config.enuDirection
        let cmDir = simd_normalize(simd_float3(enu.x, -enu.y, enu.z))
        arrow.simdOrientation = ArrowSceneView.Coordinator.quaternionAligning(
            from: simd_normalize(simd_float3(0, 1, 0)),
            to: cmDir
        )

        if let pivot = horizon.childNode(withName: "targetAzimuthPivot", recursively: true) {
            let hz = hypot(Double(cmDir.x), Double(cmDir.y))
            if hz >= 0.04 {
                pivot.eulerAngles = SCNVector3(0, 0, Float(atan2(Double(cmDir.y), Double(cmDir.x))))
                pivot.isHidden = false
            } else {
                pivot.isHidden = true
            }
        }

        // Picker-shot dim: large constant-shaded plane between disc (z=0) and camera (z=6)
        if config.showPicker {
            let dimGeom = SCNPlane(width: 20, height: 20)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.black.withAlphaComponent(0.25)
            mat.lightingModel   = .constant
            mat.isDoubleSided   = true
            dimGeom.firstMaterial = mat
            let dimNode = SCNNode(geometry: dimGeom)
            dimNode.position = SCNVector3(0, 0, 5)
            scene.rootNode.addChildNode(dimNode)
        }

        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene        = scene
        renderer.pointOfView  = cameraNode
        renderer.autoenablesDefaultLighting = true

        let snapshot = renderer.snapshot(atTime: 0, with: pixelSize,
                                          antialiasingMode: .multisampling4X)
        guard let cg = snapshot.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

#Preview {
    ScreenshotArrowView(config: ScreenshotConfig.configs[0])
}
#endif

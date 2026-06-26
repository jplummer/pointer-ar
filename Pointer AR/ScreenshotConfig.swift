#if DEBUG
import simd

struct ScreenshotConfig {
    var id: String
    var targetName: String        // must match CelestialTarget.displayName or GroundTarget.displayName
    var azimuthDeg: Double        // degrees clockwise from north
    var elevationDeg: Double      // degrees above/below horizon
    var backgroundImage: String   // filename without extension, must match bg-*.jpg in bundle
    var deviceAzimuthDeg: Double  // simulated device heading — controls where N appears on bezel
    var showPicker: Bool

    /// ENU unit vector: +X north, +Y east, +Z up.
    var enuDirection: simd_float3 {
        let el = Float(elevationDeg) * .pi / 180
        let az = Float(azimuthDeg)  * .pi / 180
        return simd_normalize(simd_float3(
            cos(el) * cos(az),  // north
            cos(el) * sin(az),  // east
            sin(el)             // up
        ))
    }

    /// Orientation for the SceneKit stabilized node, simulating the device held level
    /// at deviceAzimuthDeg yaw. Equivalent to simd_inverse(deviceAttitude) in production.
    var stabilizationOrientation: simd_quatf {
        let rad = Float(deviceAzimuthDeg) * .pi / 180
        let device = simd_quaternion(rad, simd_float3(0, 0, 1))
        return simd_inverse(device)
    }
}

extension ScreenshotConfig {
    static let all: [String: ScreenshotConfig] = Dictionary(
        uniqueKeysWithValues: configs.map { ($0.id, $0) }
    )

    static let configs: [ScreenshotConfig] = [
        ScreenshotConfig(
            id: "01-iss",
            targetName: "International Space Station",
            azimuthDeg: 247,
            elevationDeg: 35,
            backgroundImage: "bg-golden-city",
            deviceAzimuthDeg: 60,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "02-moon",
            targetName: "Moon",
            azimuthDeg: 142,
            elevationDeg: 52,
            backgroundImage: "bg-hills-and-clouds",
            deviceAzimuthDeg: 150,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "03-sydney",
            targetName: "Sydney Opera House",
            azimuthDeg: 158,
            elevationDeg: -32,
            backgroundImage: "bg-rolling-hills",
            deviceAzimuthDeg: 240,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "04-picker",
            targetName: "International Space Station",
            azimuthDeg: 247,
            elevationDeg: 35,
            backgroundImage: "bg-field-and-hills",
            deviceAzimuthDeg: 330,
            showPicker: true
        ),
    ]
}
#endif

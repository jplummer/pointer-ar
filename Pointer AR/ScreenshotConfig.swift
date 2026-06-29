#if DEBUG
import simd

struct ScreenshotConfig {
    var id: String
    var targetName: String        // must match CelestialTarget.displayName or GroundTarget.displayName
    var targetPickableId: String  // pre-seeds AimSession via UserDefaults; format: "cel:<id>" or "ground:<id>"
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

    /// Orientation for the SceneKit stabilized node.
    /// Combines a yaw (device heading) with a ~65° pitch so the compass bezel
    /// appears foreshortened as it would on a phone held in portrait, not face-on
    /// as it would if the phone were lying flat.
    var stabilizationOrientation: simd_quatf {
        let azRad   = Float(deviceAzimuthDeg) * .pi / 180
        let pitchRad: Float = 65 * .pi / 180
        // Pitch around +X so simd_inverse tilts the disc's bottom toward the camera
        // and top away — from-above perspective, wider than tall.  (–X gives
        // from-below, which also produces a horizontal ellipse but mirrors the
        // caret/arrow relationship, making them appear to disagree on azimuth.)
        let yaw   = simd_quaternion(azRad,    simd_float3( 0, 0, 1))
        let pitch = simd_quaternion(pitchRad, simd_float3( 1, 0, 0))
        return simd_inverse(simd_mul(yaw, pitch))
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
            targetPickableId: "cel:orbit.iss",
            azimuthDeg: 247,
            elevationDeg: 35,
            backgroundImage: "bg-golden-city",
            deviceAzimuthDeg: 60,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "02-moon",
            targetName: "Moon",
            targetPickableId: "cel:sky.moon",
            azimuthDeg: 142,
            elevationDeg: 52,
            backgroundImage: "bg-hills-and-clouds",
            deviceAzimuthDeg: 150,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "03-sydney",
            targetName: "Sydney Opera House",
            targetPickableId: "ground:place.sydney_opera_house",
            azimuthDeg: 158,
            elevationDeg: -32,
            backgroundImage: "bg-rolling-hills",
            deviceAzimuthDeg: 240,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "04-picker",
            targetName: "International Space Station",
            targetPickableId: "cel:orbit.iss",
            azimuthDeg: 247,
            elevationDeg: 35,
            backgroundImage: "bg-field-and-hills",
            deviceAzimuthDeg: 330,
            showPicker: true
        ),
    ]
}
#endif

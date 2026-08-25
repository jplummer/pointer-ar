# App Store Screenshot Generation — Design Spec

**Date:** 2026-06-25
**Status:** Approved

## Context

Pointer AR needs App Store screenshots that show the camera view with the 3D arrow pointing toward interesting targets. The challenge: using the live camera would reveal the user's location, and a real device in a real place produces uncontrolled, potentially ugly results. The goal is 3–4 beautiful, reproducible screenshots that honestly show what the app does — arrow, compass bezel, azimuth/elevation readouts — without disclosing any real location.

---

## Approach

A `#if DEBUG`-only `ScreenshotView` composites a bundled stock photo background with a static-mode `ArrowSceneView` and real UI overlays. XCUITest launches the app with a `--screenshot <id>` argument and fastlane `snapshot` captures the result. No production code path is affected.

---

## Background Images

**Source:** Unsplash or Pexels (CC0 license). Download 4 JPEGs at 2048px+ wide.

**What to look for:**
- Horizon visible in the lower quarter of frame — ground gives spatial grounding
- No identifiable landmarks, signage, or region-specific vegetation
- Varied light: golden hour, blue sky, coastal overcast
- Suggested searches: `"open field sky"`, `"prairie clouds"`, `"coastal cliffs"`, `"golden hour field"`

**Naming convention:** Use the `bg-` prefix so the build exclusion rule matches (e.g., `bg-1.jpg`, `bg-2.jpg`). Update the scene table's Background column to match your actual filenames.

**Where they live:** `Pointer AR/ScreenshotBackgrounds/` — a folder added to the main target's Copy Bundle Resources phase. In Build Settings → `EXCLUDED_SOURCE_FILE_NAMES`, Release configuration is set to `bg-*.jpg` so they never ship in production.

---

## New Files

### `Pointer AR/ScreenshotConfig.swift` *(#if DEBUG)*

```swift
struct ScreenshotConfig {
    var id: String              // snapshot filename, e.g. "01-iss"
    var targetName: String      // displayed label, e.g. "International Space Station"
    var azimuthDeg: Double      // displayed readout
    var elevationDeg: Double    // displayed readout
    var backgroundImage: String // asset name, e.g. "bg-field"
    var deviceAzimuthDeg: Double // device heading — controls where N appears on bezel
    var showPicker: Bool
}
```

Arrow quaternion is derived from `azimuthDeg` + `elevationDeg` → ENU unit vector → `quaternionAligning()` (reuses the existing function in `ArrowSceneView.swift`). Bezel rotation is `azimuthDeg - deviceAzimuthDeg`, same math as production.

**The four scenes:**

| id | Target | Target Az | Device Heading | Elevation | Background |
|----|--------|-----------|----------------|-----------|------------|
| 01-iss | ISS | 247° | 60° | +35° | bg-field |
| 02-moon | Moon | 142° | 150° | +52° | bg-clouds |
| 03-sydney | Sydney Opera House | 158° | 240° | −32° | bg-coast |
| 04-picker | *(any)* | — | 330° | — | bg-field |

North lands in a distinct quadrant of the bezel for each shot (upper-left, lower-left, lower-right, upper-right). The Sydney shot arrow sits clearly below the horizon, illustrating that the app also points to ground targets through the Earth.

---

### `Pointer AR/ScreenshotView.swift` *(#if DEBUG)*

ZStack composition:

1. Background image loaded via `Bundle.main.path(forResource: config.backgroundImage, ofType: "jpg")` → `UIImage(contentsOfFile:)` → `Image(uiImage:)`. Not via `UIImage(named:)` — these are raw bundle files, not asset catalog entries.
2. `ArrowSceneView(staticOrientation:deviceAzimuth:)` — transparent SCNView over the background
3. Azimuth + elevation readout views — reused from `ContentView`, fed `config.azimuthDeg` / `config.elevationDeg`
4. Target name label — same view as `ContentView`
5. If `config.showPicker`: `TargetPickerExpando(session: screenshotSession)` — real picker with real target data from JSON

`ScreenshotAimSession` loads from `CelestialTargets.json` and `GroundTargets.json` (same files as production) but provides no live GPS or motion. Used only for the picker screenshot so it shows the real target list.

---

### `ArrowSceneView.swift` — static mode init *(#if DEBUG, ~20 lines)*

```swift
#if DEBUG
init(staticOrientation: simd_quatf, deviceAzimuth: Double) {
    // same scene setup as production init
    // skip CMMotionManager wiring entirely
    // apply staticOrientation to the stabilization node once, then stop
}
#endif
```

All geometry, materials, and lighting are identical to the production path. The stabilization node receives a quaternion representing the device held level (pitch = 0, roll = 0) but rotated to `deviceAzimuthDeg` yaw — not identity. Each scene has a distinct `deviceAzimuthDeg` (60°, 150°, 240°, 330°), so the compass bezel orientation, north marker position, and ground plane disc all appear at a different angle in every shot, making the four screenshots look like genuinely different moments of use.

---

### `PointerApp.swift` — launch argument handling *(#if DEBUG)*

```swift
#if DEBUG
if CommandLine.arguments.contains("--screenshot"),
   let id = /* next argument after --screenshot */ {
    return ScreenshotView(config: ScreenshotConfig.all[id])
}
#endif
```

Falls through to `ContentView()` in all other cases.

---

### `PointerARScreenshotTests/ScreenshotTests.swift`

New XCUITest target. One function per scene:

```swift
func testScreenshot01() {
    let app = XCUIApplication()
    app.launchArguments = ["--screenshot", "01-iss"]
    app.launch()
    snapshot("01-iss")
}
// repeat for 02-moon, 03-sydney, 04-picker
```

### `fastlane/Snapfile`

```ruby
devices(["iPhone 16 Pro Max", "iPhone SE (3rd generation)"])
languages(["en-US"])
scheme("Pointer AR")
output_directory("./fastlane/screenshots")
clear_previous_screenshots(true)
```

---

## Verification

1. Run screenshot UI tests on the iOS simulator — confirm each scene renders without errors
2. Visually check: all four bezels show N in a different quadrant; Sydney arrow is visibly below the horizon line; ISS and Moon arrows point clearly upward
3. Build for Release → inspect `DerivedData/.../Release-iphonesimulator/Pointer AR.app/` → confirm `bg-*.jpg` files are absent
4. Run `fastlane snapshot` end-to-end — confirm output PNGs land in `fastlane/screenshots/`

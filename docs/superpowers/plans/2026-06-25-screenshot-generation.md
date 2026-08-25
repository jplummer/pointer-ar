# App Store Screenshot Generation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate 4 reproducible App Store screenshots showing the Pointer AR interface over beautiful stock photos, without revealing a real location.

**Architecture:** A `#if DEBUG`-only `ScreenshotView` composites a bundled JPEG background with a static `ScreenshotArrowView` (no CMMotionManager) and real UI overlays. `PointerApp.swift` routes to `ScreenshotView` when launched with `--screenshot <id>`. XCUITest + fastlane `snapshot` drives capture.

**Tech Stack:** SwiftUI, SceneKit/simd, XCTest UITesting, fastlane snapshot

## Global Constraints

- All new code except `PointerApp.swift` changes is wrapped in `#if DEBUG ... #endif`
- Background images must be named with `bg-` prefix for build exclusion to work
- Only `PointerApp.swift` is modified among existing files (all other changes are new files)
- Target iOS/iPadOS as per existing project settings

---

### Task 1: Add background images and build exclusion

**Files:**
- Create: `Pointer AR/ScreenshotBackgrounds/` (folder — manual Xcode steps)
- Modify: Xcode Build Settings (`EXCLUDED_SOURCE_FILE_NAMES` for Release)

- [ ] **Step 1: Place images in the folder**

Ensure your JPEG files are named with the `bg-` prefix (e.g., `bg-1.jpg`, `bg-2.jpg`, `bg-3.jpg`). Copy them into `Pointer AR/ScreenshotBackgrounds/` in Finder. Note your filenames — you'll need them in Task 2.

- [ ] **Step 2: Add the folder to Xcode**

In Xcode, right-click the `Pointer AR` group in the Project Navigator → **Add Files to "Pointer AR"…** Select the `ScreenshotBackgrounds` folder. In the dialog:
- **Added folders:** Create groups
- **Add to targets:** Pointer AR ✓

Click Add. Open **Build Phases → Copy Bundle Resources** and confirm the `bg-*.jpg` files appear there.

- [ ] **Step 3: Exclude from Release builds**

In Xcode:
1. Click the **Pointer AR** project (blue icon) → select the **Pointer AR** target → **Build Settings** tab → **All**
2. Search: `excluded source`
3. Expand **Excluded Source File Names**
4. Set the **Release** row to: `bg-*.jpg`

- [ ] **Step 4: Verify exclusion**

Switch scheme to Release (Edit Scheme → Run → Build Configuration: Release). Build with Cmd+B. Navigate to:
`~/Library/Developer/Xcode/DerivedData/` → find `Pointer AR-xxx/Build/Products/Release-iphonesimulator/Pointer AR.app/`

Confirm `bg-*.jpg` files are absent from the `.app` bundle. Switch back to Debug.

---

### Task 2: ScreenshotConfig.swift

**Files:**
- Create: `Pointer AR/ScreenshotConfig.swift`

- [ ] **Step 1: Create the file**

Create `Pointer AR/ScreenshotConfig.swift`:

```swift
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

    // UPDATE backgroundImage values to match your actual filenames (without .jpg).
    static let configs: [ScreenshotConfig] = [
        ScreenshotConfig(
            id: "01-iss",
            targetName: "International Space Station",
            azimuthDeg: 247,
            elevationDeg: 35,
            backgroundImage: "bg-1",    // ← update to your filename
            deviceAzimuthDeg: 60,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "02-moon",
            targetName: "Moon",
            azimuthDeg: 142,
            elevationDeg: 52,
            backgroundImage: "bg-2",    // ← update to your filename
            deviceAzimuthDeg: 150,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "03-sydney",
            targetName: "Sydney Opera House",
            azimuthDeg: 158,
            elevationDeg: -32,
            backgroundImage: "bg-3",    // ← update to your filename
            deviceAzimuthDeg: 240,
            showPicker: false
        ),
        ScreenshotConfig(
            id: "04-picker",
            targetName: "International Space Station",
            azimuthDeg: 247,
            elevationDeg: 35,
            backgroundImage: "bg-1",    // ← update to your filename
            deviceAzimuthDeg: 330,
            showPicker: true
        ),
    ]
}
#endif
```

- [ ] **Step 2: Update background image names**

Replace `"bg-1"`, `"bg-2"`, `"bg-3"` in the configs with the actual filenames (without `.jpg`) from Task 1.

- [ ] **Step 3: Build**

Cmd+B in Debug. Expected: clean build, no errors.

---

### Task 3: ScreenshotArrowView.swift

**Files:**
- Create: `Pointer AR/ScreenshotArrowView.swift`

This reuses `ArrowSceneView.Coordinator`'s static geometry builders (they are `internal` by default and accessible within the module). No `CMMotionManager` is wired up — the arrow and bezel are set once from the config.

- [ ] **Step 1: Create the file**

Create `Pointer AR/ScreenshotArrowView.swift`:

```swift
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
```

- [ ] **Step 2: Build**

Cmd+B in Debug. If you see `value of type 'ArrowSceneView.Coordinator' has no member 'buildHorizonDiskNode'` or `buildFlatDiskSpinnerNode'`, open `ArrowSceneView.swift`, find those two static method declarations, and remove the `private` keyword from them only. Rebuild.

---

### Task 4: ScreenshotView.swift

**Files:**
- Create: `Pointer AR/ScreenshotView.swift`

- [ ] **Step 1: Create the file**

Create `Pointer AR/ScreenshotView.swift`:

```swift
#if DEBUG
import SwiftUI

struct ScreenshotView: View {
    let config: ScreenshotConfig
    @StateObject private var session = AimSession()

    var body: some View {
        ZStack {
            // Background: raw JPEG from bundle (not an asset catalog entry)
            if let path = Bundle.main.path(forResource: config.backgroundImage, ofType: "jpg"),
               let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                // Fallback: visible so a missing filename is obvious during iteration
                Color.indigo.ignoresSafeArea()
            }

            ScreenshotArrowView(config: config)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Target picker — collapsed (shows target name) or expanded for picker shot
                TargetPickerExpando(session: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Spacer(minLength: 0)

                // Az/El readout — same styling as ContentView.azimuthElevationReadout
                HStack(spacing: 18) {
                    Text("Az \(String(format: "%.0f°", config.azimuthDeg))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("El \(String(format: "%+.0f°", config.elevationDeg))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
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
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            // Select the correct target so the picker header shows the right name
            if let t = session.celestialCatalog.first(where: { $0.displayName == config.targetName }) {
                session.aimMode = .celestial(t)
            } else if let t = session.groundCatalog.first(where: { $0.displayName == config.targetName }) {
                session.aimMode = .ground(t)
            }
            if config.showPicker {
                session.pickerExpanded = true
            }
        }
    }
}

#Preview {
    ScreenshotView(config: ScreenshotConfig.configs[0])
}
#endif
```

- [ ] **Step 2: Open the Preview canvas**

Open `ScreenshotView.swift` in Xcode and click **Resume** in the Preview canvas. Verify:
- Background photo fills the screen (not indigo — if indigo, the `backgroundImage` value in ScreenshotConfig doesn't match your filename)
- Arrow is visible over the background
- Compass bezel disk is visible
- Az/El capsule appears at the bottom
- Target name shows in the collapsed picker header

Cycle through all four configs in the `#Preview` block (change `configs[0]` to `configs[1]`, etc.) to verify each scene.

---

### Task 5: Route PointerApp to ScreenshotView

**Files:**
- Modify: `Pointer AR/PointerApp.swift`

- [ ] **Step 1: Replace PointerApp.swift**

Replace the entire contents of `Pointer AR/PointerApp.swift`:

```swift
import SwiftUI

@main
struct PointerApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let idx = CommandLine.arguments.firstIndex(of: "--screenshot"),
               idx + 1 < CommandLine.arguments.count,
               let config = ScreenshotConfig.all[CommandLine.arguments[idx + 1]] {
                ScreenshotView(config: config)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
```

- [ ] **Step 2: Test each scene in the simulator**

For each config id, add launch arguments to the scheme (Product → Edit Scheme → Run → Arguments), run on simulator, and visually verify before moving to the next:

| Arguments to pass | What to check |
|-------------------|---------------|
| `--screenshot 01-iss` | Arrow pointing SW and up ~35°; golden-hour background; N in upper-left quadrant of bezel |
| `--screenshot 02-moon` | Arrow pointing SE and high ~52°; blue-sky background; N in lower-left quadrant |
| `--screenshot 03-sydney` | Arrow clearly below the horizon (~-32°); coastal background; N in lower-right quadrant |
| `--screenshot 04-picker` | Picker expanded showing full target list; golden-hour background; N in upper-right quadrant |

Remove the scheme arguments when done iterating.

- [ ] **Step 3: Commit**

```bash
git add "Pointer AR/ScreenshotConfig.swift" \
        "Pointer AR/ScreenshotArrowView.swift" \
        "Pointer AR/ScreenshotView.swift" \
        "Pointer AR/PointerApp.swift" \
        "Pointer AR/ScreenshotBackgrounds/"
git commit -m "feat: add DEBUG-only screenshot composition view for App Store"
```

---

### Task 6: XCUITest target and fastlane snapshot

**Files:**
- Create: `PointerARScreenshotTests/ScreenshotTests.swift` (new Xcode target)
- Create: `fastlane/Snapfile`
- Create: `fastlane/SnapshotHelper.swift` (generated by fastlane)

- [ ] **Step 1: Install fastlane**

```bash
brew install fastlane
```

Verify: `fastlane --version` should print a version number.

- [ ] **Step 2: Create the UITest target in Xcode**

1. **File → New → Target**
2. Choose **iOS UI Testing Bundle**
3. **Product Name:** `PointerARScreenshotTests`
4. **Target to be Tested:** `Pointer AR`
5. Click **Finish**

Xcode creates a `PointerARScreenshotTests` group with a launch test file. Delete `PointerARScreenshotTestsLaunchTests.swift` — it's not needed.

- [ ] **Step 3: Initialize fastlane snapshot**

```bash
cd /Users/jonplummer/Projects/pointer-ar
fastlane snapshot init
```

Expected output: "Created new file 'fastlane/SnapshotHelper.swift'" and "Created new file 'fastlane/Snapfile'".

- [ ] **Step 4: Add SnapshotHelper to the test target**

In Xcode, drag `fastlane/SnapshotHelper.swift` into the `PointerARScreenshotTests` group in the Project Navigator. In the dialog:
- **Add to targets:** `PointerARScreenshotTests` ✓ (not `Pointer AR`)

- [ ] **Step 5: Write the test file**

Create `PointerARScreenshotTests/ScreenshotTests.swift`:

```swift
import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testScreenshot01_ISS() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "01-iss"]
        app.launch()
        sleep(2)
        snapshot("01-iss")
    }

    func testScreenshot02_Moon() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "02-moon"]
        app.launch()
        sleep(2)
        snapshot("02-moon")
    }

    func testScreenshot03_Sydney() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "03-sydney"]
        app.launch()
        sleep(2)
        snapshot("03-sydney")
    }

    func testScreenshot04_Picker() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "04-picker"]
        app.launch()
        sleep(3)
        snapshot("04-picker")
    }
}
```

- [ ] **Step 6: Configure Snapfile**

Replace the contents of `fastlane/Snapfile` with:

```ruby
devices([
  "iPhone 16 Pro Max",
  "iPhone SE (3rd generation)"
])

languages(["en-US"])

scheme("PointerARScreenshotTests")

output_directory("./fastlane/screenshots")
output_simulator_logs(false)
clear_previous_screenshots(true)
```

- [ ] **Step 7: Share the test scheme**

In Xcode:
1. **Product → Scheme → Manage Schemes**
2. Find `PointerARScreenshotTests` → check the **Shared** checkbox
3. Close

This makes the scheme visible to fastlane.

- [ ] **Step 8: Run fastlane snapshot**

```bash
cd /Users/jonplummer/Projects/pointer-ar
fastlane snapshot
```

Expected: fastlane boots each simulator, runs the 4 tests, saves PNGs to `fastlane/screenshots/en-US/`. The total run takes 3–5 minutes.

- [ ] **Step 9: Verify output**

Open `fastlane/screenshots/en-US/`. Confirm 8 PNG files (2 devices × 4 shots). Open each and verify:
- Background correct per shot (no indigo fallback)
- Arrow visible and directionally distinct per shot
- Bezel N marker in a different screen quadrant for each shot
- `03-sydney` arrow clearly below the horizon line
- `04-picker` picker list is fully expanded

- [ ] **Step 10: Commit**

```bash
echo "fastlane/screenshots/" >> .gitignore
git add "PointerARScreenshotTests/" \
        "fastlane/Snapfile" \
        "fastlane/SnapshotHelper.swift" \
        ".gitignore"
git commit -m "feat: add XCUITest screenshot automation with fastlane snapshot"
```

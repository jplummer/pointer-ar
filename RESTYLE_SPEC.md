# Pointer — restyle and rebehavior spec

## Context

Pointer is a working iOS app that overlays a 3D arrow on the camera feed, pointing at a chosen target (landmark, satellite, celestial body, compass direction). The core math pipeline — Core Motion attitude, GPS position, bearing/ENU calculation, SceneKit rendering — works. What doesn't work well: the app has no startup sequence, the "waiting for GPS" state is a bare spinner with no context, the scene resets and accuracy degrades when the user is moving (walking, in a car), and the arrow/disk visuals are functional placeholders.

This spec covers four interconnected segments: startup behavior, finding-position behavior, phone-in-motion stability, and pointer + ground plane look and feel.

---

## 1. Startup behavior

### Problem

The app drops straight into a camera feed with a spinning disk. No identity moment, no sense of "this app is ready." Systems (Core Motion, GPS, SceneKit first frame) initialize at different speeds, and there's a 6-second fallback timer that forces `arrowSceneReady = true` even if nothing has rendered.

### Design

**A brief branded moment covers initialization.** The sequence:

1. **Launch screen** (system-provided, static): app background color + centered wordmark or icon. Displayed by iOS while the process loads — no code runs here.

2. **Branded transition** (~1-2 seconds, code-controlled): same visual as the launch screen but now live SwiftUI. Systems start initializing behind it (Core Motion begins, GPS authorization requested, SceneKit scene builds). The transition ends when SceneKit has rendered its first frame OR 2 seconds elapse, whichever comes first.

3. **Camera fade-up**: the camera feed fades in (opacity 0 → 1, ~0.4 seconds). The ground plane spinner is already visible and stabilized — it was rendering behind the branded screen. The user sees the spinner in the ground plane immediately, which reads as "working."

4. **Arrow appearance**: once aim direction resolves (GPS fix + bearing math), the spinner cross-fades to the compass disk and the arrow fades in (opacity 0 → 1, ~0.3 seconds).

**Returning from background:** no branded moment. Camera feed resumes, spinner or arrow appears based on current state. If GPS fix is stale (> 30 seconds old), show the spinner until a fresh fix arrives.

**Previously selected target persists.** `AimSession` should save the last `pickableId` to UserDefaults and restore it on launch. If the saved target isn't found in the catalog (removed in an update), fall back to the default catalog entry.

### What changes in code

- New `LaunchScreen.storyboard` or SwiftUI launch screen configuration (Info.plist keys).
- `ContentView`: add a `@State private var showBrandedCover = true` that gates an overlay. Dismiss it when `arrowSceneReady` becomes true, with a minimum 1-second display time.
- Camera fade-in: `CameraPreviewView` starts at opacity 0, animates to 1 when the branded cover dismisses.
- Remove the 6-second fallback timer — replace with a 3-second maximum for the branded cover (if SceneKit hasn't rendered by then, dismiss anyway and let the spinner carry the weight).
- `AimSession.init()`: read last pickableId from UserDefaults; `aimMode` setter: write to UserDefaults.

---

## 2. Finding-position behavior

### Problem

The current "waiting for GPS" state is a spinning disk with no text. Waits can be long enough (especially indoors or on first launch) that users don't know if the app is stuck. The info sheet shows GPS status, but you have to open it.

### Design

**A short label accompanies the spinner, then becomes associated with the visual so users recognize the state without reading it later.**

The label sits below the ground plane disk (in SwiftUI overlay space, not in the SceneKit scene). It appears when the spinner is showing and the cause is identifiable:

| State | Label | Icon hint |
|-------|-------|-----------|
| GPS not authorized, hasn't been asked for | "Location access needed" (leads to iOS permission dialog) | location.slash |
| GPS not authorized, has been asked for in the past | Instructional panel (see below) | location.slash |
| Waiting for first GPS fix | "Finding position..." | antenna.radiowaves.left.and.right |
| GPS fix acquired, computing direction | (no label — this resolves in < 1 frame) | — |
| Satellite ephemeris loading | "Loading orbit data..." | arrow.down.circle |
| GPS fix lost after having one | "Reacquiring position..." | antenna.radiowaves.left.and.right |

**Authorization denied (previously asked):** A panel overlays the SceneKit view explaining how to enable location services for this app in Settings — similar to how Monotasker handles this. Includes a button that opens Settings directly. The camera feed and spinner remain visible behind it. This treatment may evolve but serves as the v1 approach.

The label uses the same capsule style as the existing Az/El readout: dark translucent background, thin white border, white text. `.caption` weight, not prominent. It fades out when the spinner transitions to the compass disk.

**The spinner itself gets a subtle change per state** so that over time, the visual alone communicates what's happening. The finding-position spinner spins at 1 Hz (current behavior). The ephemeris-loading spinner spins at 0.5 Hz (slower = "waiting for network, not sensors"). This is a small enough difference to be felt rather than consciously noticed.

### What changes in code

- New enum `WaitReason` computed in `ContentView` from existing state: `.noAuthorization`, `.waitingForGPS`, `.loadingEphemeris`, `.reacquiringGPS`, `.none`.
- The wait label is a SwiftUI `Text` view positioned below the SceneKit overlay, gated on `waitReason != .none`.
- Spinner speed: pass `waitReason` through to `ArrowSceneView`; adjust the `SCNAction.rotateBy` duration (1.0 vs 2.0 seconds per revolution).
- "Reacquiring GPS" state: track whether we've ever had a fix (`@State private var hadGPSFix = false`). If `hadGPSFix && location.lastLocation == nil`, show reacquiring. (Note: `lastLocation` is never set to nil in the current `LocationService` — a new fix always replaces the old one. The reacquiring state should instead trigger when the fix age exceeds a threshold, e.g., 30 seconds since `lastLocation.timestamp`.)

---

## 3. Phone-in-motion stability

### Problem

Two distinct issues when the user is walking or in a vehicle:

**Scene resets (arrow disappears, spinner shows, arrow reappears).** Root cause: the `orientationRingShowsWait` flag in `ContentView:38-41` becomes `true` whenever `aimReady` briefly flickers `false`. This happens because `arrowDirectionResolved()` re-evaluates on every SwiftUI body pass, and transient state changes (new GPS fix arriving, `pickableId` comparison) can cause a single frame where the condition fails. The motion manager then restarts (frame changes from `.xTrueNorthZVertical` to `.xArbitraryZVertical` and back), causing a visible gap in attitude data.

**Accuracy drift (arrow drifts away from correct direction over time in a vehicle).** Likely cause: magnetometer interference from vehicle metal corrupts the `.xTrueNorthZVertical` reference frame's heading component. The attitude quaternion's "north" reference drifts, and the arrow follows it. This is a known limitation of `CMMotionManager` in vehicles — the magnetometer is heavily influenced by nearby ferrous metal and electronics.

### Design

**Fix 1: Never drop back to the wait spinner for transient GPS fluctuations.**

- Introduce `lastResolvedAimENU: simd_float3?` on the Coordinator. When a valid aim direction is computed, cache it. When the aim computation temporarily fails (GPS age, nil intermediate), use the cached direction instead of showing the spinner.
- Only clear `lastResolvedAimENU` when the user explicitly picks a different target (via `onChange(of: pickableId)`).
- Remove the `aimSession.aimMode.pickableId != pointerShownPickableId` check from `orientationRingShowsWait`. Instead, track target changes with a brief cross-fade: old arrow fades out, spinner shows for at most 0.5 seconds while new direction resolves, new arrow fades in.

**Fix 2: Don't restart the motion manager on transient frame changes.**

- The `lastMotionFrame` check in `Coordinator.sync()` restarts Core Motion every time the frame toggles. Instead: start with `.xTrueNorthZVertical` once and keep it running. The fallback to `.xArbitraryZVertical` was only needed when there's no target direction at all — with the cached aim from Fix 1, this case only arises on very first launch before any GPS fix.
- Start Core Motion in `makeUIView` with `.xTrueNorthZVertical` unconditionally. Only restart if the user has never had a GPS fix and there's no cached aim.

**Fix 3: Smooth bearing updates from GPS.**

- When a new GPS fix arrives and the bearing to the target changes, don't snap the arrow to the new direction. Instead, SLERP (spherical linear interpolation) from the current aim ENU to the new aim ENU over ~0.3 seconds.
- This eliminates the visible "jump" when GPS updates arrive during motion.
- Implementation: store `currentDisplayENU` and `targetENU` on the Coordinator. On each SceneKit render callback, SLERP `currentDisplayENU` toward `targetENU` with a time-based interpolation factor.

**Fix 4: Magnetometer drift mitigation (partial — the hard one).**

- Full fix requires sensor fusion beyond what Core Motion provides, which is out of scope.
- Partial mitigation: when the target is celestial (sun, moon, stars), the computed ENU direction changes slowly with observer position but the direction itself is authoritative. Compare the expected heading-to-target with the observed heading-to-target; if they diverge by more than a threshold (say 15 degrees), show a subtle "heading unreliable" indicator (a small icon near the Az readout, not a modal warning).
- For ground targets at long distances (> 100 km), bearing changes < 1 degree per GPS update are normal — don't SLERP these, just accept the new value.
- Document the vehicle limitation in the info sheet: "Heading accuracy may be reduced in vehicles due to magnetic interference."

### What changes in code

- `ArrowSceneView.Coordinator`: add `lastResolvedAimENU`, `currentDisplayENU`, `targetENU` properties.
- `Coordinator.sync()`: rewrite aim resolution to use cached direction as fallback, SLERP for transitions.
- `Coordinator.renderer(_:updateAtTime:)`: implement per-frame SLERP interpolation.
- `ContentView`: simplify `orientationRingShowsWait` to only be true during initial startup (no fix ever) or explicit target change.
- `MotionController`: start once in `makeUIView`, remove `restart()` from `sync()` hot path.
- `PointerInfoSheet`: add "heading unreliable in vehicles" copy.

---

## 4. Pointer and ground plane look and feel

### Problem

The arrow is a solid orange cylinder with a yellow cone — functional but reads as a placeholder. The horizon disk is a featureless translucent white circle with an orange radial spoke. Neither communicates scale, bearing, or elevation at a glance. The arrow and disk don't feel like they belong together as a single instrument.

### Design

**Arrow geometry** — explored separately in the Pointer arrow study; current front-runner is the *fletched dart* (slim untapered shaft, a small sharp head that doubles as the end-on circle, four slim vanes, no ring). Key constraints, all met by the dart:

- Monochrome (white / light gray), constant shading (`.lightingModel = .constant`), no scene lighting response.
- Head-on view evokes dot-in-circle; tail-on evokes cross-in-circle — ideally as natural consequences of the 3D shape, not special-cased rendering.
- The arrow's center (not base) sits at the disk's center, so it can point below the horizon.
- Reads as a computed overlay, not an AR object — crisp, synthetic, obviously not in the camera scene.

**Ground plane / compass disk:**

- Replace the featureless translucent disk with a **compass bezel**: degree tick marks around the rim, the translucent membrane carried all the way to the center so the shaft visibly pierces the plane.
- **Tick marks**: fine ticks every 5 degrees, longer ticks every 15 degrees, longest ticks every 45 degrees. No cardinal letters (N/E/S/W) — ticks only. (Earlier drafts said 10°/30°; the built bezel uses 15°/45°.)
- **Scale zero**: a fixed double tick at 0° on the rim — two close ticks, drawn slightly longer than the 45° marks. Monochrome, no accent fill. Replaces the old full-radius orange spoke. (Earlier drafts proposed a brighter single tick or a small triangle; the built bezel uses the double tick.)
- **Target azimuth marker**: a distinct caret (a slim triangle pointing outward to the rim, like the shadow of the arrow's tip) at the target's azimuth, set apart from the scale ticks by shape so it reads as the bearing rather than a graduation. It sits where the arrow's horizontal projection crosses the rim, so the arrow and the marker agree in azimuth. Monochrome, no accent fill.
- **Interior**: a flat translucent white membrane (~0.35 opacity) carried all the way to the center — not a radial gradient. It lifts the dark ticks off the camera feed and reads as the horizon plane the shaft pierces. There is no brighter bezel band at the rim (removed).
- **Material**: constant shading. Ticks and bug are the same dark-neutral line weight; the bug reads as the bearing only because it is doubled and longer, not brighter.
- **Elevation readout**: still pending — not yet built. Intent unchanged: integrate into the disk (small arc/sector) so the separate SwiftUI Az/El capsule becomes nice-to-have rather than necessary.
- **As a spinner**: the spinner is the bezel stripped to its outer ring — same plane, same scale, thin and white — and nothing else: no ticks, no membrane (the interior is fully empty), no center mark, so it can never be mistaken for the finished compass. Because a ring spun in its own plane shows no motion, the life comes from a single crisp, monochrome highlight traveling the rim. It spins at 1 Hz while finding position and 0.5 Hz while loading orbit data (slower = waiting on the network, not the sensors). The chosen motif is the **sweep**: a short bright arc led by a single radial tick, orbiting the rim. The leading tick just gives the sweep a clear direction of travel. Alternates explored: a single orbiting seed tick, a plain sweeping arc, a moving break in the ring, and twin opposed arcs.
- **Spinner → bezel transition** ("this became that," not "this loaded"): the sweep's highlight simply winds down where it is — angular velocity eases to zero over ~0.95 s (continuous from the spin, no jump), coasting roughly half a turn, while the rim sprouts its degree ticks and the membrane fades in. The spinner highlight has nothing to park on (it isn't a bearing indicator), so it simply vanishes; the resolved bezel then carries the readouts — the fixed 0° double tick at the scale zero, and a caret at the target azimuth that the dart points to as it fades in through the disk center (opacity 0→1) — the same arrow appearance described in the startup sequence (§1). If the spin is interrupted it resumes from exactly where it stopped, never jumping to a new position. The outer ring persists through the change as the rim the ticks grow from — one member of the family becoming another.
- **Viewpoint** for the look-and-feel study: the shallow tilt of a phone held up to the scene (the ground plane seen nearly edge-on).


**Arrow + disk coupling:**

- The arrow shaft passes through the disk's center plane. When pointing at the horizon, the arrow is horizontal and bisected by the disk. When pointing up, the arrow tilts upward from the disk center. When pointing down (target below horizon), it tilts downward.
- The bearing bug on the disk ring aligns with the arrow's horizontal projection — they point the same direction in azimuth, reinforcing that they're one instrument.

**Az/El readout (SwiftUI overlay):**

- Keep the capsule readout as an option (toggle in settings) but design the disk so the readout is nice-to-have rather than necessary.
- When shown, position it near the bottom of the screen. Same dark capsule style.

### What changes in code

- `Coordinator.buildArrowNode()`: replace geometry with the fletched dart from the **Pointer arrow study** (the HTML file is the visual + motion source of truth — match its proportions, marks, timings, and the depth/order rules below; the geometry there is Three.js but maps 1:1 to SceneKit nodes).
- `Coordinator.buildHorizonDiskNode()`: replace with compass bezel geometry — SCNShape from a UIBezierPath with tick marks, or procedural geometry from cylinders/boxes.
- Remove `buildFlatDiskSpinnerNode()` — the wait spinner should be a simplified version of the compass bezel (same ring, no ticks, spinning), not a separate geometry.
- Arrow rendering order and disk rendering order should be tuned so the arrow reads in front of the disk from all angles.

**Rendering & depth (carry these over exactly — they caused most of the bugs in the study):**

- **Only the 3D arrow writes depth.** Every flat disk element — outer ring, spinner highlight, degree ticks, 0° double-tick, target caret, and the membrane — must set `writesToDepthBuffer = false`. A flat element that writes depth punches dark/occluded holes in whatever is behind it (in the study, invisible ticks notched the spinning ring). Layer the flat elements with `renderingOrder`, not depth.
- **Draw order:** arrow → membrane → ticks/ring/caret (set `renderingOrder` so the arrow renders first, the membrane after it, the scale marks last/on top).
- **Translucent occlusion (the “pierce”):** the membrane is translucent (~0.35) and does NOT write depth, so it never reads solid. Because the arrow writes depth and is drawn first, its above-plane half stays crisp in front of the membrane while its below-plane half is dimmed *through* the membrane (tinted, not hidden). Do not make the membrane an opaque depth occluder — that reads as a solid disk.
- **Constant shading** (`.lightingModel = .constant`) on everything; monochrome white/light-gray for the disk; the arrow keeps one warm accent at the tip.

**Spinner mechanics (do NOT shortcut these):**

- The spinner free-runs at a constant rate for an unknown, variable time. **Never** resolve by counting turns or by waiting for the highlight to reach a particular spot.
- On fix, the highlight **winds down where it is**: ease angular velocity to zero over ~1 s (continuous from the spin speed), then it fades out as the ticks + membrane fade in. No target, no parking.
- If interrupted and resumed, the spinner continues **from where it stopped** — it never snaps to a new position.
- Resolve ordering: highlight fades fully out FIRST, then ticks/membrane grow in, then the arrow fades in. Teardown reverses it (arrow out over the still-bright membrane, then membrane/ticks out, then spinner back in) so nothing ghosts dark.
- Two static marks appear only once resolved: a fixed **0° double-tick** (scale zero) and an **outward-pointing caret** at the target azimuth (reads like the shadow of the arrow's tip; the arrow's horizontal projection and the caret agree in azimuth).

---

## Verification

After implementation, test these scenarios on a physical device:

1. **Cold launch**: app shows branded moment → camera fades in with spinner → arrow appears when GPS resolves. Should feel deliberate, not loading.
2. **Warm launch from background**: no branded moment, arrow or spinner appears immediately based on state.
3. **Walk test**: select a ground target, walk for 5 minutes. Arrow should never disappear/reappear. Direction should update smoothly as GPS fixes arrive.
4. **Vehicle test**: select the sun, ride in a car for 10+ minutes. Arrow should not reset. If heading drifts, the "heading unreliable" indicator should appear rather than the arrow silently pointing wrong.
5. **Indoor test (no GPS)**: app should show "Finding position..." label with spinner indefinitely. No crashes, no timeouts.
6. **Target switch**: change target while arrow is showing. Brief cross-fade, no flicker.
7. **Compass disk**: tick marks readable, bearing bug tracks the arrow's azimuth, ticks don't obscure camera feed.
8. **Arrow from all angles**: tilt phone to see arrow head-on and tail-on. Dot-in-circle and cross-in-circle should be recognizable.

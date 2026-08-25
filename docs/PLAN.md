# Pointer — plan

## Intent

Build an iOS/iPadOS app that shows a **3D arrow** fixed in the user’s local space (screen-anchored or world-anchored via AR), **rotating** so it always aims toward **one chosen target** from a curated list.

Targets share a theme: their positions are **computable or published**, but **not intuitive** without references—orbital mechanics, astronomy, geodesy, magnetism, or convention.

The experience is exploratory and educational: pick “where should I point?” from a catalog, understand briefly *how* that direction is defined, then see it as a spatial pointer.

## Platform

- **Primary:** iOS and iPadOS (unified SwiftUI lifecycle; iPad layout where it adds value).

### Rendering & interaction (decided)

- **v1:** **SceneKit** full-screen 3D: an arrow in a scene whose orientation updates from **device attitude** (Core Motion) and **user location** when the target needs it. No camera AR requirement yet; tilt and rotation provide the spatial feel.
- **Later:** **ARKit + SceneKit** via **`ARSCNView`** when we want the arrow composited on the real world—reuse the same scene content and direction math where possible.
- **Orientation / location:** Core Motion for device frame; Core Location for observer position on Earth; ARKit only when we add the AR pass.

### Not in scope for first build

- Flat 2D compass-only UI as the primary visualization.
- RealityKit-only path unless we revisit (SceneKit covers non-AR and ARSCNView AR).

## Core user flows

1. **Choose a target** from categories (space, Earth surface, abstract/geometric, cultural/defined points).
2. **See the arrow** update continuously as the device moves and as time passes (for moving targets).
3. **Short context** per target: what coordinate system, what approximations, refresh cadence, and known limitations.

## Example targets (seed list)

- **International Space Station** — Orbital ephemeris (TLE or API); fast-moving.
- **Tiangong space station** — Same class as ISS.
- **Hubble Space Telescope** — Orbital; similar pipeline.
- **James Webb Space Telescope** — Sun–Earth L2 halo orbit; semi-stable, still computed.
- **Center of the Milky Way** — Toward Sagittarius A* (Sgr A*); galactic coordinates → local direction.
- **Magnetic north (dip pole or model)** — World Magnetic Model (WMM/IGRF); moves over years; not the same as geographic north.
- **Geomagnetic pole vs dip pole** — Optional separate entries to teach the distinction.
- **Geographic North Pole** — 90°N; classical “top of Earth.”
- **Geographic South Pole** — 90°S; Amundsen–Scott Station as a surface anchor if useful.
- **Mecca / Kaaba** — Fixed geodetic point; widely published coordinates.
- **Jerusalem (Temple Mount / conventional coords)** — Fixed surface point; define one published datum.
- **Vatican / St. Peter’s Basilica** — Fixed surface point (example of named place).
- **Greenwich Prime Meridian monument** — Fixed; good for “where is 0° longitude on the ground.”
- **Challenger Deep** — Fixed surface coordinates (with datums) for “straight down” into the trench (direction is local vertical + geoid).
- **Summit of Everest** — Published coordinates; vertical deflection matters only for nitpicking.
- **Null Island** — (0°, 0°) in Gulf of Guinea—tongue-in-cheek “defined” point.
- **User’s antipodal point** — Derived from GPS; “through the Earth” direction.
- **Moon (sub-Earth direction)** — Vector to current moon position; classic “where is the moon.”
- **Sun (sub-solar point)** — “Toward the sun center” from observer; clarifies light direction.
- **Polaris (north celestial pole)** — Approximate “true north” in the sky for Northern Hemisphere intuition.
- **Direction of Earth’s orbital motion** — Velocity vector of Earth around the Sun (abstruse but computable).
- **Galactic plane “up”** — Normal to galactic plane (educational).

## Catalog: ancient wonders, New7Wonders, and finalists

These are **must-include** surface targets for the curated list. Each entry ships with **one agreed WGS84 point** (monument, visitor center, or widely cited archaeological coordinate) and UI copy where the location is **approximate or disputed**.

### Seven Wonders of the Ancient World (classical list)

- **Great Pyramid of Giza** (Pyramid of Khufu) — Extant; overlaps with New7Wonders honorary site below—one coordinate set, two catalog entries if we want both labels.
- **Hanging Gardens of Babylon** — No confirmed site; literature often ties to **Babylon** near Hillah, Iraq—disclaimer required.
- **Temple of Artemis** — Near **Ephesus** (Selçuk), Turkey.
- **Statue of Zeus at Olympia** — **Olympia** archaeological site, Greece.
- **Mausoleum at Halicarnassus** — **Bodrum**, Turkey (ancient Halicarnassus).
- **Colossus of Rhodes** — **Rhodes** harbor / Old Town area—position symbolic (statue gone).
- **Lighthouse of Alexandria (Pharos)** — **Alexandria**, Egypt (Pharos island area—approximate).

### New7Wonders of the World (2007 vote) — seven winners

- **Great Wall of China**
- **Petra**, Jordan
- **Christ the Redeemer**, Rio de Janeiro, Brazil
- **Machu Picchu**, Peru
- **Chichen Itza**, Mexico
- **Colosseum**, Rome, Italy
- **Taj Mahal**, Agra, India

### Same campaign — honorary status

- **Great Pyramid of Giza**, Egypt — Declared **honorary** New7Wonder as the only surviving ancient wonder; not one of the seven vote winners.

### Thirteen other finalists (shortlist of 21)

The global campaign started from **21 finalists**; subtract the **seven vote winners** and the **honorary Pyramid**, and **13** sites remain from that shortlist (none of these won the final vote).

- **Acropolis of Athens**, Greece
- **Alhambra**, Granada, Spain
- **Angkor Wat** (Angkor), Cambodia
- **Moai / Rapa Nui** (Easter Island), Chile
- **Eiffel Tower**, Paris, France
- **Hagia Sophia**, Istanbul, Turkey
- **Kiyomizu-dera**, Kyoto, Japan
- **Moscow Kremlin**, Russia
- **Neuschwanstein Castle**, Füssen, Germany
- **Statue of Liberty**, New York, USA
- **Stonehenge**, Amesbury, UK
- **Sydney Opera House**, Australia
- **Timbuktu** (Great Mosque / city), Mali

## More ideas to add over time

**Satellites & space hardware:** Starlink “train” is a set, not one point—optional “nearest shell object.” GPS is a constellation—optional “nearest visible PRN” for advanced mode. LRO, Mars Reconnaissance Orbiter if we add planet-centric frames (heavier scope).

**Deep-sky / standard directions:** Vernal equinox direction on the celestial sphere; **Voyager 1/2** heliocentric state vectors (very long-range “pointers”). **Proxima Centauri** or **Alpha Centauri**—unit vector toward a named star.

**Earth geodesy:** **Projected coordinate system origin** for a national grid (niche). **Geographic center** of a country (several competing definitions—good for “this is arbitrary” education).

**Cultural / historical (all need exact published coordinates and sensitivity in copy):** Varanasi ghats; Lourdes; Mount Fuji summit; Uluru; Kaaba already listed; **wonders** are enumerated above (including Giza under ancient + New7Wonders honorary).

**Magnetic / ionospheric:** Aurora oval centroid is dynamic—probably out of scope unless we simplify.

## Technical notes (non-binding)

- **Moving targets:** propagate from TLE (SGP4) or trusted APIs; cache and refresh on a sane interval.
- **Galactic / celestial:** transform from ICRS or galactic coordinates to observer-centered horizontal or camera frame; nutation/precession if we aim for arcminute-level seriousness.
- **Magnetic:** use WMM coefficients with clear “model valid until …” messaging.
- **Surface points:** WGS84 latitude/longitude → ECEF → local tangent east/north/up at user → align arrow.
- **“Center of the universe”:** implement as explicit **non-target** educational card or remove from literal pointer list unless we adopt a clearly labeled metaphor.

## Non-goals (for now)

- Multiplayer or social layers.
- Replacing navigation apps or Islamic prayer apps—respect specialized accuracy requirements if we ship Mecca/Qibla; link out or disclaim where appropriate.

## Success criteria (draft)

Track against the implementation roadmap; update when a milestone ships.

- [x] **Smooth arrow update** on device rotation — Core Motion + stabilized SceneKit (stub axis); revisit after Step 5 for ground targets.
- [x] **Correct qualitative direction for Earth-fixed targets** — `xTrueNorthZVertical` + great-circle initial bearing + arrow twist (Step 5; validate on device).
- [x] **Documented limitations** for non-ground sources — `DATA_SOURCES.md` (TLE, Horizons, SIMBAD, WMM, etc.); in-app satellite ephemeris not built yet.

---

## Implementation roadmap (weekend-sized steps)

Work top to bottom; each step is intended to finish in **one or two focused sessions** so you can pause between weekends without losing the thread. Skip ahead only when a dependency is already done.

### Roadmap progress

Last reviewed against the repo: **2026-04-20**.

- **1 — Project shell** — **Done.** SwiftUI app, iOS 17+, iPhone + iPad; builds and runs on simulator and device.
- **2 — SceneKit arrow** — **Done.** `ArrowSceneView` geometry + lighting + camera; arrow visible.
- **3 — Core Motion → arrow** — **Done.** Stabilized root + stub **+X** axis; predictable tilt on device (simulator motion is weak).
- **4 — Core Location** — **Done.** `LocationService`, when-in-use; details + coordinates in **info** sheet (bottom-left).
- **5 — Earth-fixed aim** — **Done.** WGS84 ECEF → local ENU chord in `Geodesy`; `ArrowSceneView` + `.xTrueNorthZVertical` when ground target + fix; stub otherwise.
- **6 — Catalog v0** — **Partial.** Catalog + picker drive aim when location available; polish remains.
- **7 — Context cards** — **Not started.**
- **8 — Moving target (ISS-class)** — **Not started.**
- **9 — Expand surface catalog** — **Not started.** Many rows already in JSON; “expand” means polish + behavior + copy.
- **10 — Polish pass** — **Not started.**
- **11 — AR pass** — **Not started.** Optional.
- **12 — Prettified screenshot** — **Not started.**

**Optional track** (fixed celestial / SIMBAD-class): not started.

### Step 1 — Project shell

- Create an Xcode SwiftUI project for **iOS + iPadOS** with a unified lifecycle and a sensible minimum deployment target.
- Add a minimal app structure: root view, placeholder for the 3D view, placeholder for target selection (even a single hardcoded title).

**Checkpoint:** App launches on simulator and device; empty UI is navigable.  
**Status:** Done (see **Roadmap progress** above).

### Step 2 — SceneKit arrow (no sensors yet)

- Embed **`SCNView`** (or wrapper) in SwiftUI.
- Build a scene with a readable **arrow** (cone + cylinder or imported asset), lighting, and camera framing.

**Checkpoint:** Arrow is visible and stable when you rotate the simulator/device *without* tying attitude to the arrow yet.  
**Status:** Done (superseded by Step 3 wiring; arrow geometry unchanged).

### Step 3 — Core Motion → arrow orientation

- Subscribe to device attitude (quaternion or rotation matrix).
- Drive the arrow’s orientation so it represents a **test direction** in world space (e.g. always “north” in a dumb stub, or fixed axis) to validate the math pipeline.

**Checkpoint:** Tilting the physical device clearly moves the arrow in a predictable way.  
**Status:** Done — stub axis (+X); validate on a physical device.

### Step 4 — Core Location plumbing

- Request **when-in-use** authorization; handle denied/restricted states in UI.
- Subscribe to location updates (or significant-change if you prefer early battery savings); expose latitude, longitude, and horizontal accuracy to your model layer.
- **In-app:** the **info** control (bottom-left) opens a sheet with **GPS status/coordinates**, **selected target** geography (or stub explanation), **great-circle distance and initial bearing** when both a fix and a catalog point exist, **next-step / roadmap copy** (no persistent footer bar), **Settings** when denied, and **build metadata** (version / build / bundle id).

**Checkpoint:** UI or debug overlay shows live user coords on device (simulator may need a simulated location).  
**Status:** Done — info sheet + `LocationService`.

### Step 5 — One Earth-fixed target (direction math)

- Pick **one** landmark with a fixed WGS84 coordinate (hardcoded constant is fine).
- Implement **user position + target lat/lon → direction** in the frame your arrow uses (ECEF → local ENU or equivalent), then combine with attitude from Step 3 so the arrow points **at** the landmark.

**Checkpoint:** On a real walk or drive, the arrow’s intent matches “that way” qualitatively for the fixed point.  
**Status:** Done — wiring in `ArrowSceneView` + `Geodesy`; confirm outdoors on hardware.

### Step 6 — Catalog v0 (static list)

- Move the single target into a **small static catalog** (Swift data, JSON bundled in app—your call). The repo already ships **`Pointer/GroundTargets.json`** as a starter bundle you can decode when ready.
- **Picker chrome:** the top **“Pointing at”** surface is an **expando**: collapsed it shows the current selection; expanded it shows a **categorized menu** (groups from JSON—ancient wonders, New7Wonders legs, seed rows, plus a **Motion (test)** stub until ephemeris targets exist). Selection updates **model state** immediately; the arrow follows once **location + bearing** exist (Steps 4–5) and later **moving targets** (Step 8).
- Keep sections **scrollable** and cap expanded height so the camera + arrow stay visible.

**Checkpoint:** Switching rows updates the selected target in-app; switching rows changes where the arrow aims when a GPS fix exists **without new UI work** (bearing in Step 5).  
**Status:** Partial — picker + aim + decode; remaining work is polish and context cards (Step 7).

### Step 7 — Per-target context card

- For each catalog entry, store **short educational copy**: definition of the direction, datum, rough refresh expectations, “good enough” caveats.
- Present as sheet, panel, or secondary screen—whatever matches your shell from Step 1.

**Checkpoint:** Every selectable target explains *what* you’re pointing at without relying on external docs.

### Step 8 — First moving target (ISS-class)

- **Preferred path:** fetch **CelesTrak** (or Space-Track, if you onboard to their terms) **TLEs**, propagate on-device or in app code with **SGP4**, cache with a timestamp, refresh on a sane interval. Isolate behind a small service type so you can swap sources.
- **Secondary / demo path:** HTTP APIs (**N2YO**, **Where The ISS At**, etc.) or **NASA** `api.nasa.gov` ISS location endpoints for quick prototypes—treat as **less rigorous** than TLE+SGP4; keep them behind the same interface if you use them at all.
- Show **ephemeris age** (TLE epoch or last fetch time) in the context card.

**Checkpoint:** Arrow tracks a fast-moving target noticeably differently than a fixed landmark.

### Optional track — Fixed celestial targets (after Step 8 feels stable)

- For **stars / Sgr A\* / deep-sky** objects, start from authoritative **ICRS/J2000** coordinates—**SIMBAD** is the usual name-resolution and citation path; ship **precomputed unit vectors** in v1 rather than bundling **Gaia** or large catalogs.
- **HYG**-style compact catalogs are fine for hobbyist sky lists if you outgrow a tiny named list.
- The pipeline matches everything else: **catalog direction → topocentric Alt/Az** for the user’s location and time, then into the device frame (same “unifying transform” idea as `DATA_SOURCES.md`).

### Step 9 — Expand surface catalog slowly

- Add **ancient wonders / New7Wonders / finalists** with agreed WGS84 anchors and disclaimers where sites are disputed.
- Resist expanding categories until surface pipeline feels solid.

**Checkpoint:** Multiple independent Earth-fixed pins behave; copy warns where coordinates are approximate.

### Step 10 — Polish and honesty pass

- Tune motion/location update rates vs smoothness vs battery.
- Centralize **error states**: no location, stale TLE, network failure for APIs.
- Re-read success criteria above and tick them off explicitly.

**Checkpoint:** You’d be comfortable demoing to a friend without apologizing for rough edges.

### Step 11 — AR pass (defer until non-AR feels correct)

- Spike **`ARSCNView`** sharing the same arrow node / direction logic where possible.
- Treat as optional: ship without AR if schedule slips.

**Checkpoint:** Arrow overlays camera pass with plausible alignment (exact calibration can stay iterative).

### Step 12 — Prettified screenshot

Goal: ship a **single action** that saves or shares an image worth posting—clean composition, readable caption, no accidental HUD clutter.

- **Trigger:** toolbar / overflow action, or an explicit **“Capture”** control (avoid accidental screenshots from volume buttons unless you document it).
- **What to capture:** composite of **camera feed + SceneKit arrow + “Pointing at” label** (and whatever branding you want). Optionally **strip** dev-only overlays or show a **simplified** caption line for export only.
- **Prettify levers (pick a minimal set for v1):**
  - Fixed **aspect ratio** or **safe margins** so crops for social or App Store previews don’t clip the arrow.
  - Optional **footer strip**: target name, UTC date/time, coarse place (city-level) only if privacy copy allows—otherwise omit location.
  - Optional **wordmark** or tint consistent with app chrome.
  - **Temporal anti-flicker:** pause or average one frame of video if banding shows up in exports.
- **Implementation sketch (choose one path and isolate behind something like `ScreenshotComposer`):**
  - **`ImageRenderer`** over a SwiftUI subtree built for export (easiest iteration on layout).
  - **`UIView.drawHierarchy(in:afterScreenUpdates:)`** / **`UIGraphicsImageRenderer`** on a dedicated container that mirrors the live UI.
  - **SceneKit / Metal snapshot** only if vector-level crispness on the arrow matters more than iteration speed.
- **Delivery:** **`PHPhotoLibrary`** (add **Photo Library usage** string), **`UIActivityViewController`**, and/or **temporary file** for AirDrop.
- **Honesty:** screenshot is a **composed illustration** of the experience—fine for marketing if labeled; for bug reports, offer a separate **plain** capture mode without prettification.

**Checkpoint:** One tap produces a shareable image that looks intentional, not a raw framebuffer grab.

---

## Where the old “next step” landed

Steps **1–5** are **done** in-repo: ground targets use **great-circle initial bearing** plus Core Motion **`.xTrueNorthZVertical`** so the arrow shaft (**local +Y**) aligns with that horizontal direction while the stabilized root tracks attitude. Step **6** is **partial** (catalog + picker + aim wiring); **8** (moving targets / ISS-class) remains the next major slice after catalog polish.

---

## Later ideas (backlog, unordered)

Captured for when the core surface pipeline feels solid; no ordering implied.

- **Icon and splash screen** — App Store asset set and launch storyboard / SwiftUI splash consistent with the in-app overlay style.
- **Compass-only (surface) mode** — 2D map or compass rose that shows **initial bearing on the tangent plane only** (no chord dip), as a contrast to the full 3D chord aim; useful for “walking direction” intuition and teaching the difference vs the current pointer.
- **Plane / horizon indicator** — A subtle **local horizontal plane** (disk, grid, or horizon line) in the SceneKit overlay so **elevation above/below that plane** (dip relative to tangent) reads at a glance; reinforces chord vs great-circle tangent.
- **Globe mode** — Separate **map or 3D globe** view: observer and target as pins, **great-circle arc on the ellipsoid**, and the **straight chord** through the Earth (or the ECEF segment) so “piercing line” and curvature are visible; pairs with education copy in context cards.
- **Different arrows** — Alternate arrow **geometries or materials** (sleek pointer, bold tourist style, accessibility scale) chosen in settings or per theme; share the same aim quaternion path.

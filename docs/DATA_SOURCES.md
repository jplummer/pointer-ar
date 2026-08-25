# Pointer — data sources

Ground-fixed targets ship as bundled `Pointer/GroundTargets.json` (WGS84 latitude and longitude). Each entry includes starter `sources` URLs for verification and iteration.

This document covers **non-ground** targets and **magnetic** models referenced in `PLAN.md`.

## Low Earth orbit satellites (ISS, Hubble, Tiangong, etc.)

**Preferred workflow:** NORAD-style **two-line elements (TLE)** plus **SGP4** propagation—the same algorithm family used in many operations-style toolchains. **CelesTrak** publishes convenient TLE bulletins with clear documentation.


| Approach                                                 | What you get                                                           | Notes                                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **CelesTrak** two-line elements (TLE)                    | Free bulletins for many objects; propagate with **SGP4/SDP4**.         | Default for Pointer: refresh TLEs every few hours to daily depending on accuracy needs.      |
| **Space-Track.org**                                      | Official TLEs for many payloads; requires account acceptance of terms. | Use when you need operational-quality elements and compliance expectations are clear.        |
| **Community APIs** (e.g. **N2YO**, **Where The ISS At**) | Ready JSON positions for demos.                                        | Rate limits and Terms of Service apply; convenient; usually **not** the precision reference. |
| **NASA** (`api.nasa.gov`, ISS location helpers)          | Quick ISS position JSON for prototypes.                                | Handy smoke test; treat as **secondary** to TLE+SGP4 if you care about rigorous propagation. |


Implementation sketch: download TLE → run SGP4 to ECI position at time *t* → rotate Earth-fixed observer (WGS84) into the same frame → subtract to get topocentric direction → map into the device frame with attitude.

## Unifying concept — coordinate transforms

Most non-ground targets eventually follow the same pipeline:

1. Represent the object in a **standard astrometric frame** (e.g. **ICRS/J2000** RA/Dec for stars; **ICRS/GCRS**-style vectors for solar-system work; **ECI** from SGP4 for Earth orbiters).
2. Reduce to **observer-centered horizontal coordinates** (altitude/azimuth or an equivalent topocentric vector) using the user’s **WGS84** position and **UTC** time (precession/nutation/refraction added only when you need that level of fidelity).
3. Combine with **device attitude** from Core Motion to express the direction in the SceneKit camera frame.

Python ecosystems (**Skyfield**, **Astropy**) document this pipeline well and are useful references even when the app ships Swift-only math.

## Deep space / Sun–Earth L2 (e.g. JWST)


| Approach                 | What you get                                               | Notes                                                                        |
| ------------------------ | ---------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **JPL Horizons**         | High-accuracy ephemerides for spacecraft and major bodies. | Batch or API-style workflows; excellent for slow-moving targets outside LEO. |
| **SPICE kernels** (NAIF) | Same class as mission analysts use.                        | Heavier integration; great if you standardize on one astronomy stack.        |


## Solar system bodies (Moon, Sun, planets)

**Authoritative reference:** **NASA/JPL Horizons** (often backed by **DE440** / **DE441** planetary ephemerides). Query via web UI, email API, or telnet-style workflows depending on your tooling.


| Approach                            | What you get                                     | Notes                                                                     |
| ----------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------- |
| **Swift AA** (open source)          | Astronomical algorithms in Swift-friendly form.  | Useful for Moon/Sun direction without shipping a full SPICE stack for v1. |
| **JPL Horizons**                    | Authoritative vectors for bodies and spacecraft. | Cross-check library outputs; heavy batch usage may need caching.          |
| **Skyfield** / **Astropy** (Python) | Same geometry in friendly APIs.                  | Strong docs for reproducing vectors before you freeze constants in Swift. |


## Stars / galactic center


| Approach                         | What you get                                                      | Notes                                                                            |
| -------------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **SIMBAD**                       | Canonical identifiers and **ICRS** coordinates for named objects. | Resolve names (“Sgr A*”, bright stars, Messier objects) before freezing vectors. |
| **Gaia DR3**                     | Ultra-precise astrometry for enormous star counts.                | Overkill for early builds; use when you need catalog-scale inputs.               |
| **HYG Database**                 | Compact bundled star list for hobbyist sky visualizations.        | Fine for curated “bright star” modes if licensing fits.                          |
| **Precomputed unit vectors**     | ICRS direction toward Sgr A*, Galactic center, M31, bright stars. | Stable in app; SIMBAD cites the canonical numbers.                               |
| **Erfa / SOFA**-style reductions | Rigorous coordinate transforms (precession, nutation).            | Add when you outgrow “good enough” catalog vectors.                              |


**Milky Way center:** treat as a **fixed** ICRS direction toward **Sgr A** (verify current SIMBAD values for your build); local sky motion is the usual Earth-rotation + observer pipeline, not an ephemeris hunt for the galaxy center itself.

## Geomagnetic north (World Magnetic Model)


| Approach                                             | What you get                                               | Notes                                                                             |
| ---------------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **NOAA WMM** coefficients + reference implementation | Declination and field vector on and above Earth’s surface. | Ship a **model validity window** in the UI; coefficients update every five years. |


Pointer can compute a **horizontal direction** from declination at the user’s location, then express it in the SceneKit camera frame.

## Ionosphere / space weather

Generally **out of scope** for v1 unless you model aurora oval motion explicitly.

## “Center of the universe”

No physical pointer is defined in standard cosmology. Treat as **educational copy** or omit from numeric pointing (see `PLAN.md`).

## Operational hygiene

- **Caching:** TLEs and ephemeris fragments should be cached with timestamps and source URLs.
- **Attribution:** retain license and attribution requirements for each feed (CelesTrak, mission APIs, etc.).
- **Privacy:** prefer on-device propagation when possible; location + time reveals user context—avoid shipping raw queries when not needed.


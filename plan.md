# Plan

Three buckets: **(1) Definitely**, clear improvements; **(2) Recommended**,
which follows from `vision.md`; **(3) Side quests**, which are optional and fun.
There's a suggested order at the end.

## Working agreement

- Agents commit after each coherent, working chunk of work (roughly one numbered
  item, or a clear sub-step of it). Tests must pass before committing, with a
  descriptive message. Commit to `main` unless the change is risky or
  experimental; then use a branch.
- `make test` runs everything locally: unit tests, golden-image tests and CLI
  tests. There is no CI.
- Any renderer or performance change updates `Performance.md` with numbers.

---

## Architecture: the quadtree tile cache

This is the backbone of "silky motion" and "deep zoom". It's described here
because several plan items depend on it.

- **Tiles.** A tile is (level, ix, iy), with 256×256 samples. A level-L tile
  covers `3 / 2^L` of the complex plane. At deep zoom the tile indices are
  arbitrary-precision, so tile keys are stored *relative to an anchor* (the
  perturbation reference point, or a nearby high-precision point). They are not
  absolute integers.
- **Tile contents.** Store raw data, not colour: a float32 smooth iteration
  count plus an "inside the set" flag (and later a distance estimate). Keep them
  in a Metal texture array or heap. Colour is applied when drawing the frame,
  so changing palettes costs nothing.
- **Drawing a frame (every frame, cheap, on the GPU).** For each area of the
  screen, use the finest cached tile at or below the ideal level. If it's
  missing, fall back to a parent tile and scale it up. Blend between the two
  nearest levels according to the fractional zoom, as in trilinear
  mip-mapping. **Blend after colouring, not before:** interpolating iteration
  counts across the set boundary, or across a doubling of the count, produces
  false colours. Blending colours is safe.
- **True mipmaps going upward.** A parent can be made *exactly* by averaging
  its four children's colours. That gives anti-aliased zoom-out almost for
  free, and in practice it's better-looking than computing the parent directly.
  Going downward, a child always needs new computation; upsampling the parent
  is only a placeholder while it's computed.
- **Refinement without popping.** When a finer tile arrives, fade it in over
  about 100–150 ms.
- **Work queue.** Only tiles that will be visible. Coarse before fine, centre
  before edges. Cancel tiles that go off screen. Prefetch one level in the
  direction of the current zoom gesture. Time-slice GPU work so it never costs
  a displayed frame.
- **Memory.** LRU eviction with a budget per device (about 256 KB per tile
  with float32; say 150 MB on iPhone and 500 MB on Mac). Never evict the
  current screen or its ancestors. At deep zoom you only ever see a narrow cone
  of the quadtree, so cache use stays bounded.
- **Precision per tile.** Each tile's level decides its renderer (float,
  double-float, or perturbation). Renderer selection falls out naturally.
- **Pays off again.** Zoom movies (2.6) are just the chain of ancestor tiles
  along a path, rendered as keyframes. This is the technique used by
  zoomasm/Kalles Fraktaler.

The trade-off: the cache is a substantial piece of engineering, and it's
overkill below about 10³× zoom. But deep zoom plus 120 Hz motion is exactly
where recomputing the whole screen breaks down, so I think it's the right bet.
It's also great material for the portfolio.

---

## 1. Definitely do

**1.1 Land the uncommitted CLI work.** ✅ Done in `7cdb991` (CLI, PNG and
raw-count export, headless tests). Leftovers: add `*.profraw` to `.gitignore`,
and remove `xros` from `SUPPORTED_PLATFORMS`.

**1.2 Fix `metal-double`.** ✅ Done in `7cdb991`. Fast math is off, implicit
multiply-add contraction is disabled, the aspect ratio and escape test now use
FloatFloat, and the evidence is in `evidence/floatfloat/`. An optional
leftover, for speed: compute `realMin`, `imagMax` and per-pixel steps on the
CPU and pass them in as FloatFloat, removing the per-pixel `dd_div`. Check
whether disabling fast math slowed the Float kernel.

**1.3 Golden-image test harness.** A small, fixed set of locations (the whole
set, Seahorse Valley, a 1e10 zoom, and later 1e50 and 1e200). For each, store
reference iteration counts (from CPU `baseline` in Double, or from a
high-precision reference for deep points) plus a reference PNG. Each renderer
must match the counts within tolerance: exact on most pixels, with a small
allowed percentage of boundary pixels that differ. Wire it into `make test`,
together with the CLI tests and unit tests. Starting point: the 1e7 FloatFloat
accuracy regression (`MANDELBROT_TEST_METAL=1`) and the `.u16` count dumps in
`evidence/floatfloat/`. Generalise that into a fixture directory with one
entry per location.

**1.4 Keep the whole pipeline on the GPU.** Store counts in shared buffers or
textures, not `[Int]`. Colour in a Metal kernel. Present through an
`MTKView` wrapped for SwiftUI. Benchmark "kernel only" separately from
"end to end".

**1.5 Smooth colouring plus a curated palette set.** Use a normalised
iteration count with bailout 256. Offer 6–8 good palettes (a gradient lookup
table as a 1D texture), with a pleasant default. Candidates: a classic
blue-gold "Ultra Fractal" style gradient, fire, ice, monochrome ink, twilight,
and a perceptually uniform cyclic map. Add a density/offset control so the
palette fits the depth.

**1.6 Refactor for readability (portfolio grade).**
- A `Viewport` model (center, scale, screen↔complex conversion), replacing the
  three copy-pasted conversions.
- A `Renderer` protocol with a small registry, replacing string-typed variants.
- Separate viewer, benchmark and docs views.
- One command table that drives keyboard shortcuts, the menu bar and the help
  overlay.

**1.7 Hide the developer tools.** Remove the renderer menu and the HUD details
from the main UI. Add a **Developer panel**, containing the benchmark, a
renderer override, a HUD toggle and tile-cache debug overlays. To open it:
- **iOS:** Settings → About → tap the version number 7 times (as on Android).
  Alternatively, a three-finger long-press.
- **macOS:** a Debug menu that only appears while ⌥ is held when you open the
  menu bar, or is enabled by a defaults flag.
The benchmark gets a "Share results" button (a Markdown table plus device
model), so friends can send their numbers back.

**1.8 Input basics on both platforms.**
- *iOS:* pinch anchored at the fingers (already done), double-tap to zoom in,
  two-finger tap to zoom out, and momentum/inertia on pan and pinch. Replace
  the quad-tap and edge-double-tap gestures with visible controls or
  automatic behaviour.
- *macOS:* scroll and trackpad zoom anchored at the cursor, double-click zoom,
  arrow keys, and menu commands.

---

## 2. Recommended (the vision)

**2.1 Quadtree tile cache and a per-frame compositor.** See the Architecture
section above. Build it in stages:
(a) a tile renderer with a fixed level plus the compositor, used for panning
only;
(b) multiple levels with fallback to parent tiles, so zooming is smooth;
(c) blending between levels plus fade-in;
(d) mip-averaging upward, prefetching and memory budgets.
Add debug overlays (tile borders and levels) to the Developer panel.

**2.2 Perturbation-theory deep zoom.** ✅ Completed; see the 2.2 sections in
`Implementation.md`, `Architecture.md` and `Performance.md`.
- *Library:* borrow, with a permissive licence. GMP and MPFR are LGPL, which is
  awkward for statically linked iOS App Store builds. Candidates:
  Boost.Multiprecision `cpp_bin_float` (header-only, Boost licence, via Swift's
  C++ interop), or a pure-Swift BigInt (such as attaswift/BigInt, MIT) used as
  fixed-point. Spike both and benchmark reference-orbit speed at 1e100 and
  1e1000.
- Compute reference orbits on the CPU, and per-pixel deltas on the GPU in
  float, or double-float when needed.
- Glitch detection (Pauldelbrot) and re-referencing.
- Extended-exponent floats (a mantissa plus separate exponent) beyond about
  1e-300.
- Then bilinear approximation (BLA) to skip iterations. That's where deep
  renders go from minutes to seconds.
- Golden tests at 1e50, 1e200 and 1e1000.

**2.3 Automatic iteration depth.** Depth-based first estimate and manual detail
multiplier implemented after the 2.2 review, with a one-million GPU cap and
separate count/correction storage. Pixel-driven adaptation, periodicity checking
and selective state continuation remain outstanding. Follow-up fixes retain
escaped samples across limit changes and stream extendable reference orbits;
capped tile pixels currently restart in bounded worker scratch. Two layers:
- *Starting guess from depth:* `maxIter ≈ 200 + 80·log2(scale)`. That gives
  200 at 1×, about 2,000 at 1e7 (which matches the FloatFloat evidence) and
  about 27,000 at 1e100. Calibrate the constants against the golden locations.
  This is only a first guess: near minibrots the needed depth grows with the
  minibrot's period, not with zoom.
- *Correction from data:* use the coarse pass (or the parent tile) to decide.
  Without detecting interior points you can't tell a genuinely interior pixel
  from one that needed more iterations, so this depends on periodicity checking
  (2.8). Any pixels that hit the limit are then either known to be inside or
  genuinely unresolved:
  - raise the limit (to about 2× the current one) while more than about 0.1% of
    pixels are unresolved;
  - lower it (to about 2× the 99.9th percentile of escaped counts) when the
    highest escaped count is below a quarter of the limit.
  Use hysteresis, only raise during gestures, and only lower at idle, so
  tiles don't flicker.
- *Deep-zoom hint:* the perturbation reference orbit's escape iteration, or its
  period, gives a strong estimate for free.
- *Tile cache:* a tile stores which limit it was computed with. Raising the
  limit only recomputes the pixels that hit the old limit; escaped counts stay
  valid.
- *Colouring:* palette mapping must depend on counts (for example relative to
  the lowest escaped count in view), never on `maxIter`. Otherwise
  auto-adjusting would shift the colours.
- *UI:* the +/− controls become a "detail" multiplier on the automatic value.
  Friends and family never need to touch it.

**2.4 Locations: bookmarks, history, sharing.** A `Location` type (center
stored as an arbitrary-precision decimal string, scale, iterations, palette).
Back and forward history. A universal link or `mandelbrot://` URL scheme, and
the share sheet. A starter gallery of famous spots, which doubles as onboarding
for friends and family.

**2.5 Julia companion.** A picture-in-picture panel (iPad and Mac:
side-by-side, iPhone: a corner inset) showing the Julia set for the point under
the cursor or finger, updated live. It's cheap: one small float render per
frame. Tap to swap the main and companion views. The Julia view reuses the same
tile cache and palettes.

**2.6 Zoom movies.** Pick a start location (by default the whole set) and an
end location (the current view or a bookmark). Render the keyframe chain (one
image per zoom level of 2× along the path, straight from the quadtree). Then
compose an exponential zoom video by interpolating between keyframes, and
write it with AVAssetWriter (HEVC/H.264). Options: duration, resolution
(1080p/4K), palette cycling, ease in and out. Render in the background with
progress, and share the result. This is the feature people will post.

**2.7 High-resolution still export.** Tiled supersampled render at any size.
PNG with the location embedded in the metadata. Shares code with the CLI
`--render`.

**2.8 Cheap performance wins.** Skip the main cardioid and the period-2 bulb,
and use periodicity checking for points inside the set. Measure each as a
benchmark variant.

**2.9 Ready for the App Store and for employers.**
- *App Store:* iPhone and iPad layouts, app icon variants, launch screen,
  first-run hint ("pinch to zoom"), the privacy label (no data collected),
  and TestFlight for friends and family first.
- *Employers:* a README with screenshots and a zoom GIF, an architecture doc
  (the tile cache and the precision ladder, with diagrams), `Performance.md`
  as a proper write-up, and a short "what I learned" section.

---

## 3. Side quests

- **Orbit visualiser.** Hover or long-press to draw a point's orbit. Also
  useful when debugging perturbation.
- **Distance-estimate shading and 3D relief lighting.** A natural extension of
  the palettes, and very photogenic.
- **Minibrot hunter.** Find nearby minibrots with Newton's method on periodic
  points, then fly to them. Great combined with zoom movies.
- **Screensaver / live wallpaper.** An endless zoom along a pre-found deep
  path.
- **Palette cycling and a palette editor.** Later extensions to 1.5.
- **Sound of the set.** Turn a point's orbit into audio.
- **Buddhabrot / Nebulabrot mode.**
- **Other formulas.** Burning Ship, Multibrot, Tricorn.
- **Benchmark leaderboard.** A cross-device comparison of friends' results.

---

## Suggested order

1. **Groundwork:** (1.1 and 1.2 are done) → 1.3 (golden tests, so later
   changes are safe) → 1.6.
2. **Looks and feel:** 1.4 → 1.5 → 1.7 → 1.8. At this point you can ship to
   friends on TestFlight.
3. **Smooth motion:** 2.1 (a–d); 2.8 (periodicity checking) → 2.3.
   The depth-based starting guess from 2.3 can land at any time, even now.
4. **Deep:** 2.2 (library spike first).
5. **Share:** 2.4 → 2.6 → 2.5 → 2.7.
6. **Ship:** 2.9 → App Store.

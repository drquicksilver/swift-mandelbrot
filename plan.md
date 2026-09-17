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
- **Pays off again.** Zoom movies (2.8) are just the chain of ancestor tiles
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

**2.3 Automatic iteration depth.** ✅ Completed, except the parts that need
periodicity checking, which move to 2.10. See the 2.3 sections in
`Performance.md` and `Implementation.md`.
- *Starting guess from depth:* `maxIter ≈ 200 + 80·log2(scale)`, rounded to 200.
  Calibrated against the golden locations, no depth-only slope fits both: c = i
  at 1e1000 escapes within about 2,700 iterations (the estimate gives 266,000),
  while the period-312 minibrot at 1e100 needs up to 60,000 (the estimate gives
  about 26,800). The slope stays generous, because the observed ceiling removes
  overshoot once the view settles, while undershoot hides escaping detail.
- *Lowering from data (done):* once every visible tile is complete, cap the
  automatic limit at 2× the highest escaped count in view when that count is
  below a quarter of the limit. Deviation: the maximum, not the 99.9th
  percentile, which makes lowering exact (nothing escapes between the maximum
  and the old limit, so the picture is unchanged). Counts 1.5× those the ceiling
  came from release it; further zoom grows it at the estimate's slope. Decreases
  still wait 300 ms after input and motion stop.
- *Raising from data (→ 2.10):* raise while more than about 0.1% of pixels are
  unresolved. Without interior detection a capped pixel may be inside the set,
  so this needs periodicity checking.
- *Deep-zoom hint (→ 2.10):* the reference orbit's period or escape iteration.
- *Tile cache (done):* each tile stores its limit and highest escaped count.
  A decrease recomputes nothing. A raise re-samples only capped pixels and
  recolours only when a record holds a count the old limit coloured as capped.
  A tile with no capped pixels is exact at any higher limit. Capped pixels
  restart from iteration 0 instead of resuming (→ 2.10, re-measure): once
  periodicity marks interior pixels, few genuinely unresolved pixels remain, and
  retained orbit state would cost 1–3 MB per tile.
- *Colouring (done):* palette phase depends on counts; the limit only marks
  counts at or above it as capped.
- *UI (done):* automatic by default, with a detail multiplier (Settings,
  ⌘[ / ⌘]) and a manual mode.

**2.4 Coverage pyramid.** ✅ Completed. Alongside the visible-detail cache, a
bounded pyramid of coarse tiles keeps zooming out drawable after cold jumps.
- *Selection.* The root footprint plus near offsets 1…8 and a sparse tail
  16…512, in that priority order, each group all-or-nothing. Projections stop
  at the viewport's minimum scale. Deviation: quarter resolution (L − j − 2)
  needs 6–18 tiles per offset on a phone and 20–35 on a large Mac display, so
  each offset takes the finest level at or below it that fits 6 tiles (offsets
  1–2) or 4. In practice that is 1/8–1/16 resolution.
- *Storage.* Coverage records are marked separately, protected from LRU,
  recoloured with the palette, sampled at their own level's estimate, and never
  extended. The cap is a tenth of the budget (at least 30 MiB, at most 64 tiles),
  never more than the bytes left after the detail band. Choosing detail reserves
  the root and offsets 1–2. On a phone at 150 MiB a full-resolution view leaves
  room for about that much; a Mac at 500 MiB holds the whole near ladder.
- *Memory pressure.* A coverage tile makes room by discarding lower-priority
  coverage (farthest first). The root is never deferred; deferred coverage
  returns when a tile fits again. Only the planned root footprint, plus up to
  nine cells of earlier footprints until it completes, is protected; other
  root-level records are ordinary LRU entries. Eviction removes records the
  current frame still draws last.
- *Scheduling and composition.* Root first, then the local preview/visible
  band, near coverage, sparse coverage and zoom-in prefetch. Bounds-based coverage
  lookup bypasses the 62-level ancestor limit. Old-anchor coverage stays as
  fallback until a new root has completed. Zoom-out prefetch is satisfied by the
  protected band: levels L − 1 and L − 2 are computed with the view.
- *Accepted deviation.* The root is relative to the current grid anchor, not a
  fixed world anchor, and is recomputed after re-anchoring (one cheap tile).
- *Tests.* Projection unit tests, including at 1e1000; sentinel-free long
  zoom-outs after a cold deep jump; phone- and Mac-shaped sweeps at real budgets,
  shallow and at 1e1000, under a watchdog; 2×, 4× and 16× zoom-outs served
  from their planned levels; cold-jump latency with coverage on and off;
  update and plan p95 while moving at 1e1000; a pan through empty space;
  deferral under pressure and its recovery. 2.5 rotation must expand the
  projected footprint.

**2.5 Navigation feel: trackpad panning, rotation, gentle bounds.** ✅ Completed.
- *Mac two-finger scrolling pans.* Precise deltas pan and follow the system's
  natural-scrolling setting; AppKit momentum continues the pan and the
  interaction ends with momentum, not with the fingers. Wheels and ⌘-scroll zoom
  at the cursor. `rotate(with:)` rotates about the cursor, interleaved with
  `magnify(with:)`.
- *Twist to rotate.* iOS tracks the two touches itself and solves for the
  transform pinning both fingers (rotate and scale about the previous midpoint,
  then translate), replacing the pan and pinch recognisers. The first 10° of
  twist are ignored, snapping is within ±3° of a right angle with a haptic tick
  on iPhone, and a compass button animates back to upright. Rotation inertia
  shares the pan/zoom decay.
- *Rotation in the architecture.* `Viewport.angle` applies to Double offsets
  from the screen centre, so precision is unaffected; tiles stay axis-aligned
  and the compositor draws rotated quads; `visible()` covers the rotated
  bounding box (`Viewport.coverage`). The angle is stored in the CLI
  (`--rotation`, tile pipeline), bookmarks and share links (2.6) and zoom
  movies (2.8).
- *Gentle bounds.* Zooming out past the whole set springs back to it; panning
  into empty space springs back until part of the set is in view; the precision
  limit bounces. All use `Motion.approach`, the same analytic decay as inertia.
- *Tests.* Rotated conversion round trips shallow and deep, rotated `visible()`
  corner coverage, a 30° product golden against the independent oracle, a
  rotated-compositor check, and a frame-by-frame model check of the twist
  threshold, snap, compass, inertia, springs at two refresh rates and the bounce.
- *Deviation.* The lab renderers (`--pipeline legacy`/`gpu`) sample axis-aligned
  rows and reject `--rotation`; 2.14 removes that path from the viewer anyway.

**2.6 Locations: bookmarks, history, sharing.** ✅ Completed.
- *`Location`.* Centre as arbitrary-precision decimal strings, scale as a
  decimal string, rotation in degrees, iteration limit (nil means automatic),
  palette, density and offset. Codable, so it serves bookmarks, links and
  (later) a movie's keyframes.
- *Links.* `mandelbrot://view?re=…&im=…&zoom=…&rot=…&iter=…&palette=…`, with the
  scheme registered on both platforms, `.onOpenURL` applying it, and `ShareLink`
  in the toolbar and next to every place. The parser also accepts the matching
  universal-link path, so a shared link keeps working if the site serves one,
  and it rejects anything the renderer cannot represent.
- *History.* Back and forward over settled views, recorded when the view comes
  to rest and has moved more than half a zoom level, a quarter of the screen or
  two degrees; jumping to a place always records where it came from. ⌘⇧← / ⌘⇧→.
- *Bookmarks.* Saved as JSON in user defaults, with rename and delete, capped at
  200. ⌘D bookmarks the current view.
- *Gallery.* Nine famous places (whole set, Seahorse and Elephant valleys,
  Triple Spiral, Scepter Valley, a mini Mandelbrot, Feather, the point i, and
  the period-312 minibrot at 1e100), shown in the Places sheet (⌘L) with the
  bookmarks.
- *Tests.* Round trips through links and viewports including a deep rotated view
  and nine rejection cases; every gallery entry parses, is in range and is
  distinct; a headless model check of opening links, history, and bookmark
  persistence, renaming and deletion; the built app's URL scheme is verified.

**2.7 Julia companion.** ✅ Completed. A panel showing the Julia set for the
point under the cursor or finger, updated live: side by side on Mac and iPad, a
corner inset on iPhone (⌘J, or the toolbar button). Tapping the panel swaps it
with the main view (⌘⇧J); while swapped, gestures drive the companion's own
view and the Mandelbrot continues live in the panel.
- *Rendering.* One small GPU render per change, float below 2^18 and
  double-float above, sampled at pixel centres and coloured by the same palette
  kernel as the tiles. The render is skipped when nothing has changed, and its
  resolution is capped at about 2.2 MP so a full-screen swap cannot stall the
  GPU.
- *Deviations.* The companion does not use the tile cache: it is small, always
  redrawn whole, and deliberately shallow (it stops at 2^26, where double-float
  still holds). It shares the palettes, the sample format and the draw pipeline.
- *Tests.* The kernel is checked against the mathematics rather than against
  itself: for c = 0 every point inside the unit circle is captured and every
  point outside escapes; for c = -1 the critical point never escapes. Plus the
  render cache, pointer tracking, and gesture routing while swapped.

**2.8 Zoom movies.** Pick a start location (by default the whole set) and an
end location (the current view or a bookmark). Render the keyframe chain (one
image per zoom level of 2× along the path, straight from the quadtree). Then
compose an exponential zoom video by interpolating between keyframes, and
write it with AVAssetWriter (HEVC/H.264). Options: duration, resolution
(1080p/4K), palette cycling, ease in and out. Render in the background with
progress, and share the result. This is the feature people will post.

**2.9 High-resolution still export.** Tiled supersampled render at any size.
PNG with the location embedded in the metadata. Shares code with the CLI
`--render`.

**2.10 Cheap performance wins.** Skip the main cardioid and the period-2 bulb,
and use periodicity checking for points inside the set. Measure each as a
benchmark variant. Then finish 2.3, which needs interior detection:
- *Raise from data:* raise the limit (to about 2× the current one) while more
  than about 0.1% of pixels are unresolved, i.e. capped but not known interior.
  Keep hysteresis alongside the observed ceiling from 2.3.
- *Deep-zoom hint:* use the reference orbit's period, or its escape iteration,
  as a depth estimate.
- *Resuming capped pixels:* re-measure how much a raise re-samples once interior
  pixels are resolved. Only add bounded state retention if it is still
  significant.

**2.11 Device validation and resilience.** Hands-on testing found problems the
headless tests missed, so real devices get a dedicated pass. The iPhone 11 Pro
is the floor.
- *Profile both phones in Instruments* (Metal System Trace, Allocations):
  frame pacing at 60 Hz and 120 Hz, temperature and throttling over a
  10-minute session, and peak memory. Record the results in `Performance.md`.
- *Memory warnings.* On a system memory warning, shrink the tile cache to the
  protected set (visible tiles and their nearby parents), drop cached reference
  orbits and spare buffers, and allow them to grow back afterwards. Nothing
  handles memory warnings today.
- *Low Power Mode and heat.* When `isLowPowerModeEnabled` is set, or
  `thermalState` is serious or critical, cap presentation at 60 Hz, shrink GPU
  batch budgets and pause prefetching. Restore normal behaviour when conditions
  clear.
- *Headless soak test.* Several minutes of seeded random navigation: pans,
  zooms (including deep round trips), rotations, iteration and palette changes.
  Assert that memory stays within budget, no tile fails, and update, preparation
  and refinement times don't drift compared with a fresh session. It would have
  caught the sticky deep anchor and the cache wipes on iteration changes. Run it
  from `make soak`, outside the default `make test`.

**2.12 Automatic colour.** Palette density is fixed at 64 iterations per cycle,
which suits shallow views. At 1e100, counts in view run from about 22,000 to
34,000. Choose density and offset from the range of escaped counts in view,
using a log mapping or a histogram-based mapping. Deep views then look good
without opening Settings. Use the protected tiles' samples (already on the GPU)
for the statistics, and change the mapping smoothly with hysteresis so colours
don't pulse while moving. The manual density and offset controls become
adjustments on top of the automatic value, like the detail multiplier in 2.3.
A prerequisite for zoom movies (2.8): a movie crosses a huge range of depths,
and a fixed density will look wrong at one end.

**2.13 Deep-zoom performance, round two.** Only if the 2.11 measurements show
cold deep views are too slow on the phones.
- *Boost reference backend.* Boost measured 5.3–5.7× faster per iteration for
  saved reference orbits. Put reference computation behind a protocol, add a
  Boost `cpp_bin_float` implementation through Swift's C++ interop, and keep
  BigInt as the fallback and oracle. It must pass the same hard numerical and
  tile-path goldens, cancellation and cache tests.
- *Better reference choice.* Prefer the pixel with the highest iteration count
  in a first pass, or a nearby minibrot nucleus found with Newton's method,
  over the viewport centre.
- *BLA tuning.* Set ε and the per-jump margin from the isolated BLA-on vs
  BLA-off error measurements, not from comparisons against the oracle.

**2.14 Tidy up before shipping.** Employers will read this repository.
- One pixel-mapping convention everywhere: the full-frame CLI and GPU paths
  still sample at endpoints, while tiles use pixel centres. Re-record the
  affected goldens deliberately.
- Remove the CPU image path from the viewer; the lab renderers stay in the CLI
  and benchmarks.
- Split `Performance.md` into current results plus a history appendix, and fold
  `Implementation.md` into `Architecture.md` and the README.
- Remove dead code and stale comments.

**2.15 Ready for the App Store and for employers.**
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
3. **Smooth motion:** 2.1 (a–d); 2.10 (periodicity checking) → 2.3 → 2.4
   (coverage pyramid).
   The depth-based starting guess from 2.3 can land at any time, even now.
4. **Deep:** 2.2 (library spike first).
5. **Feel:** 2.5 (Mac panning, rotation, gentle bounds). Do it before 2.6, so
   bookmarks store the angle from the start.
6. **Validate:** 2.11 on both phones, then 2.13 only if the measurements call
   for it.
7. **Share:** 2.6 → 2.12 (automatic colour, before movies) → 2.8 → 2.7 → 2.9.
8. **Ship:** 2.14 → 2.15 → App Store.

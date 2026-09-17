# Pro Image Mode — Plan

Pro Image Mode is a small offline rendering pipeline that sits **beside** the
existing Mandelbrot explorer. It is not just a larger set of options, and it is
not an extension of the interactive renderer.

| Mode | Purpose |
|---|---|
| Interactive | Fast navigation and exploration |
| Pro Image | Slow, deliberate, multi-pass, data-rich final rendering |

This is an experiment. It is deliberately disjoint from `plan.md`, and assumes
that roadmap is mostly finished before this starts. See §7 for what it inherits.

---

## 1. Architectural principles

These apply from Milestone 0 onwards. They are the parts that are expensive to
retrofit.

### 1.1 A separate path, deliberately

Pro Image Mode gets its own render path, and shares only what is genuinely
common. Slow is acceptable. Correct and beautiful is not negotiable.

The interactive renderer is full of heuristics that are *right* for holding a
120 Hz frame deadline and *wrong* for a presentation image. We keep them in the
interactive renderer and do not inherit them:

| Interactive heuristic | Why Pro Image Mode does not use it |
|---|---|
| Capped pixels painted `float3(0.005, 0.008, 0.014)` in `colourSamples` | An unresolved pixel is disguised as background. Pro resolves it (period detection, §3 M6) instead of hiding it. This is the motivating example for the whole mode. |
| BLA approximation | An approximation whose error budget was fitted to an interactive image. See §1.8. |
| Bounded glitch retry (16 reference attempts, then a marked failure) | A presentation image must contain zero glitched pixels. Re-reference until clean, however long it takes. |
| `IterationPolicy.estimate` | Explicitly "a first guess". Pro iterates until the image is resolved. |
| The 1,000,000 GPU iteration cap | May genuinely bind near a high-period minibrot. Pro raises or removes it. |
| ~1 ms adaptive iteration batches | Built to protect a frame deadline Pro does not have. Use long batches and fewer submissions. |
| LOD blending, 125 ms fades, coverage pyramid | Irrelevant offline. |
| 8-bit colour mipmaps, box-averaged parents | Replaced by proper resolve filtering (§1.4). |
| LRU eviction | Pro renders a tile once and writes it out; nothing is evicted mid-image. |

**What we do share**, from `Mandelbrot/Core`: `Viewport` and the deep coordinate
types (`DeepPoint`, `WideReal`), `TileGrid`'s bounds and coordinate arithmetic,
`ReferenceOrbit` / `ReferenceOrbitCache`, `BilinearApproximation`, and the
palette definitions (decoded to linear, §1.3). We do **not** share `TileStore`
or `TileCompositor`; their design serves interactivity.

Pro Image Mode is GPU-only. The CPU laboratory renderers stay in the CLI and
benchmarks.

**Open question to settle before Milestone 0:** is this Mac-only? A 4K render
with 4×4 supersampling is unlikely to be sensible on an iPhone 11 Pro, but iPad
may be fine given that slow is acceptable. Decide deliberately rather than
discovering it on device.

### 1.2 Compute once, reshade many

The fractal pass writes a cached set of per-pixel buffers. Shading, lighting,
post-processing and tone mapping all run over those buffers and never re-iterate.

- While editing, the shading passes run in real time over a preview-resolution
  buffer set, on Pro's own preview surface — not through the interactive
  compositor.
- Changing any look parameter triggers a reshade only.
- The fractal pass reruns only when the view, iteration limit or resolution
  changes.

This is what makes the "choose a preset, then tweak a few hero controls"
workflow feel responsive, and that workflow is the core UX bet.

### 1.3 Linear light and HDR from day one

- All buffers and shading are float, in linear light.
- Tone mapping is always the final stage. It may start as a simple clamp or
  exposure curve.
- Export supports 16-bit PNG (and optionally TIFF / EXR) from the start.

Nothing in the current codebase is linear or above 8 bits: sample and colour
targets are `rgba8Unorm`, the compositor is `bgra8Unorm`, palette lookup
textures are `rgba8Unorm` 1024×1, and `GPUContext.image()` hardcodes
`bitsPerComponent: 8, bitsPerPixel: 32`. So this is real work, not a flag. See
Milestone 0 for the three concrete pieces.

**Palettes.** The seven curated palettes are authored as sRGB hex stops,
interpolated in 8-bit, and the `orbit` palette explicitly encodes to display
sRGB as its last step. Pro decodes `Palette.stops` to linear float rather than
authoring a separate set, so a Pro preset still visibly relates to its
interactive palette, and moves the sRGB encode to the tone-map stage. The
interactive path is left exactly as it is.

### 1.4 Shade per sample, then resolve

Angles, normals, masks and distance estimates cannot be averaged across
subsamples before shading. The pipeline therefore:

1. computes buffers at supersampled resolution,
2. shades each sample,
3. resolves (filters/downsamples) the shaded HDR result,
4. runs neighbourhood post effects (bloom, etc.) on the resolved image,
5. tone-maps and exports.

Supersampling is quoted as a linear rate: 2× means 2×2 = 4 samples per pixel,
4× means 4×4 = 16.

### 1.5 Our own tiling

Supersampled buffers are large. At 3840×2160 with 4×4 supersampling and ~10
float32 channels, the full buffer set is roughly 5 GB. But that figure applies
only to the *supersampled per-sample* buffers, which are per-tile and transient.
The resolved HDR image is 66 MB at RGBA16F — trivially resident. So:

- The fractal and shading passes are tiled, with Pro's own tiler, from
  Milestone 0.
- Each tile is shaded and resolved independently, then written into the
  resolved full-resolution image.
- **Neighbourhood passes (bloom, local contrast, glare) run on the resolved
  full-resolution image**, which is small enough to hold whole. We do not use
  tile overlap margins: the interactive tile gutter is one sample, and a bloom
  radius of a few percent of image width is tens to hundreds of pixels. Dropping
  the overlap option removes a whole class of complexity.
- Tile size is ours to choose and need not be 256².
- The preview path uses the same code at preview resolution.

### 1.6 Resolution independence

A look tuned on the preview must match the final render.

- All spatial parameters (glow radius, bloom radius, boundary thickness, DE
  thresholds, normal strength) are specified relative to image width or pixel
  spacing, never in raw pixels.
- Image-dependent statistics (the histogram remap) are computed from a global
  low-resolution pass, not per tile, and stored in the render recipe.

### 1.7 Determinism and recipes

A render recipe fully describes a render:

- view (centre, scale, **rotation**) at full precision
- precision mode and iteration settings, including whether the limit was
  automatic or manual and the detail multiplier — these change the image
- output size, supersampling, jitter seed
- the complete look (all shading/post parameters)
- cached global statistics (histogram CDF)

The same recipe always produces the same image. Recipes extend the `Location`
type from `plan.md` 2.6 rather than defining a parallel format, and are
loadable from the CLI (§3 M0).

### 1.8 Precision modes

Float, FloatFloat and Perturbation rendering already exist, are selected
automatically at 40 coordinate bits per pixel (`PrecisionPolicy`), and work
well. Pro Image Mode requires every new buffer to be produced consistently by
all three paths.

- **Derivative in every path.** Iterate dz/dc alongside z. In perturbation,
  update it using the full orbit value, `dz ← 2(Zₙ + δₙ)·dz + 1`. Note this
  quantity is dδ/dc, which *is* dz/dc for the pixel: the reference orbit Z is
  constant with respect to the pixel's own c, so it contributes nothing to the
  derivative. The derivative does not need extended precision, and because it is
  an absolute quantity it is unaffected by rebasing or glitch correction
  (`perturbTile` rebases with `s.delta = total; s.ref = 0`, which δ absorbs).

- **BLA skips the derivative recurrence — this must be handled explicitly.**
  Production perturbation runs BLA by default, and a single jump skips up to
  16,384 iterations. The per-iteration recurrence above simply never runs for
  those, so a naive implementation yields a wrong DE and wrong normals at every
  deep location — plausible-looking, not obviously broken. Two options, and we
  take both:
  - *Propagate through the jump.* The jump is `δ' = A·δ + B·dc`, so
    differentiating gives `dδ'/dc = A·(dδ/dc) + B`, reusing the same
    `BLAEntry.a` and `.b`. Exact, and costs no new coefficients.
  - *Validate against `--bla off`.* That control already exists on both the
    full-image and tile paths, and gives an exact oracle. Extend the existing
    `measureBLA` diagnostic — which already compares GPU jumps against 180-digit
    Decimal recurrence — to cover the derivative.

  The open risk is that BLA's validity radius was constructed for δ alone
  (`BilinearApproximation.merge` bounds it from `second.radius −
  |first.b|·dc`), so derivative accuracy under a jump is **not** covered by the
  existing error budget. Measure it. If the radius is too loose for dδ/dc,
  tighten the margin for Pro only — we can afford the iterations. If it cannot
  be made tight enough, Pro falls back to `--bla off`, accepting the render time.

- **Derivative in pixel units.** Track `dz/dc × pixel spacing` rather than raw
  dz/dc, which yields DE directly in pixel units — the scale that glow,
  thickness and normal strength need anyway (§1.6). In the Float and FloatFloat
  paths this also avoids float32 overflow at deep zoom; in perturbation it does
  not, because the delta arithmetic there is already extended-exponent
  (`XF` = FloatFloat mantissa with a separate integer exponent), so pixel units
  are adopted there for consistency and resolution independence, not overflow.

- **Cross-mode consistency.** A look must not visibly change when the renderer
  switches mode mid-zoom. A debug check renders the same shallow view in all
  three modes and diffs the smooth-escape, DE and angle buffers.

- **Interior detection per path.** Period detection is straightforward in Float
  and FloatFloat, but it is not free — it is `plan.md` 2.10, still outstanding,
  and needs its own benchmark variant. In perturbation, δ-based comparisons need
  care near the reference orbit, but this is where the speedup matters most,
  since deep interior pixels otherwise burn the full iteration budget.

### 1.9 Validation

Pro Image Mode adds per-pixel work to all three precision kernels, so the
`plan.md` working agreement applies: each milestone lands with tests passing and
`Performance.md` updated with numbers.

What we reuse: `tests/test_product_golden.py` for independent CPU references,
the Decimal oracle at 1e50 / 1e200 / 1e1000, and the `measureBLA` rig. The
cross-mode consistency check in §1.8 becomes its own `make` target alongside
`deep` and `bla`.

---

## 2. Per-pixel data

Most buffers come from a single iteration loop that tracks z and dz/dc together.

### 2.1 Core buffers (from the main loop)

| Buffer | Derivation | Uses |
|---|---|---|
| Smooth escape value | continuous iteration count | smooth colouring, histogram remap, blend weights |
| Interior / exterior / undetermined mask | escape and period detection | separate interior and exterior shading, effect masking |
| Exterior distance estimate | `DE ≈ \|z\|·log\|z\| / \|dz/dc\|` (pixel units) | edge glow, halos, AO-like darkening, "black glass" |
| Normal direction | `u = z / (dz/dc)`, normalised | lighting, specular, rim light, bas-relief |
| arg z, \|z\| at escape | final orbit value | angular colour fields, iridescence |
| arg(dz/dc), \|dz/dc\| | derivative | structure-following colour, highlight shaping |

The analytic normal from `u` is preferred over finite-differencing the DE
buffer, which aliases badly on sub-pixel filaments.

Note that z at escape is **not** stored today: the existing record keeps an
exact `UInt32` count plus a `Float32` smooth correction, and `escapeSample`
clamps that correction (`max(correction, -float(n))`). arg z and |z| are new
state in all three kernels, not a free read. Bailout is already radius 256
(65536), so the escape test itself needs no change.

### 2.2 Derived in the shader (not stored)

- Curvature / edge-strength estimates, from neighbouring normals or DE.
- Pseudo-height, from a mapping of DE or smooth escape.

### 2.3 Invalid and unresolved samples

The interactive path uses reserved counts for capped, unfinished and glitched
samples. Every new buffer needs the same discipline, decided once rather than
per effect:

- **Glitched:** must not exist in a finished Pro image. Re-reference until clean
  (§1.1); a glitched pixel that survives to shading is a bug, not a colour.
- **Capped / undetermined:** has no meaningful DE or normal. Carry the mask
  through shading, and exclude these samples from every neighbourhood pass so
  they cannot bleed into bloom or local contrast.
- **Interior:** DE and normal come from the interior estimators (M6), not the
  exterior ones.

### 2.4 Later buffers

| Buffer | Milestone | Uses |
|---|---|---|
| Attracting cycle period | 6 | interior colouring, faster interior bailout |
| Interior distance estimate | 6 | real interior geometry for shading |
| Orbit trap statistics (min distance, trap ID) | 7 | material masks, emissive accents |
| Sample variance | 8 | adaptive supersampling, quality view |

---

## 3. Milestones

Ordered to answer the experiment's real question early: **are these images
worth the pipeline?**

### Spike — is the look worth it?

**Goal:** a compelling image, as cheaply as possible, before committing to any
architecture.

dz/dc in the **Float path only**, at shallow zoom, single tile, no supersampling,
8-bit output: DE edge glow, analytic normals, one directional light.

No tiling, no HDR export, no recipes, no perturbation, no preview UI. A few
hundred lines. If the bas-relief / black-glass look is not compelling here, it
will not be compelling after Milestones 0–4 either.

Keep the shading maths float and linear from the start, so only the output stage
is thrown away.

**Decision point:** proceed to Milestone 0, or stop.

### Milestone 0 — Pipeline skeleton

**Goal:** the complete pipeline shape, with minimal shading.

Renderer:
- Pro Image Mode switch, separate from interactive rendering
- Pro's own tiler; tiled, supersampled float render targets
- shade-per-sample, then resolve
- buffer cache with reshade-only updates
- linear-light pipeline with a trivial tone mapper
- smooth escape value and interior/exterior/undetermined mask
- render recipes: save, load, deterministic seed
- debug-view framework

16-bit export, as three concrete pieces:
- a float/half render target format for the resolved image (`rgba16Float`)
- a readback path that handles it — `GPUContext.readback()` currently derives
  stride from `pixelFormat == .rg32Uint ? 8 : 4`, which must become a real
  format table
- 16-bit `CGImage` construction and PNG encoding, separate from
  `GPUContext.image()`'s hardcoded 8-bit path

CLI: `--recipe PATH` renders a recipe headlessly. This is the primary interface
for a slow offline renderer, not an afterthought — it is also how evidence gets
captured and how the image tests run.

Unlocks: clean, high-quality smooth-coloured 4K stills.

UI: Export panel (size preset — 1920×1080, 2560×1440, 3840×2160, custom;
supersampling 1×/2×/4×; max iterations; render button; progress, cancel and time
estimate) and a basic Colour panel (palette picker).

### Milestone 1 — Full iteration data and global colour mapping

**Goal:** all core buffers from one loop, in all three precision modes, plus
better palette use.

Renderer:
- dz/dc in pixel units in Float, FloatFloat and Perturbation
- **derivative propagation through BLA jumps, with `--bla off` as the oracle
  and `measureBLA` extended to cover it** (§1.8) — this is the milestone's main
  technical risk, and is done before anything depends on DE
- DE, normal direction, arg z, |z|, arg(dz/dc), |dz/dc| buffers
- cross-mode consistency check, as a `make` target
- histogram CDF from a global low-resolution pass, stored in the recipe

Unlocks: premium-looking classic renders with far less crushed detail.

UI (Colour): palette type (gradient / cyclic / monochrome), histogram remap
(off / mild / full), palette scale and offset, contrast, saturation.

Debug: smooth escape, histogram curve, raw DE, log DE, normals, angle and
derivative fields, cross-mode diff, BLA-on vs BLA-off derivative diff.

### Milestone 2 — Distance effects and lighting

**Goal:** treat the boundary as a shape.

Renderer:
- DE-based edge glow, falloff and boundary lines
- brightness source blend (smooth escape / DE)
- pseudo-height from DE
- lighting from analytic normals: one directional light, ambient + Lambert +
  specular + rim

Unlocks: black-background drama, bas-relief, metallic highlights, rim-lit
filaments. This is the milestone that most differentiates the images from
ordinary Mandelbrot renders.

UI (Light): light direction gizmo (draggable circle), elevation, ambient,
diffuse, specular, gloss, rim intensity and width, relief strength, edge glow,
glow radius, boundary thickness.

Debug: boundary mask, lit greyscale, specular only.

### Milestone 3 — Bloom and tone mapping

**Goal:** bright structures that feel optical rather than painted on.

Renderer:
- multi-scale bloom on the resolved HDR image
- tone mappers: linear, filmic, ACES-like
- vignette, optional very subtle grain

Unlocks: white-hot filaments, cinematic glow, vivid highlights on dark
wallpapers.

UI (Effects): bloom threshold, intensity and radius; exposure; black and white
point; shoulder; tone mapper choice; vignette; grain.

Debug: pre-tonemap HDR, bloom contribution only, clipped highlights.

### Milestone 4 — Looks and hero controls

**Goal:** a usable artistic workflow, introduced early and refined later.

Renderer: formalise the pass graph (base, light, emissive, bloom, composite) and
bundle all parameters into Look presets.

UI (Look):
- preset gallery with thumbnails
- save, duplicate, favourite, A/B compare
- five surfaced hero controls per preset: **Exposure, Glow, Relief, Colour
  shift, Darkness**, mapped onto the deeper parameters

Initial presets: Black Glass, Incandescent, Bas Relief, Deep Ocean.

### Milestone 5 — Angular and derivative colour

**Goal:** colour that follows the geometry rather than escape time.

Renderer: modular colour synthesis from the existing buffers.

UI (Colour, advanced):
- hue source: smooth escape / arg z / arg(dz/dc) / hybrid
- brightness source: DE / smooth escape / lighting / hybrid
- saturation source: curvature / |dz/dc| / fixed / hybrid
- hue rotation, cyclic frequency, phase shift, saturation clamp
- small preview strip or wheel showing the active hue mapping

Presets: Iridescent Titanium, Beetle Shell, Polarised Glass, Aurora Metal.

### Milestone 6 — Interior

**Goal:** a deliberately beautiful interior, grounded in real geometry.

Renderer:
- period detection in all three precision modes (also speeds up interior
  bailout, and retires the capped-pixel fudge from §1.1)
- interior distance estimate
- interior material shading using interior DE and normals
- optional colouring by period

Unlocks: polished stone interiors, per-component materials, subtle hidden
structure.

UI (Interior, within Colour or Light): black / shaded / coloured, brightness,
roughness, specular, tint, glow, colour by period, period contrast.

Presets: Black Lacquer, Polished Onyx, Dark Ceramic, Hidden Period Glow.

Debug: period field, interior DE.

Period detection can be pulled earlier if interior render times become a
problem. If `plan.md` 2.10 has landed, much of this is already done (§7).

### Milestone 7 — Orbit-trap modulators (optional)

**Goal:** tasteful material variation, used as masks and modulators rather than
the main feature.

Renderer: one or two traps (point, line/axis).

UI: trap type, position/orientation (overlaid on the preview while editing),
influence, and target (hue / roughness / emissive / glow mask).

Presets: Mineral Veins, Gold Filaments, Copper Oxide, Frozen Crystal.

Debug: trap distance field, trap influence mask.

### Milestone 8 — Optics and adaptive quality (optional)

**Goal:** a premium photographic finish.

Renderer: stochastic and variance-driven adaptive supersampling, chromatic
aberration, glare on hot highlights, pseudo depth of field from height, local
tone mapping, microcontrast.

UI: hidden behind an Advanced disclosure, with a subtle / moderate / strong
limiter or a warning when the result becomes gaudy.

Debug: variance and sample-count view.

---

## 4. Control panel

Kept deliberately small for v1:

| Panel | Contents |
|---|---|
| **Look** | preset gallery, hero controls, save / compare |
| **Light** | direction gizmo, lighting terms, relief, edge glow |
| **Colour** | palette, histogram remap, sources (advanced), interior |
| **Effects** | bloom, tone mapping, vignette, optics (advanced) |
| **Export** | size, supersampling, iterations, precision info, render, progress, cancel |
| **Debug** | toggle; buffer and pass views, cross-mode diff |

Composition aids (aspect ratio, crop, desktop icon / menu bar safe-area overlay,
framing guides) sit as an overlay toggle on the preview.

Intended workflow:

1. Choose a look preset.
2. Adjust the five hero controls.
3. Optionally open advanced controls.
4. Export.

A long render needs progress and cancellation that do not fight the interactive
renderer's worker. Pro owns its own worker and its own generation/cancellation.

---

## 5. What each milestone unlocks

| Milestone | New data / capability | New style unlocked |
|---|---|---|
| Spike | DE and normals, Float only | proof the look is worth building |
| 0 | tiled float pipeline, 16-bit export, recipes | clean 4K stills |
| 1 | derivative buffers (incl. through BLA), histogram remap | better classic colouring |
| 2 | DE effects, analytic normals, lighting | edge glow, bas-relief, metallic |
| 3 | bloom, tone mapping | white-hot highlights, real glow |
| 4 | pass graph, presets | practical artistic workflow |
| 5 | angular / derivative colour | iridescent, geometry-following colour |
| 6 | period, interior DE | structured interiors |
| 7 | orbit traps | mineral / material variation |
| 8 | variance, optics | photographic finish |

---

## 6. First shippable target: Pro Image Mode v1

Spike, then Milestones 0–4:

- tiled, supersampled, linear-light float pipeline with cached reshading
- 4K, 16-bit export and deterministic recipes, drivable from the CLI
- smooth escape, DE and analytic normals in all three precision modes, correct
  through BLA jumps
- DE edge glow and one directional light
- bloom and filmic tone mapping
- four presets with hero controls: Black Glass, Incandescent, Bas Relief,
  Deep Ocean

If time is tight, histogram remap can slip. DE and lighting carry most of the
visual impact.

---

## 7. What `plan.md` will already have given us

This plan assumes the roadmap is mostly finished first, so several milestones
start further along than they look:

- **2.10 (periodicity checking)** is the same mathematics as Milestone 6's
  period detection, and `plan.md` 2.3 is already blocked on it. If 2.10 has
  landed, Milestone 6 gets substantially cheaper.
- **2.12 (automatic colour)** builds histogram and in-view statistics machinery
  that Milestone 1's remap can borrow.
- **2.5 (navigation feel)** adds `Viewport.angle`, which is what makes the
  rotation field in §1.7's recipe meaningful. `Viewport` has no angle today.
- **2.6 (locations)** defines the `Location` type that recipes extend.
- **2.14 (tidy-up)** removes the CPU path from the viewer and settles the
  pixel-mapping convention, both of which simplify a new render path.

**One decision to make consciously: `plan.md` 2.9, high-resolution still
export.** Milestone 0 supersedes it. Either build 2.9 as the quick everyday
export and let Pro Image Mode be the deliberate one, or skip 2.9 when the time
comes and let Pro cover both cases. Choose, rather than building it twice.

`vision.md` currently lists a palette editor as a non-goal, on the grounds that
a curated set is enough. Pro Image Mode does not change that for the interactive
app, but when this lands that line wants a one-sentence amendment so the repo
does not contradict itself.

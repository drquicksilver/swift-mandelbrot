# Vision

## One line

**A Mandelbrot explorer for iPhone, iPad and Mac. Moving around is always
silky smooth, you can zoom as deep as you like, and it looks beautiful. It is
good enough to give to friends, publish on the App Store and show to an
employer.**

## Audience

- **Friends and family:** people who aren't programmers. They should be able
  to pick up a phone, pinch, and be amazed. No settings needed.
- **App Store users:** the same people, at a larger scale. This needs App Store
  polish: onboarding, an icon, privacy details, and no crashes.
- **Future employers:** people reading the code. The repository is part of the
  product. Clean architecture, a clear README, documented performance work,
  real tests. It should show both craft (the GPU work and the precision maths)
  and judgement (what was measured and why decisions were made).

## Where we are

The project began as a performance lab: one algorithm, nine implementations,
benchmarked side by side (see `Performance.md`). The lab taught us:
single-threaded tweaks are worth ±5%, threads about 7×, and Metal is in a
different league. It grew into a usable SwiftUI viewer, which is now the
product. The lab stays, but its job is to measure the product.

## What "good" looks like, in priority order

1. **Silky motion.** Pan and zoom run at the display's refresh rate
   (120 Hz on ProMotion) on iPhone, iPad and Mac. The screen always shows
   something reasonable, never a blank frame. Detail is allowed to arrive a
   moment later, fading in rather than popping. The building block for this is
   a **quadtree tile cache** (see `plan.md`, "Architecture").
2. **Deep.** Zoom to 10¹⁰⁰× and far beyond. Precision steps up automatically:
   float → double-float on the GPU → perturbation theory, using a
   high-precision reference orbit from a borrowed arbitrary-precision library.
   The user never picks a renderer.
3. **Beautiful.** Smooth, band-free colouring and a curated set of good
   palettes. Screenshots should be wallpaper-worthy by default. (Palette
   editing can come later.)
4. **Shareable.** Bookmarks, history, share a location as a link, export
   high-resolution images, and **zoom movies**: exponential zooms into a
   location, which people will actually post and send to each other.
5. **Playful depth.** A **Julia companion** view that shows the Julia set for
   the point under your finger or cursor. It makes the connection between the
   two sets something you can touch.
6. **Honest about performance.** The benchmark is still in the app, hidden
   behind a developer panel so it can be run on friends' devices. The CLI and
   golden-image tests keep every renderer honest.

## Principles

- **The GPU does the heavy work, all the way to the screen.** Computation,
  colouring and compositing happen on the GPU. The CPU coordinates, and
  computes the high-precision reference orbits.
- **Compute once, display many ways.** Tiles store smooth iteration data, not
  colours. Changing palettes is free, and cached tiles never go stale because
  of how they are displayed.
- **Precision is automatic.** Renderer selection is a developer-panel tool.
- **Measure, then change.** Each renderer change comes with a benchmark number
  and a golden-image check.
- **iOS is a first-class target.** Touch-first interaction design. The Mac gets
  keyboard, mouse and menu extras on top of that.
- **Native, small and licence-clean.** Swift, SwiftUI and Metal. Borrowed
  dependencies must be compatible with App Store distribution: prefer
  MIT, BSD, Apache or Boost licences over LGPL/GPL.

## Non-goals (for now)

- Vision Pro. We can't test it, so drop it from supported platforms until we
  can.
- A palette editor (a curated set is enough for now).
- Other fractal families as a main focus.
- CI. Tests run locally (`make test`).
- Web or cross-platform versions, and cloud rendering.

# 2.12 — the UX and UI pass

Two independent audits were run against commit `a463931` on 22 September 2026,
one by Claude and one by Codex, and both are in `reviews/`:

- `reviews/claude-ui-ux/ui-ux-audit.html` — 21 areas, 45 screenshots, 56
  actionable issues, with a screen-by-screen walk and a design-system section.
- `reviews/codex-ui-ux/ui-ux-audit.html` — 20 issues, shorter, organised by
  screen and workflow.

They were written without sight of each other and reach substantially the same
diagnosis, so where both raise something it is taken here as settled. Open
either where a line below needs more context; this file does not reproduce
them.

Their shared conclusion: the parts that touch the fractal — the canvas, the
gestures, the palettes, the Julia companion, the Mac movie sheet — are good.
Almost everything around them is one generic `NavigationStack { Form }` shipped
unchanged to both platforms, and on the Mac that shared chrome is visibly
broken.

This file splits the findings in two. The stages below are the work that needs
no design decisions — shared primitives, correctness, language, accessibility
and polish. The screens that do need designing first are listed at the end;
they are a separate task and are not sequenced here.

## Stage 1 — shared primitives

No user-visible change, and everything later gets cheaper. Both audits put this
first.

1. **One scale formatter.** `MovieSheetMac.zoom(_:)` is already the right
   function: plain grouped digits below about 10¹⁰, a clean exponent above.
   Move it to the model and route every user-facing scale through it. The same
   quantity is currently printed six ways across `PlacesView`, `MovieView`,
   `MovieSheetMac`, `SettingsView`, `BenchmarkView` and `ExplorerModel`,
   including `2.0000000000000004e9×`. Show a raw decimal only where precision
   matters, in a copyable coordinate field. Test it in `tests/core`.
2. **`ValueSlider` and `ValueStepper`.** Three sliders built three ways, and
   three stepper treatments for one quantity. One pair showing title, live
   value and bounds, used everywhere. This is Apple convention, not new design.
3. **The glossary.** Agree one word per concept — Place, Detail, Palette,
   Colour spacing, Colour shift, Journey, Render — and record it. Applying it
   is stage 3, in one sweep.

The shared *panel* scaffold belongs with the design work, not here; see below.

## Stage 2 — correctness and state

Self-contained, and each one is a thing that is wrong rather than merely plain.

4. Validate the menu commands against the focused model. Back, Forward, Upright
   and Swap are always enabled in `ExplorerCommands`.
5. Initialise the Mac movie sheet's **From** popup so it is never blank.
6. Disable the iPhone movie settings while a render is running.
7. Fix the bookmark naming field: commit on `Return`, and chase the swallowed
   first click on **Bookmark**.
8. Recalibrate or delete the movie file-size estimate. 119.4 MB predicted
   against 10.8 MB actually written is a formula fault, not rounding.
9. Seed the iPhone Julia marker at the view centre when the companion opens, so
   crosshair and companion always agree, and preserve it across rotation.
10. Investigate whether a double-click zoom can fire from two distant clicks.
    Unconfirmed in the audit.

## Stage 3 — language

11. Apply the stage 1 glossary to every user-facing string. Fix “Route: 1
    segments” and “Zoom from X into *the starting view*”, give bookmarks a
    better default name than “1.0× view”, title the untitled Controls section,
    name movie timeline segments by their endpoints, and retire the leaked
    jargon: Keyframes, Perturbation, FloatFloat, “Invalid decimal coordinate”,
    “Pin *c* where it is”.
12. Replace internal error strings with human sentences.
13. Platform-condition the copy. “Pointer” and “click” currently appear on the
    phone.
14. Move the strings into a catalogue while every one of them is already being
    touched, and strip the hard wraps from the licence text.

## Stage 4 — accessibility and Dynamic Type

After stage 3, because labels come from strings; before the polish, because it
changes frames.

15. **The second P0.** At AX5 the iPhone control capsule's glyphs overlap and
    spill outside it, the companion's buttons do the same, and the companion
    caption covers the whole Julia image. Cap the icon scaling and let frames
    grow with their content.
16. Label the companion panel's children individually. They currently inherit
    one container label.
17. Raise the two sub-44 pt targets: the companion buttons and the Places
    **Bookmark** button.
18. Make the canvas an accessible element on both platforms, with a live
    scale and coordinate value and an adjustable zoom action, so it can be
    explored without a gesture. No visual change; needs the stage 1 formatter.
19. Honour Reduce Motion for flings, refinement fades and the rotation spring.

## Stage 5 — Mac platform idiom

Only the parts that are not bound to the panel redesign.

20. Add **Settings…** and ⌘, to the app menu.
21. Give Places and the filled-bookmark toolbar item distinct glyphs — an
    outline and a filled bookmark side by side read as one toggle and are two
    commands — and reserve space for the conditional Back, Forward and Upright
    items so the cluster stops reflowing.
22. Group the Explore menu with separators, give Reset View a shortcut, and
    review the unmodified arrow-key bindings against text entry.
23. Put the current scale in `.navigationSubtitle`. The Mac half of “the app
    never tells you where you are” is nearly free once the formatter exists;
    the iPhone half needs design.
24. Make the Mac Julia split draggable.
25. Zoom out by gesture on macOS, and change the cursor to surface shift-drag
    framing.

## Stage 6 — polish

26. Give the crosshair a dark outline so it survives bright regions, and the
    iPhone capsule a minimum contrast floor.
27. Draw the palette preview as a real gradient instead of 64 blocks.
28. Fix the misaligned separator under the Places naming row.
29. Collapse the movie preview slot during and after a render rather than
    leaving an empty box with a stale caption, and scroll to the completion
    card.
30. Separate famous places from your bookmarks in the movie **From** menu.
31. Let Acknowledgements keep a dismissal control; give About an icon and
    links.
32. Restore the last location on launch, and animate a jump to a place as a
    short continuous zoom, honouring Reduce Motion. Both audits ask for the
    transition: a hard cut wastes the app's spatial premise.
33. Add a benchmarks empty state, and a retry and time-remaining estimate on
    movie render failure.
34. Make the developer panel a real window on macOS.

## What needs designing first

These are the larger items. They are noted here, as 2.12 asks, and are a
separate task.

1. **The macOS panel scaffold.** The P0, and the single systemic cause. Five
   screens — Settings, Places, Controls, Developer, Benchmarks — are one
   `NavigationStack { Form }` with a hard-coded frame. On the Mac that clips
   content through the middle of rows, cannot be resized, puts **Done** at the
   bottom *leading* edge, offers no Cancel and no default button, ignores
   `Escape`, and renders section headers as unstyled body text. Both audits
   name the same fix: extract the shape `MovieSheetMac` already uses. But what
   that shape *is* — heading, cards, label gutter, footer grammar,
   phase-dependent footers — is the design decision. Settings additionally
   becoming a real `Settings` scene belongs here. A handful of stage 5 and 6
   items were deliberately left out above because they only make sense inside
   this work: `Escape` dismissal, Cancel and default buttons, sheet sizing, and
   `Section` header styling. Fold them in rather than doing them twice.
2. **Settings, rebuilt on the scaffold.** Including replacing the Depth/Pinned
   segmented control, which cannot be operated in both directions and is
   unnamed on iPhone, and explaining Detail, colour spacing and *c* in
   audience-facing terms.
3. **Places as a library.** Thumbnails from the existing `LocationThumbnail`,
   an empty state, rename, reorder, a Mac context menu — which also gives the
   Mac a discoverable delete — and a stable notion of the current place.
4. **The iPhone movie sheet.** Both audits are blunt that it is a different and
   weaker product, not a platform adaptation: no endpoint thumbnails, no
   preview, a direct-descent-only route model, no minimum-duration guard, no
   completion state. Sharing `Journey`, the preview, the thumbnails, the
   statistics, the duration guard and `MovieOutcome` is engineering; laying the
   result out on a phone is design.
5. **Still export and the share payload.** The largest genuinely missing
   capability: `Export Image…` (⇧⌘E) on the Mac, a share action on the phone,
   and a `Transferable` carrying a rendered still and an `https` universal link
   with a `SharePreview`, in place of a bare `mandelbrot://` URL that nobody
   without the app can open. The render itself is 2.13; what 2.12 owes it is
   the surface and the share model.
6. **The iPhone control cluster.** Moving it into the thumb arc and adding
   Bookmark and Share means re-deciding what earns a slot.
7. **Save acknowledgement and notices.** “Saved to Places” with Undo and a
   name, and one dismissible-notice treatment to replace error text that is
   dismissed by tapping it. Small in code, but a new element to specify once
   and reuse.
8. **A first-run pass**, built from the existing `HelpContent` so a gesture
   cannot be hinted without already being explained.
9. **The app icon.** A readable mark in one of the app's own palettes, with
   dark and tinted variants.

## Status, 23 September 2026

Stages 1–6 are done, one commit per stage (`405f03b`…`d8596f6`); the design
list above is untouched. Where the work departed from the list:

- **⌘? is the system's.** macOS gives Command-? to the Help menu's search, and
  a menu drops a `?` key equivalent, so Controls sits in the Help menu unbound
  and `?` is a canvas key, as the arrows now are (item 22).
- **Menu commands are disabled behind a sheet** as well as when they cannot
  act (item 4): the menu bar stays live over a sheet, and ⌘J reached the view
  behind the movie sheet.
- **Some items landed a stage early** because the code was open: Settings…
  (20) with stage 1, so Settings could be reached for testing; option-double-
  click (25) with the double-click fix (10); the better bookmark name (11) with
  the naming field (7).
- **Double-click (10)** was confirmed as a risk rather than reproduced: two
  quick clicks 600 pt apart do not zoom, and the handler now demands both
  presses be clicks within 5 pt, which AppKit's `clickCount` does not.
- **The swallowed click (7)** reproduced: a default-styled button in a Mac list
  row lost its first click to the row. A bordered one does not.
- **Strings (14):** `xcodebuild` never writes a catalogue back, so
  `make strings` does, from the Release builds' extracted strings.
- **Last location (32)** is stored in user defaults, not scene storage, so it
  survives a Mac quit; only a window writes it.
- **Deferred as design, noticed on the way:** Escape still does not close the
  sheets; the Julia caption keeps four decimals however deep the view; a link
  with no colour parameter still opens pinned; the preview video still eats
  scroll events in the Mac movie sheet.

Test failures that predate 2.12 (identical on `a463931`): `make tiles`
(“Palette completion did not wake presentation”), `make product` (pixel
mismatch) and `make deep`'s minibrot check (`AssertionError: 189`). The core
test that also failed there, the auto-contrast fit, was stale after 2.11 and
is corrected in `ce720d2`.

## Review follow-up, 23 September 2026

`reviews/2026-09-23-2.12-ux-pass.md` found six things; all are addressed.

1. **The iPad lost its bare keys** (stage 5). Keys now route per platform:
   the Mac canvas hears the bare keys, and an iPad binds them in the menu, its
   only route. A unit test checks every key Help lists has a live route, and a
   UI test drives an iPad simulator's keyboard; both fail on stage 5's routing.
   The UI test also confirmed that iPadOS gives a text field its arrows first.
2. **The menu bar ran on every frame.** Measured at about 70 evaluations a
   second during a drag; with an `Equatable` `MenuState` it ran 3 times.
3. **Errors were sorted by their text.** Movie failures are typed, their
   causes are logged, and only `UserError` text is ever shown.
4. **Place travel ran on its own timer.** It is stepped by the motion clock.
5. **The catalogue churned between Xcode and `make strings`.** The tool is
   Swift now and writes exactly what Xcode writes, checked against Xcode's
   own rewrite.
6. **The smaller items**, including the review's list of tests.

`make apptests` runs the app's tests on the Mac and an iPad simulator.

## Places on the Mac, 23 September 2026

Design item 3 is built for the Mac from Jules's drawing, as
`PlacesSheetMac`: this view ready to bookmark, then bookmarks and famous
places as grids of rendered thumbnails, with search, a “Current” mark, a
per-card menu (open, rename, share, move, delete), drag reordering and an
empty state. The iPhone keeps `PlacesView` until it has a design of its own.
Its previews show real thumbnails from `Preview Content`, drawn beforehand
with `--render --pipeline tiles`, because a preview snapshot does not wait
for the GPU. Drawn that way, Mini Mandelbrot comes out flat gold and Feather
flat black; whether the gallery entries miss is not yet checked.

The three inherited failures are fixed in `7beff93`: two were tests still
written for colour before 2.11, and three were real 2.11 regressions in the
compositor's colouring, recorded in Performance.md. `make test` passes.

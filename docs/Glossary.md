# Glossary

One word per concept in everything a person reads: menus, sheets, help,
tooltips, accessibility labels and error messages. The code keeps its own names
(`Location`, `density`, `iterations`, `ZoomPath`); this is only what the app
*says*. Agreed for 2.12 from the two audits in `reviews/`.

| Concept | Say | Don't say |
| --- | --- | --- |
| Where you are now | **this view** | location, current location, the starting view |
| A named point in the set, built in or saved | **place** | location, view (for a saved one) |
| Saving this view as a place | **bookmark** (verb); your saved places are **bookmarks** | save location, add place |
| The built-in places | **famous places** | gallery, presets |
| How far in you are | **zoom**, written by `ZoomFormat`: `4,000×`, `3.4e27×` | scale, magnification, raw decimals |
| The iteration limit | **detail**; its number may be counted in *iterations* | iteration limit, max iterations, depth |
| The colour scheme | **palette** | colour map, gradient, colouring |
| `densityAdjustment` | **colour spacing** | exterior contrast, density, contrast |
| `offsetAdjustment` | **colour shift** | palette phase, phase adjustment, offset |
| Deterministic colour | **match colour to zoom** | depth colouring, automatic colour |
| Colour held fixed | **keep these colours** | pinned |
| One-shot auto-contrast | **tune colours to this view** | auto-contrast |
| The second panel | **Julia companion**, or **the companion** | Julia view, Julia panel |
| The point the companion draws | **the crosshair** | *c*, the parameter, the pin |
| The camera path of a movie | **journey**; its parts are named by their ends, “Seahorse Valley to this view” | route, path, keyframes, segments |
| Making a movie or a still | **render** | export, create, generate |
| A zoom movie | **movie** | video, animation, clip |
| A problem drawing the view | **couldn’t draw** | tile failed, render error |

Words that belong only in the developer panel and the benchmark report:
perturbation, FloatFloat, Double, BLA, reference orbit, tile, level, kernel.

Platform words: **click** and **pointer** on the Mac, **tap** and **finger** on
iPhone and iPad. Copy that names an input is written as a whole sentence per
platform under `#if os(macOS)`, as `HelpContent` does, never spliced together
from a platform word, so each sentence can be translated whole.

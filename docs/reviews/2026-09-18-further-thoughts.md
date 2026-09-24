Mostly, but the navigation features aren’t fully correct yet. I reviewed the September 17 evening commits, `e5bc76e` through `8d66666`, using an isolated committed snapshot. Your uncommitted work was untouched.

I found five actionable issues:

1. **[P1] Deep rotated zoom loses its cursor anchor.**  
   The deep zoom calculation still subtracts an unrotated offset. At `1e40`, with 45° rotation, my 2× zoom probe displaced the anchored point by **257 screen points**. Even a factor of 1 can move it. Use `planeOffset` when rebuilding the deep centre. [Viewport.swift:157](/Users/jules/personal/progs/Mandelbrot/Mandelbrot/Core/Viewport.swift:157)

2. **[P2] Back history misses ordinary navigation.**  
   `apply()` saves the last recorded viewport rather than the current one, and keyboard navigation doesn’t record settled views. Reproduced: zoom to **32×**, visit a gallery location, press Back → returns to **1×**. Opening the first gallery location also leaves Back unavailable because history starts uninitialised. Initialise history and save the actual departing location, including its settings. [ExplorerModel.swift:207](/Users/jules/personal/progs/Mandelbrot/Mandelbrot/ExplorerModel.swift:207)

3. **[P2] Rotation affects the wrong view after swapping Julia.**  
   Pan and zoom route to `juliaViewport`, but rotation always changes the Mandelbrot viewport. My probe confirmed that rotating the main Julia view changes only the Mandelbrot companion. Route rotation consistently; Julia’s renderer would also need to honour its viewport angle. [ExplorerModel.swift:266](/Users/jules/personal/progs/Mandelbrot/Mandelbrot/ExplorerModel.swift:266)

4. **[P2] iOS rotation inertia bypasses the twist threshold.**  
   Touch handling derives rotation velocity from raw finger movement, then applies it after `endTwist()`. Thus a twist deliberately ignored during a pinch can rotate the view upon release. Replaying that sequence with a 5° twist produced an **8.1° final tilt**. Only fling rotation that passed the threshold, and preserve snapping’s suppression of rotation velocity. [PlatformInput.swift:243](/Users/jules/personal/progs/Mandelbrot/Mandelbrot/PlatformInput.swift:243)

5. **[P2] Finished tile fades retain unaccounted textures.**  
   `baseTransitions` keeps a strong reference to the previous tile after its fade completes. When refinement replaces a tile, its old textures can remain alive indefinitely while the view stays still, although `residentBytes` no longer counts them. Release previous records after fading and account for transition-held textures in the budget. This finding is from code inspection. [TileStore.swift:734](/Users/jules/personal/progs/Mandelbrot/Mandelbrot/TileStore.swift:734)

Validation passed: **macOS Release build, all 32 core tests, the tile integration suite, and all five independent image regression cases**. The rendering and coverage changes therefore have good supporting evidence.

The main testing improvement is to exercise complete input sequences. Existing tests cover deep rotation without deep zooming, Julia pan/zoom without rotation, and model snapping without the subsequent touch-release fling. The iOS finding was reproduced through the model sequence, not on a physical device.

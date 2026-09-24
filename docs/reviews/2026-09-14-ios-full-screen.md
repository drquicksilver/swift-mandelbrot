# iOS full-screen viewer: fixing the safe-area strip

- **Date:** 2026-09-14
- **Status:** recommendations only. No code has been changed.
- **Applies to:** `Mandelbrot/ContentView.swift`, iOS only.

## Problem

On iPhone, the fractal doesn't fill the screen:
- **Portrait:** there's a black strip along the bottom.
- **Landscape:** the strip is glaring, and the set sits visibly off-centre.

## Cause

This is the **safe area**, not the home indicator itself. The original `ContentView` had `.ignoresSafeArea()`, but the 1.6 refactor dropped it. So SwiftUI lays the viewer out inside the safe rectangle:
- **Portrait:** the viewer stops above the home indicator.
- **Landscape:** it also stops short of the Dynamic Island side and the rounded corners.

`.background(.black)` does extend into those insets, which is why they show as black bars. `Viewport` centres the set in the safe rectangle, which in landscape is shifted up by the height of the bottom inset. That's the off-centre look.

## Fix

The rule is: **the fractal goes edge to edge, and the controls stay inside the safe area.**

### 1. Split the viewer from the overlays
At the moment one `GeometryReader` wraps both the viewer and the overlays (HUD, notices, buttons). Restructure so only the viewer sits in a `GeometryReader` that ignores the safe area:

```swift
var body: some View {
  ZStack(alignment: .bottomTrailing) {
    // The fractal: edge to edge.
    GeometryReader { geometry in
      ViewerView(model: model)
        .onAppear { model.resize(geometry.size, displayScale: displayScale) }
        .onChange(of: geometry.size) { _, size in model.resize(size, displayScale: displayScale) }
        .onChange(of: displayScale) { _, scale in model.resize(geometry.size, displayScale: scale) }
    }
    #if os(iOS)
    .ignoresSafeArea()
    .statusBarHidden()
    #endif

    // Everything else stays inside the safe area, as now.
    TileFailureNotice(store: model.tiles)
    if model.showHUD { TileHUD(...) }
    if model.atPrecisionLimit { ... }
    if let error = model.error { ... }
  }
  #if os(iOS)
  .overlay(alignment: .topTrailing) { /* the three buttons, unchanged */ }
  #endif
  // scenePhase, background, macOS toolbar, sheets, focusedSceneValue: unchanged
}
```

### 2. Put `.ignoresSafeArea()` on the `GeometryReader` itself
Not inside it. Only then does `geometry.size` report the full screen.

### 3. Move the three `resize` handlers with it
This is the step that's easy to get wrong. `model.size` drives all the maths that converts between screen points and complex coordinates: pan, pinch anchors, rectangle zoom, and which tiles are visible. If the canvas is full screen but `resize` still gets the safe-area size, the image will look right while gestures drift. For example, the point under your fingers would slide during a pinch near the bottom edge.

### 4. Hide the status bar (decided)
Add `.statusBarHidden()`, as in the sketch above. With the status bar gone, the top safe-area inset in portrait gets smaller. Because the buttons are in the safe-area layer, they move up to match, so check they still clear the Dynamic Island.

### 5. Keep the change iOS-only
On the Mac, ignoring the safe area would slide the fractal under the toolbar and shift its centre down. The Mac looks right today; leave it alone.

### 6. Leave everything else
`ViewerView`, `GPUCanvas` and `PlatformInput` take their size from their parent and need no changes.

## Optional polish (not yet decided)

Add these iOS-only modifiers to the same `GeometryReader`:
- **`.persistentSystemOverlays(.hidden)`** fades the home indicator out after a few seconds without touches. This is the Photos-style immersive look.
- **`.defersSystemGestures(on: .bottom)`** means a pan that starts at the bottom edge needs a second swipe before it goes home, now that the fractal extends under that edge.

It's unconfirmed whether deferring also stops the "double-tap the bottom edge for Siri" gesture from taking double-tap-to-zoom. Test it on a device. If Siri still wins, ignore double-taps within about 30 pt of the bottom edge.

## How to check it worked

On an iPhone, try portrait and **both** landscape directions (the Dynamic Island switches sides):

1. **Edges:** the fractal reaches every edge and corner, and is drawn under the Dynamic Island, as in Photos.
2. **Status bar:** it's hidden in both orientations.
3. **Buttons:** the three buttons and any notices stay clear of the Dynamic Island and the corners.
4. **Centring:** after Reset the set sits exactly in the middle of the physical screen. The tile-border overlay in the Developer panel makes this easy to judge.
5. **Pinch anchors:** pinch near the bottom edge and near the Dynamic Island side. The point under your fingers should stay put, which confirms step 3.
6. **Rotation:** rotate while zoomed in. The same point should stay at the centre, with no black flash.
7. **Mac:** unchanged, with the toolbar and fractal exactly as before.

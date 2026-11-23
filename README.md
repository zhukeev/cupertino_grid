# cupertino_grid

[![pub package](https://img.shields.io/pub/v/cupertino_grid.svg)](https://pub.dev/packages/cupertino_grid)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/zhukeev/cupertino_grid/blob/main/LICENSE)

iOS-Photos-style pinch-to-zoom grid for Flutter. Pinch with two fingers and
every cell morphs continuously between column counts — the photo under the
fingers stays under them — then the grid springs onto the nearest density.

![Pinch morph demo](doc/pinch_morph_demo.gif)

## Features

- **Focal-point preservation** — the pinched photo tracks the fingers through
  the whole gesture, including at grid edges and on a reversed
  (bottom-anchored, iOS-Photos-order) scroll axis.
- **Rigid lattice, local reflow** — cells stay uniform for most of the
  gesture; only a narrow window around each density boundary slides and
  morphs, like Photos' brief shuffle instead of a morph-long dissolve.
- **Deterministic settle** — release glides monotonically onto the nearest
  column count, with no down-then-up dip even when the grid underfills the
  viewport.
- **Keep-zooming opens the photo** — stretching past the largest stop tracks
  the pinch 1:1 and hands off an `OverscaleCommit` payload (index, painted
  screen rect, decode size) for a shared-element flight into your detail
  viewer.
- **Stable item identity** — tiles keep their keys across stop crossings, so
  thumbnails never remount or reload mid-gesture.
- **Full widget** — scrolling, two-finger recognition, morph overlay, section
  pills, pull-to-refresh, pagination and visibility callbacks included; or
  drive the pure-Dart `PinchMorph` engine yourself.
- **Accessibility-aware** — honors Reduce Motion / disableAnimations: pinches
  commit instantly without the morph animation.

## Install

```sh
flutter pub add cupertino_grid
```

```dart
import 'package:cupertino_grid/cupertino_grid.dart';
```

## Quick start

```dart
CupertinoGrid(
  itemCount: photos.length,
  columnCounts: const [1, 3, 5, 16],
  itemBuilder: (context, index, targetSize) =>
      PhotoTile(photo: photos[index], targetSize: targetSize),
)
```

`targetSize` is the cell's logical width at the current stop — pass it to your
thumbnail loader so overlay frames and the resting grid request the same
resolution. Tiles morph without a reload flash on commit.

## Common recipes

### Density ladder per device

```dart
CupertinoGrid(
  columnCountsForWidth: (width) =>
      width > 900 ? const [1, 5, 10, 24] : const [1, 3, 5, 16],
  // ...
)
```

`columnCountsForWidth` is re-evaluated on every layout, so rotation and
multi-window resizing just work.

### Section pills (date headers that ride on tiles)

```dart
CupertinoGrid(
  sectionLabelFor: (index) =>
      isFirstOfMonth(index) ? monthName(photos[index].date) : null,
  sectionLabelBuilder: (context, label) => MyPill(label),
  minLabelColumns: 5, // hide pills on sparse stops, like Photos
  // ...
)
```

`sectionLabelFor` doubles as the "is section start" predicate — return the
label text at section boundaries, `null` elsewhere. Pills stick under the
header at rest and dissolve with their section mid-morph.

### Decoded-image fast path

Handing the overlay decoded `ui.Image`s lets morph frames paint directly on
the canvas — no widget mounts at all while the fingers move:

```dart
CupertinoGrid(
  overlayImageFor: (index, targetSize) =>
      thumbCache.lookup(photos[index].id, targetSize),
  overlayImagesListenable: thumbCache, // repaints when async decodes land
  // ...
)
```

Indices returning `null` fall back to `itemBuilder` children automatically —
tiles that aren't decoded yet still show after a few layouts. Pair with
`onWarmRange` (reports the visible range at each reachable stop's tile size)
to pre-decode before the morph needs it.

### Keep-zooming opens the detail viewer

```dart
CupertinoGrid(
  onOverscaleCommit: (commit) {
    final image = thumbCache.lookup(photos[commit.index].id, commit.targetSize);
    openDetail(
      commit.index,
      launchRect: commit.rect,   // global screen rect of the stretched cell
      launchImage: image,        // for a shared-element flight
    );
  },
  // ...
)
```

A release stretched past `PinchMorphStyle.overscaleCommitThreshold` (1.5× by
default) fires the callback; below it, the overshoot stays a rubber-band peek
and settles back. `commit.targetSize` is the decode key the overlay actually
painted — query by it, not by `commit.rect`'s stretched size. The grid honors
Reduce Motion here too: no painted overscale means `rect` is the resting
cell's frame and nothing stretches.

### Reversed axis (iOS Photos order) + pull-to-refresh

```dart
CupertinoReverseRefresh(
  onRefresh: reload,
  indicatorInset: 80, // float the spinner above your bottom bar
  child: CupertinoGrid(
    reverse: true,      // item 0 at the bottom, scroll grows upward
    mirrorRows: true,   // rows read right-to-left, newest first
    physics: const FarEdgeClampScrollPhysics(),
    // ...
  ),
)
```

`CupertinoSliverRefreshControl` asserts a downward axis, so
`CupertinoReverseRefresh` overlays the pull indicator and watches leading-edge
overscroll itself. `FarEdgeClampScrollPhysics` clamps drags and flings at the
exhausted far edge (no "more to load" bounce) while the near edge keeps its
pull-to-refresh travel.

### Controlled density

```dart
CupertinoGrid(
  columns: state.columns,
  onColumnsChanged: (columns) => cubit.setColumns(columns),
  // ...
)
```

When `columns` is null the grid tracks density internally from
`initialColumns` (default: the middle of the ladder).

### Insert/remove diffs

```dart
CupertinoGrid(
  itemsVersion: photos,          // resync on reorder/merge at same count
  itemKey: (index) => photos[index].id,
  itemAnchorKey: (index) => photos[index].groupId, // survives stack folds
  removedItemBuilder: (context, index, animation) =>
      FadeTransition(opacity: animation, child: RemovedTile()),
  // ...
)
```

`itemAnchorKey` is the group identity used to re-resolve the pinched item when
the cell list reshapes mid-gesture — members of a collapsible group should
return the group's key.

### Hooks for caches and chrome

- `onVisibleItemsChanged` — the set of indices the current frame paints; feed
  it to decode priority so what the user sees evicts last.
- `onVisibleAnchorChanged` — the topmost row's anchor item and scroll
  direction, for resolution-aware prefetch.
- `onNearEnd` / `nearEndExtent` — pagination trigger.
- `overlayBuilder` — a layer between the resting grid and the morph overlay
  (a timeline scrubber), with stop, grid origin, scroll controller and
  `morphActive`.
- `overlayItemBuilder` — render morph tiles without resting decorations
  (labels, hero tags). `itemBuilder` is reused when null, with heroes
  suppressed via `HeroMode`.
- `headerBuilder` / `leadingSlivers` / `footer` / `emptyBuilder` — content
  around the grid; the morph replicates the header so it scrolls and clips
  identically mid-gesture.
- `topClearance` / `morphCoverageLeading` — insets for grids scrolled under
  floating chrome; the latter eases the coverage floor under a leading bar
  during the morph.

## Tuning the feel: PinchMorphStyle

Every behavioral constant lives in one immutable object; defaults match iOS
Photos reference footage, so `const PinchMorphStyle()` is the factory feel.
Invalid values assert at construction.

| Knob                        | Default   | What it moves                                             |
| --------------------------- | --------- | --------------------------------------------------------- |
| `reflowWindow`              | `0.25`    | Share of an interval that slides/morphs vs. stays rigid.  |
| `crossfadeEase`             | `2.0`     | How early the photo swap resolves inside the window.      |
| `coverageBlendSpan`         | `0.45`    | How gradually the edge-coverage push eases in.            |
| `levelSmoothing`            | `0.03`    | Low-pass (seconds) on the pinch level — `0` = raw.        |
| `rubberBand`                | `1.0`     | Overscale stretch response: 1 tracks the pinch exactly.   |
| `settleSpring`              | see below | Release spring — critically damped, ~300 ms settle.       |
| `commitThreshold`           | `0.18`    | Interval fraction a release must pass to carry on.        |
| `flickVelocity`             | `2.0`     | Stops/sec at release for momentum to commit.              |
| `flickStaleDuration`        | `90 ms`   | Age at which a level sample reads as fingers-held-still.  |
| `minEdgeSqueeze`            | `0.94`    | Scale floor of the densest-stop rubber-band.              |
| `edgeSqueezeGain`           | `0.12`    | How fast the edge squeeze approaches its floor.           |
| `edgeRefractory`            | `600 ms`  | Cooldown between edge squeezes.                           |
| `overscaleCommitThreshold`  | `1.5`     | Stretch that fires `onOverscaleCommit` on release.        |
| `pillExtent`                | `26`      | Section-pill band height in the overlay (taller = clip).  |
| `pillGap`                   | `4`       | Vertical gap between a pill and its tile band.            |
| `stickyImageBytes`          | `48 MB`   | Byte cap on decoded images the overlay retains.           |

```dart
CupertinoGrid(
  style: const PinchMorphStyle(
    reflowWindow: 0.35, // a wider morph around stop boundaries
    flickVelocity: 1.5, // commit on slower flicks
    settleSpring: SpringDescription(mass: 1, stiffness: 300, damping: 35),
  ),
  // ...
)
```

## Custom pixel effects: TileMorphEffect

`PinchMorph` owns geometry — positions, identity, swap timing. A
`TileMorphEffect` owns how an image-painted tile's pixels resolve mid-gesture.
`overlayTileEffect` takes a fixed effect; `overlayTileEffectBuilder` resolves
one per frame (return `null` for the plain cover-fit draw — e.g. to toggle
morphing off).

```dart
final gpu = await GpuImageMorphEffect.load(); // package:image_morph
final effect = TileMorphEffect.callbacks(
  paint: gpu.paint,
  paintPair: gpu.paintPair,
  flowImage: gpu.flowImage,
  onDispose: gpu.dispose,
);

CupertinoGrid(overlayTileEffect: effect, /* ... */);
```

[`package:image_morph`](https://github.com/zhukeev/veya_mobile/tree/main/packages/image_morph)
ships a runtime-shader content morph (focal warp + pixel-granular dissolve).
`TileMorphEffect.callbacks` adapts any paint functions, so effect packages
need not depend on `cupertino_grid` — a plain crossfade is a dozen lines.
Effects only apply to tiles painted via `overlayImageFor`; widget-painted
tiles keep the plain path. Note: runtime shaders don't execute under
`flutter test`'s rasterizer — evaluate them on a simulator or device.

## The engine without the widget: PinchMorph

`PinchMorph` is pure Dart (a `ChangeNotifier`) — render the morph yourself
with your own scene graph:

```dart
final morph = PinchMorph()
  ..begin(
    stops: myStops,            // List<MorphGridStop>
    startStop: 1,
    focalIndex: 42,
    focalFraction: const Offset(0.5, 0.5),
    focalPoint: touch.position,
    startScroll: scroll.offset,
    minScroll: scroll.minScrollExtent,
    trailing: footerExtent,
    itemCount: items.length,
    origin: gridOrigin,
    headerOrigin: headerTop,
    viewport: size,
  );

morph.set(level: pinchLevel, pin: 1.0); // scrub
final MorphFrame frame = morph.frame(isSectionStart);
// frame.tiles → List<MorphTile> { index, rect, opacity, targetSize, ... }
```

`frame()` emits paint-ordered tiles (departing coverage, stable slots,
arriving ghosts) plus section pills and the band clip rect. Every emitted tile
carries `targetSize` (the decode-size hint) and `arriving` (destination-lattice
content vs. rigid departing coverage).

## Debugging

- `debugMorphPaint: true` — tints the morph overlay: the focal cell hottest,
  successive rings cooler, off-destination slots veiled.
- `debugLog` — a `ValueChanged<String>` sink for anchor/commit diagnostics.
- `PinchMorph.debugTraceEnabled` + `PinchMorph.debugTrace` — engine-level
  frame log for custom renderers.

## How it works

Each frame draws one helical slot lattice: cell size interpolates
geometrically between the bracketing stops, slots carry items (so row offsets
stay stable for any position), and the lattice is placed so the focal slot
stays under the fingers — a bezel cell pins its edge, an interior cell scales
about the viewport centre. Outside a narrow reflow window around each interval
midpoint the nearer stop's layout simply scales; inside it, the band slides
rigidly to the other stop while each slot's content morphs in place. On
release a critically-damped spring eases the level to the nearest integer and
the overlay hands off to the committed `SliverGrid` — the same lattice
re-derived as real slivers, so the landing is pixel-identical.

## Example

A runnable demo grid over generated placeholder tiles lives in
[`example/`](https://github.com/zhukeev/cupertino_grid/tree/main/example):

```sh
cd example && flutter run
```

## Contributing

File issues at the
[issue tracker](https://github.com/zhukeev/cupertino_grid/issues). The
geometry contract the tests enforce is documented in
[`AGENTS.md`](https://github.com/zhukeev/cupertino_grid/blob/main/AGENTS.md)
— read it before changing motion behavior, and update it when you change the
rules deliberately.

## License

MIT — see [LICENSE](LICENSE).

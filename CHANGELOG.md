# Changelog

## Unreleased

- `CupertinoGridController` (`CupertinoGrid.controller`): the host-facing
  control surface a gallery rebuilds by hand today —
  `scrollToIndex(index, targetItemCount:, leadingInset:)` lands a row
  under floating chrome in one commit: it projects the post-merge
  `maxScrollExtent` from the grid's own extent delta (the live max still
  describes the pre-merge list mid-build), suppresses the leading-row
  anchor hold for that pass, and re-verifies the landing once extents
  settle. `scrollOffsetForIndex` exposes the same math for overlays;
  `indexAtGlobalPoint` resolves an item under a global point, axis-aware.
- Drag-range selection: `beginSelectionDrag` / `updateSelectionDrag` /
  `endSelectionDrag` sweep a contiguous SLOT range emitted as item
  indices on `selectedIndices` (mapped back through `itemAt` under
  `mirrorRows`), with select-and-drift edge auto-scroll
  (`edgeScrollBand`/`edgeScrollMaxSpeed`).
- `GridScrollDriver` (`CupertinoGridController.scrollDriver`) and
  `CupertinoGrid.onScrollSettled`: the grid classifies each scroll
  session (drag / ballistic / programmatic / idle) and reports the
  anchor + direction it settled on, so hosts no longer wrap the grid in
  a `NotificationListener` to tell drive-by anchors from real landings.
- `CupertinoGrid.onStopChanged`: a pinch commit reports the column
  count's index inside the caller's own ladder list
  (`columnCounts`/`columnCountsForWidth`) — needed when the ladder order
  isn't the sorted order the engine uses internally.

## 0.3.0

- `CupertinoGrid.onOverscaleCommit`: a release stretched past
  `PinchMorphStyle.overscaleCommitThreshold` (default 1.5×) at the
  largest-tile stop now hands the host an `OverscaleCommit` — the pinched
  item's resolved index, the stretched cell's painted GLOBAL screen rect
  (a shared-element flight launches straight from it), the raw stretch,
  and `targetSize`, the decode key the overlay actually used. Below the
  threshold the overshoot stays a rubber-band peek. Honours Reduce
  Motion: nothing stretches, `rect` is the resting cell's frame.
- `PinchMorphStyle.rubberBand` (default 1.0): overscale stretch response
  — `exp(excess · rubberBand)`; 1 tracks the pinch exactly for the
  "pull the photo open" hand-off, below 1 damps it into a peek.
- `MorphTile.arriving` marks destination-lattice content: the overlay now
  paints every in-rect arriving tile through the `TileMorphEffect` (or
  the plain cover-fit draw), not just pair members, and mounts
  `itemBuilder` children only for slots that stay unresolved past a few
  layouts. Fewer mounts → far less mid-gesture thumbnail churn.
- `CupertinoGrid.debugMorphPaint`: debug-only heatmap of the morph
  overlay — focal cell hottest, rings cooler, off-destination slots
  veiled.
- `CupertinoReverseRefresh`: pull-to-refresh overlay for reversed-axis
  scroll views — `CupertinoSliverRefreshControl` asserts
  `AxisDirection.down`, so this watches leading-edge overscroll and fires
  `onRefresh` past a configurable `trigger`. `indicatorInset` clears
  floating chrome; `indicatorBuilder` swaps the default
  `CupertinoActivityIndicator`.
- `FarEdgeClampScrollPhysics`: clamps drags and flings at
  `maxScrollExtent` (the exhausted far edge) while the near edge keeps
  its platform bounce — pairs with `CupertinoReverseRefresh` on
  bottom-anchored grids.
- `CupertinoGrid.morphCoverageLeading`: eased coverage floor under
  leading chrome (e.g. a floating bottom bar on a reversed grid) — tiles
  slide in to cover the strip during a morph and glide back on settle.
- Fix: eliminate a transient `AnimatedGrid` `_incomingItems` crash on
  rapid commit/rephase pairs (the insert cleanup microtask could race a
  remove in the same task).

## 0.2.0

- `TileMorphEffect`: pluggable pixel-level transform for image-painted
  morph tiles — `overlayTileEffect` for a fixed effect,
  `overlayTileEffectBuilder` for per-frame resolution (return `null` to
  keep the plain cover-fit draw). `TileMorphEffect.callbacks` adapts plain
  functions, so effect packages (e.g. `image_morph`) need not depend on
  this package.

## 0.1.0

- Initial release as `cupertino_grid`.
- `CupertinoGrid`: iOS-Photos-style pinch-to-zoom grid — focal-point
  preservation, localized reflow, deterministic settle, reversed-axis and edge
  handling, stable tile identity across density crossings.
- `PinchMorph`: pure-Dart morph engine behind the widget (frame emission for
  custom renderers).
- `PinchMorphStyle`: tunable feel — reflow window, crossfade, coverage blend,
  rubber band, settle spring, flick commit, edge squeeze, overlay dressing.

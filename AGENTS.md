# cupertino_grid — pinch-morph contract

How the pinch morph is *supposed* to behave, confirmed against iOS recordings and
real-device video. Tests encode these rules — change the rules deliberately and
update them together, or keep the rules and make every test keep passing.

## The model

- A morph blends between two stops' lattices that share one interpolated cell
  size. Every emitted slot is `focal + offset` resolved through each stop's own
  `itemAt` mapping — index resolution stays slot-based, independent of position.
- **One rigid band.** Every emitted tile — departing, arriving, same-item,
  ghost and coverage copies — rides the shared anchor:
  `emittedFocalLeft + columnOffset·strideX`, `focalTop + rowOffset·strideY`.
  Adjacent slots stay adjacent, no gaps ever open, and a photo morphs *in
  place*: its arriving image materialises at the same slot its departing
  image painted at, so the crossfade never slides a photo sideways.
- Each stop's lattice **centres its own column span**:
  `originX = (viewport.width − columns·stride + spacing) / 2`. At a stop
  boundary the band *is* the rest grid — crossings are exact with no easing
  residue.
- Emitting the arriving layer on its own centred columns was tried and
  reverted: pairing a departing photo at the band slot with its arriving
  copy at a different screen column makes the crossfade slide photos
  laterally — the "mid zoom-in moves weirdly" regression. A photo must
  morph in place, not travel.

## Landing rule (keep position)

The pinched photo keeps its screen position: it lands on the destination column
**nearest its start column's screen x**:

```text
 pinch [1] of [1..5]  ->  [1|2|3]   stays left
 pinch [2]            ->  [2|3|4]   stays left   (NOT centre)
 pinch [3]            ->  [2|3|4]   stays centre
 pinch [4]            ->  [2|3|4]   stays right
 pinch [5]            ->  [3|4|5]   stays right
```

Implemented in `pinch_morph.dart` as `_landingTarget` +
`_phaseForTarget` (phase = leading slots so `itemAt` resolves the focal onto the
target column). Edges fall out of the same rule — an edge column is already its
own nearest column. If the cell list reshapes mid-gesture (stack unfold /
merge), `rephaseLanding` re-derives the target from the *visual intent*
(edge/interior start column), not the stale index.

Under `mirrorRows` there is **no closed form** for the phase: a mirrored row
flips inside its *occupied* slot range, which itself moves with the phase —
the displayed column is self-referential in it. `_phaseForTarget` scans the
`0..columns-1` candidates and keeps the phase landing the focal nearest the
target. Do not resurrect a formula — the old one sent a 5-photo gallery's
leftmost photo to column 11 on a 5→16 pinch (reachable answer: column 1).

## The two windows (both eased smoothstep; endpoints always exact)

- `reflow` — vertical + row re-chunk + slot pairing. Adaptive mid-centred
  window (`_reflowWindowFor`, scaled to the interval's density jump).
- `crossfade` — photo swap, on the style's own early-eased window so tiles stay
  crisp.

Emitted positions do not blend at all: both stops' slot spaces anchor the
same focal slot, so their difference is a uniform translation. The band is
ONE rigid lattice — every slot emits at
`emittedFocalLeft + columnOffset·strideX`, `focalTop + rowOffset·strideY`.
The slot window only needs the band's visible range plus a margin — a
wider window emits offscreen tiles that break the keyed-tile boundary
checks.
Swap pairing in `morph_overlay.dart` keys on the slot offset
`(columnOffset, rowOffset)`, not the rect — under a rigid band both are
the same pair, but the slot key survives any future per-layer position
change.

## Horizontal band anchor (bezel pin / centre scale)

While the fingers are down (`pin == 1`) the band anchor is `_liveFocalLeftX`
— the focal cell's emitted left, chosen **by where the pinched cell sits**:

- A cell resting on **one bezel** pins that screen edge:
  `start.left + p·(start.width − cellWidth)` with `p = _focalPivotFrac`
  (0 left edge, 1 right edge). The photo under the finger hugs the bezel
  through the gesture. Scaling it about the viewport centre instead pulls
  the edge photo off its bezel mid-gesture and rides it back — the broken
  edge anchor.
- An **interior** cell — and a cell spanning BOTH bezels (the 1-col stop,
  which has no single edge to hug) — rides a scale about the viewport's
  horizontal centre: `W/2 + (start.left − W/2)·(cellWidth/start.width)`.
  The whole band is one rigid lattice scaled about the screen's middle, so
  a pinch on a side cell produces exactly the motion a pinch on the centre
  image does — column edges clip equally on both bezels at every level.
  Holding an interior focal's own pinch-start point instead kept the photo
  in place but left the band off centre — one bezel ate a clipped column
  while the other kept nearly a full one ("different padding"); pinning a
  1-col focal at the left bezel parked it off its mid-screen landing
  column until the settle glide carried it back.

Never anchor the band on the focal's rest-position glide: that translates
the whole lattice toward the landing column mid-gesture — a side landing
leaned toward one bezel (the "mid zoom-in isn't a centre zoom" regression).

On release the **tracked point** (`p` — bezel edge or centre) glides in a
straight line to its rest position as `pin → 0`:
`emitted = lerp(rest.left + p·rest.width, live + p·cellWidth, pin) − p·cellWidth`.
The parked start grid and the committed grid are both exact, and the
settle path doesn't curve with the still-resizing cell.

The focal slot's tile **always emits**, even when its band position is
fully offscreen: a centre-scaled interior focal legitimately slides past
a bezel mid-gesture, and dropping the tile would break position reads
(the emitted-rect cull and the slot window both exempt slot `(0,0)`).

## Vertical coverage (band edges)

- The coverage push exists to stop the morph exposing a *content hole*: it
  slides the lattice so the content edges still reach `bandTop`/`bandBottom`.
- Its floors are **capped by the parked margins** —
  `coverTop = max(bandTop, clipTop)` and the mirrored bottom — where `clipTop`
  is the content edge position the parked grid shows. At a list boundary the
  parked margin is inside the band, so the edge simply rides it (iOS Photos
  does the same: the end margin stays put). Pulling an edge *deeper* than
  parked manufactures a position the settle must glide back out of — the
  vertical wobble regression (an edge pinch dragged the focal ~200px, then
  the release snapped the return in two legs).
- Mid-list pinches park their edges off the band (`clipTop` clamps to 0), so
  the floors fall back to the band edges and the push still covers gaps the
  morph itself opens. `coverageLeading` keeps easing `coverageClipTop`
  between those cases.
- **Every `restScrolls` write goes through `PinchMorph.restScrollFor`** —
  the single derivation begin/commit/retarget share (the clamp is inside
  it). The focal-anchored formula lands out of range near an edge; a
  write that bypassed it shifted the overlay's rest target after the grid
  already knew where it lands — a visible snap (a +149px one in the
  traced regression). Do not re-derive the formula at call sites.

## Image gating (next screen)

The morph region is the destination screen's own **rectangle in slot
space**: the `columns`-wide band of slot offsets that land on the
lattice's real columns (`0 <= focalColumn + columnOffset < columns`)
times the focal-anchored rest row window `_TileEmitter.nextScreen`
(`windowTop <= focalRow + rowOffset <= windowBottom`). Only slots inside
that rectangle may swap or deform their photo; slots outside it hold
their departing image rigid until they slide off — no ghost photos at
positions the destination grid has no cell for.

Why slot coordinates, not item membership: `itemAt` resolves a slot's
index *linearly*, so a column offset off the grid edge wraps to a real
item from a neighbouring row. A membership test on the item ("is this
photo on the next screen") flags those wrapped slots too — the flag
union reads as a ragged band far wider than the next screen (~65–90% of
visible cells where the rectangle owns ~40%). The gate is measured on
the SLOT's destination coordinates so the region stays a strict
rectangle.

`MorphTile.onNextScreen` carries the rectangle flag — every op at a
slot shares it, and `MorphTile.arriving` marks the destination
lattice's content (over-layer ghosts plus the zoom-in under-layer
arriving carriers) as opposed to departing coverage and stable copies.
Every decoded image op inside the rectangle resolves through the tile
effect — the plugin owns the transition, not an alpha ramp: co-rect
swap pairs morph through `paintPair` where `arrivingPaints` (rectangle
and `arrivingBoundary`) let the arriving copy paint, and UNPAIRED
arriving ops materialise through `effect.paint`, which consumes opacity
as a per-pixel dissolve threshold rather than an alpha blend. Zoom-in
additionally warps in-rectangle departing ops (its established look);
zoom-out departing coverage and every off-rectangle op stay on the
plain draw — a warp deforms rigid coverage. The debug tint draws one
colour per slot — the first visible op's flag — so the heatmap shows
the rectangle itself.

Zooming out, a slot whose departing item was not on the start screen
(`wasOnStartScreen`, the same window counted on the start stop) is new
territory sliding in and may materialise freely; a ~3% `boundaryBand`
lets the arriving side carry exact stop tiles at interval edges. The
departing keep keys on the arriving copy's *opacity* (a slot whose
arriving item fails the rectangle paints nothing, so its departing
photo covers until commit).

Cross-lattice duplicates (departing + arriving copies of one photo at
different slots) are normal — each photo glides to its own landing cell.
The rectangle gate is not a deduplication tool: it confines *deformation*
to the destination footprint; duplicate copies at off-rectangle slots
simply stay rigid there while the item morphs at its in-rectangle slot.

## Phase ownership (controlled columns)

`_phase` must always satisfy `phase < _effectiveColumns` — `MorphGridStop`
throws otherwise. A landing phase is only valid for its own stop's column
count, and a controlled parent adopts the settle density a rebuild *after*
`_applyPhase` runs, so a stamp can exceed the current grid's columns in that
window. Rule: `_applyPhase(next, forColumns:)` defers to `_pendingPhase` when
the columns haven't committed; `didUpdateWidget` applies the held stamp the
moment the matching `widget.columns` lands. Never stamp a phase directly, and
never clamp it to look valid — a lost landing phase re-lands the photo on the
wrong column. The reduce-motion path (`_finishMorphEarly` → `_fireAnchor` →
`_currentStop`) is the deterministic trigger; the bug is live in any build
that runs between stamp and column commit.

## Scroll bounds (trailing footer)

`trailing` — the content tail below the grid — is the footer sliver's chrome
and is identical at every density. `_scrollMetrics` derives it from scroll
extents only while the grid overflows; a **fitting** grid reports no extent,
so it takes the footer render box's measured height (`_footerExtent`).
Without it a fitting→scrollable pinch clamps the rest scroll `footer` short
of the real extent and lands the last row above its edge.

## Overscale open (pull-to-open)

The largest-tile stop is the level floor; spreading past it produces
`overscale`, a stretch factor applied to the whole band's cell size.
`rubberBand = 1.0` means the stretch tracks the pinch spread exactly —
the "pull the photo open" hand-off needs it under the fingers, not damped
into a peek. A release with `_rawOverscale >= overscaleCommitThreshold`
(default 1.5) fires `onOverscaleCommit` and the grid still settles back
to the largest stop.

The `OverscaleCommit` payload carries:

- `index` — the pinched item re-resolved through item/anchor keys, so a
  reshape mid-gesture can't hand back a stale index.
- `rect` — slot `(0,0)`'s emitted rect shifted to GLOBAL screen
  coordinates — the flyer's launch pose. Under reduce motion (nothing
  overscaled painted) or a refractory-suppressed pull it falls back to the
  resting grid cell, the last pose actually shown.
- `overscale` — the raw stretch at release.
- `targetSize` — the emitted tile's decode-size hint (the same value
  `overlayItemBuilder`/`overlayImageFor` received). `rect` is stretched
  past it by `overscale`, so a lookup keyed on `rect.width` misses the
  painted decode entirely.

Two release paths can fire the commit without a painted stretch: reduce
motion never mounts the overlay, and the edge refractory (wall-clocked —
test fake time cannot expire it) clamps a second pull inside its window to
`overscale = 1` while `_rawOverscale` still reports intent. Hosts must
treat `rect` as "what was last on screen", not "the user's spread".

## Focal invariants (user-visible, guarded by tests)

- **anchor.dx is finger-independent** — an off-centre pinch must not shift the
  band; the pinch point tracks the finger only vertically.
- **Bezel focal never leaves its bezel** — a cell resting on ONE bezel keeps
  its emitted bezel-side edge at its pinch-start value at every level. An
  edge photo scaled about the centre pulls off the bezel mid-gesture — the
  broken edge anchor.
- **Interior focal rides the centre scale** — its emitted left is the parked
  left scaled about the viewport centre by `cellWidth/start.width`, so both
  bezels clip equally at every level (a centre-image pinch's motion). A cell
  spanning both bezels counts as interior here: it has no edge to hug, and
  the scale converges it onto its landing column. A band that holds the
  focal's own pinch-start point instead keeps lopsided margins; one that
  translates toward the landing column is the lean.
- **Every emitted tile rides one shared band** — `left − columnOffset·strideX`
  is identical for all tiles in a frame; a tile on any other position is
  riding a column shift that is not its own.
- **Focal tile never culled** — the emitted window always contains the focal
  slot, even fully offscreen (a centre-scaled interior focal legitimately
  exits mid-gesture).
- **Landing is exact** — at a settled boundary (`pin == 0` with `settleStop`
  stamped, as the real release path does) every on-window tile sits on its
  true destination column (`spacing + col·stride`).

## Where each rule is guarded

- `test/pinch_morph_symmetric_edges_test.dart` — span centring, margin symmetry,
  centre-scale for interior focals, bezel edge-hold, exact boundary landing,
  finger-independent anchor.
- `test/pinch_morph_next_viewport_test.dart` — morph-window gating
  (item destination-row window; no horizontal gate).
- `test/pinch_morph_landing_phase_test.dart` — mirrored partial-row landing
  columns (the candidate-scan contract).
- `test/pinch_morph_window_test.dart` — visible-window emission/culling.
- `test/cupertino_grid_test.dart` — committed-grid keep-position landings,
  position audits, mid-settle reshape rephasing, edge-pinch parked-margin
  coverage (`coverage floor never drags`), pending landing phase under
  controlled columns (`reduce-motion pinch holds`), fitting→scrollable
  footer landing (`pinch from a fitting grid lands the last row`).
- `test/pinch_morph_cell_trajectory_test.dart` — every emitted tile sits on
  one shared band anchor through the whole gesture, and that anchor is the
  conditional contract (bezel pin / centre scale) for every focal column —
  catches both the lean and the lopsided-margin regressions.
- `test/pinch_morph_fuzz.dart` — continuity/no holes across random sweeps;
  coverage resolves each sample's band slot geometrically through the
  emitter's stamped stops (floor, clip- and gutter-aware).
- `test/pinch_morph_golden_test.dart` — pixel truth mid-gesture, mid-settle,
  and after commit, both axes. **Goldens are the intentional fragile layer**:
  any deliberate motion change requires `--update-goldens`; a diff must be
  eyeballed against this contract, not rubber-stamped.
- `test/pinch_morph_cells_{a..d}_test.dart` — per-cell morph sweeps (sharded).
- `test/cupertino_grid_overlay_stack_test.dart` — overlay mount/paint paths
  and the overscale commit: threshold gating, the launch rect's painted
  pose vs the resting-cell fallback, and the `targetSize` decode key.

## Verified numbers (worth re-deriving before changing the anchor)

Edge focal zooming out 5→16 (`Size(390,800)`, spacing 2): the bezel-side
edge holds its pinch-start value for the whole gesture; the inboard edge
moves only with the shared scale. On release (`pin → 0`) the tracked point
glides in a straight line onto its rest column —
`emitted = lerp(rest + p·restW, live + p·cellW, pin) − p·cellW` — exact at
both ends.

Interior focal (e.g. a 5-col cell parked at `left ≈ 80`): the emitted left
is `W/2 + (80 − W/2)·(cellW/76.8)` — it slides off the near bezel as the
band grows and lands within a column of its rest slot, so the bezel clip
margins stay equal at every level (verified: identical sliver widths in the
regenerated mid-gesture goldens). Bezel-focal frames remain pixel-identical
to the pinned-reference goldens.

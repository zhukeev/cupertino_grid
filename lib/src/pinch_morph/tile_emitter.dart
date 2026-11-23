part of '../pinch_morph.dart';

/// Emits the classified tile layers and section pills for one morph frame.
/// The per-frame constants (lattices, focal coords, fade position, rest
/// windows) arrive via the constructor; [emit] walks the union of both
/// lattices' visible slot windows once and returns the three paint layers
/// plus the pill list.
final class _TileEmitter {
  _TileEmitter({
    required this.larger,
    required this.denser,
    required this.emittedFocalLeft,
    required this.focalTop,
    required this.strideX,
    required this.strideY,
    required this.cellWidth,
    required this.cellHeight,
    required this.focalColumnLarger,
    required this.focalRowLarger,
    required this.focalColumnDenser,
    required this.focalRowDenser,
    required this.itemCount,
    required this.viewport,
    required this.clipTop,
    required this.bandBottom,
    required this.reversed,
    required this.progress,
    required this.crossfade,
    required this.zoomIn,
    required this.restScrolls,
    required this.lowerStop,
    required this.origin,
    required this.pinchStartStop,
    required this.startScroll,
    required this.focalIndex,
    required this.isSectionStart,
  });

  /// The larger-tile (sparser) stop of the interval.
  final MorphGridStop larger;

  /// The denser stop of the interval.
  final MorphGridStop denser;

  /// The emitted band's anchor: the focal slot's left edge this frame
  /// (the pinch-start pivot from `PinchMorph._emittedFocalLeftX`) and
  /// its resolved top. Every slot emits at
  /// `emittedFocalLeft + columnOffset·strideX`,
  /// `focalTop + rowOffset·strideY` — one rigid lattice, so adjacent
  /// slots stay adjacent and no gaps open.
  final double emittedFocalLeft;
  final double focalTop;

  /// This frame's interpolated slot pitch and cell size — shared by
  /// every emitted slot.
  final double strideX;
  final double strideY;
  final double cellWidth;
  final double cellHeight;

  /// The focal item's slot coordinates in each stop's lattice.
  final int focalColumnLarger;
  final int focalRowLarger;
  final int focalColumnDenser;
  final int focalRowDenser;

  final int itemCount;
  final Size viewport;

  /// Header clearance the band starts under, and the band's bottom edge
  /// (viewport height minus trailing inset).
  final double clipTop;
  final double bandBottom;

  /// Mirrored emission about the horizontal axis (reversed scroll axis).
  final bool reversed;

  /// Raw interval progress — `0` means resting at the lower stop (the
  /// denser stop's window then collapses onto the larger's).
  final double progress;

  /// Photo-crossfade position — eased ahead of the position reflow so
  /// images snap
  /// early inside the window (see `frame()`).
  final double crossfade;

  /// Travelling toward the sparser stop (level below the pinch's start).
  final bool zoomIn;

  /// Rest scroll of each stop and this interval's lower index — the
  /// windows each stop actually repaints during the reflow.
  final List<double> restScrolls;
  final int lowerStop;
  final double origin;

  /// The stop the pinch began on and its scroll — a departing photo only
  /// qualifies as a ghost while it was actually visible there; without it
  /// the slot is new territory and must remap normally so stop boundaries
  /// stay exact.
  final MorphGridStop pinchStartStop;
  final double startScroll;

  /// The pinched item — the focal row every rest-screen window counts
  /// its above/below row strides from.
  final int focalIndex;

  /// Section-start predicate from `frame()` — pills ride these items.
  final bool Function(int index) isSectionStart;

  /// Runs the emission: returns (under, stable, over) tile layers in paint
  /// order and the section pills.
  (List<MorphTile>, List<MorphTile>, List<MorphTile>, List<MorphPill>) emit() {
    // The emitted band is a single lattice anchored at
    // (emittedFocalLeft, focalTop), so the visible slot-offset range is
    // one interval — each margin below covers slots slivered on an edge.
    // The focal slot itself always emits: under the centre-scale anchor
    // an off-centre focal legitimately slides past a bezel mid-gesture,
    // and dropping its tile would break the "focal is always in the
    // frame" invariant callers (and tests) rely on.
    final minColumnOffset = math.min(((-cellWidth - emittedFocalLeft) / strideX).floor() - 1, 0);
    final maxColumnOffset = math.max(((viewport.width - emittedFocalLeft) / strideX).floor() + 1, 0);
    final minRowOffset = math.min(((clipTop - cellHeight - focalTop) / strideY).floor() - 1, 0);
    final maxRowOffset = math.max(((viewport.height - focalTop) / strideY).floor() + 1, 0);

    // Whole rows only the larger-tile stop has slide out under the header /
    // past the bottom as the clamp above moves the lattice, so they stay
    // solid — fading them would expose background. Below the content they
    // only slide when the content is taller than the screen; partial
    // first/last-row slots never slide (the rest grid leaves them empty
    // too), so they fade.
    final bottomRowsSlide = denser.rowCount(itemCount) * strideY >= bandBottom - clipTop - larger.spacing;
    final denserLastRow = denser.rowOf(itemCount - 1);

    // Each stop's "next screen" — the rows its own grid shows at scroll
    // [rest] — counted off the focal row: its rest screen top leaves
    // `focalTop / rowStride` rows above it and `(height − focalTop) /
    // rowStride` rows at/below it (the focal row itself included). That
    // is exactly `rowAtY(rest) .. rowAtY(rest + height)` with no phantom
    // margin: only slots inside the window update their photo during the
    // reflow; slots outside keep the photo they already had instead of
    // remapping to an item the destination screen doesn't have (iOS's
    // ghost edges on a 16→5 pinch).
    (int, int) nextScreen(MorphGridStop stop, int focalRow, double rest) {
      final focalTop = stop.rowTop(focalRow, origin) - rest;
      return (
        focalRow - (focalTop / stop.rowStride).ceil(),
        focalRow + ((viewport.height - focalTop) / stop.rowStride).floor(),
      );
    }

    final (windowTopLarger, windowBottomLarger) = nextScreen(larger, focalRowLarger, restScrolls[lowerStop]);
    final (windowTopDenser, windowBottomDenser) = progress == 0
        ? (windowTopLarger, windowBottomLarger)
        : nextScreen(denser, focalRowDenser, restScrolls[lowerStop + 1]);
    // Travelling sparser (level below where the pinch began) departs the
    // denser stop's layer: `dense` stays solid everywhere and `sparse`
    // materialises only inside the larger stop's next screen. Travelling
    // denser is the mirror: `sparse` stays, `dense` arrives inside the
    // denser stop's window.
    final (startVisibleTop, startVisibleBottom) = nextScreen(
      pinchStartStop,
      pinchStartStop.rowOf(focalIndex),
      startScroll,
    );
    bool wasOnStartScreen(int index) =>
        pinchStartStop.rowOf(index) >= startVisibleTop && pinchStartStop.rowOf(index) <= startVisibleBottom;

    final underTiles = <MorphTile>[];
    final stableTiles = <MorphTile>[];
    final overTiles = <MorphTile>[];
    final pills = <MorphPill>[];
    final largerTileSize = larger.tileWidth.ceil();
    final denserTileSize = denser.tileWidth.ceil();

    for (var rowOffset = minRowOffset; rowOffset <= maxRowOffset; rowOffset++) {
      for (var columnOffset = minColumnOffset; columnOffset <= maxColumnOffset; columnOffset++) {
        // The slot's emitted rect — anchored directly on the band: the
        // focal slot's glide position plus this slot's offset at the
        // shared stride. No blend needed: both stops' slot spaces anchor
        // the same focal slot, so their position difference is a uniform
        // translation (the old per-slot `Rect` lerp resolved to this
        // same point while paying four lerps).
        final rect = Rect.fromLTWH(
          emittedFocalLeft + columnOffset * strideX,
          focalTop + rowOffset * strideY,
          cellWidth,
          cellHeight,
        );
        // Half-pixel slack: slivers resting exactly on an edge would
        // otherwise flicker in and out with float noise. The focal slot
        // itself is exempt: under the centre-scale anchor an off-centre
        // focal legitimately slides fully past a bezel mid-gesture, and
        // callers rely on its tile being emitted (position reads, layer
        // keys) even while it paints nothing onscreen.
        if (rowOffset != 0 || columnOffset != 0) {
          if (rect.right <= 0.5 ||
              rect.left >= viewport.width - 0.5 ||
              rect.bottom <= clipTop + 0.5 ||
              rect.top >= viewport.height - 0.5) {
            continue;
          }
        }
        // Emit in real screen coords — mirrored about the horizontal axis
        // when the scroll axis is reversed.
        final tile = reversed
            ? Rect.fromLTRB(rect.left, viewport.height - rect.bottom, rect.right, viewport.height - rect.top)
            : rect;
        // The item each slot holds resolves through the stop's real
        // slot→item mapping: interior rows are linear in ±columnOffset
        // either way (mirrored rows descend), and the clamped head/tail
        // rows and phase holes report −1 so the partner lattice — not an
        // extrapolated item — fills them, exactly as the committed grid
        // leaves them empty.
        final denseRow = focalRowDenser + rowOffset;
        final denseItem = denser.itemAt(denseRow * denser.columns + focalColumnDenser + columnOffset, itemCount);
        final hasDense = denseItem >= 0 && denseItem < itemCount;
        final horizontallyVisible = rect.center.dx >= 0 && rect.center.dx < viewport.width;

        // The larger-tile stop's photo in this slot: same slot offset from
        // the focal photo, in that stop's (helical) column count.
        final sparseRow = focalRowLarger + rowOffset;
        final sparseItem = larger.itemAt(sparseRow * larger.columns + focalColumnLarger + columnOffset, itemCount);
        final hasSparse = sparseItem >= 0 && sparseItem < itemCount;
        // The morph region is the destination screen's own rectangle in
        // slot space: the `columns`-wide band of slot offsets that land
        // on the lattice's real columns, times the rest-screen row
        // window. `itemAt` resolves the slot's index LINEARLY, so a
        // column offset off the grid edge wraps to a real item from a
        // neighbouring row — a membership test on the item ("is this
        // photo on the next screen") flags those wrapped slots too, and
        // flagged ops deform — the union reads as a ragged band far
        // wider than the next screen. The check below gates on the
        // SLOT's destination coordinates instead, so the region is a
        // strict rectangle: slots outside it hold their departing photo
        // rigid, and no arriving copy may materialise where the
        // destination grid has no cell.
        final sparseInRect =
            (focalColumnLarger + columnOffset) >= 0 &&
            (focalColumnLarger + columnOffset) < larger.columns &&
            sparseRow >= windowTopLarger &&
            sparseRow <= windowBottomLarger;
        final denseInRect =
            (focalColumnDenser + columnOffset) >= 0 &&
            (focalColumnDenser + columnOffset) < denser.columns &&
            denseRow >= windowTopDenser &&
            denseRow <= windowBottomDenser;
        final onNextScreen = zoomIn ? sparseInRect : denseInRect;
        const boundaryBand = 0.03;
        final arrivingBoundary = zoomIn ? progress < boundaryBand : progress > 1 - boundaryBand;
        // The single predicate behind every "may the arriving layer paint
        // here" question: inside the destination rectangle (plus,
        // zoom-out, slots whose departing item wasn't on the start screen
        // — new territory sliding in), or inside the sliver of progress
        // at the interval edge the arriving side owns. Every emit
        // condition and opacity below keys off it — if any drifted to a
        // copy, the departing layer could be dropped while nothing
        // arrives to cover it.
        final arrivingVisible = zoomIn
            ? onNextScreen || arrivingBoundary
            : onNextScreen || !wasOnStartScreen(sparseItem) || arrivingBoundary;
        // Does the arriving copy actually cover this slot this frame —
        // the arriving lattice has an item here, it differs from the
        // departing one, and its paint gate is open. The keep-departing
        // guard keys on it: a slot whose arriving item paints nothing
        // keeps its departing photo to the interval end.
        final arrivingPaints = (zoomIn ? hasSparse : hasDense) && denseItem != sparseItem && arrivingVisible;

        // `denseItem == sparseItem` means the same item occupies this
        // slot offset in both lattices — it is real content at both ends
        // of the transition, so it stays solid regardless of where the
        // rest-screen window currently sits — as long as its destination
        // slot is on the next screen (otherwise it is departing-only).
        if (hasDense && hasSparse && denseItem == sparseItem && onNextScreen) {
          stableTiles.add((
            index: denseItem,
            columnOffset: columnOffset,
            rowOffset: rowOffset,
            rect: tile,
            opacity: 1.0,
            targetSize: largerTileSize,
            onNextScreen: onNextScreen,
            arriving: false,
          ));
        } else {
          // Whole rows only the larger-tile stop has slide out under the
          // header / past the bottom as the clamp moves the lattice, so
          // they stay solid — fading them would expose background.
          final rowSlidesOut = !hasDense && (denseRow < 0 || (denseRow > denserLastRow && bottomRowsSlide));
          if (zoomIn) {
            // Departing `dense` stays solid — it is both the coverage and
            // the ghost: outside the larger stop's window the old photo
            // simply remains until its slot slides off. Where the arriving
            // stop has no item in this slot at all it is new content
            // rather than a ghost, so it fades in with the window instead
            // of snapping to full opacity the moment crossfade leaves 0.
            // Off the next screen the departing photo also covers the
            // pre-window region (`progress > 0`) where `crossfade` is
            // still 0 — otherwise the pure-lattice frame would swap the
            // cell to the arriving photo a third of the gesture early;
            // it may only be replaced at the commit itself.
            if (hasDense && (crossfade > 0 || (!arrivingPaints && progress > 0))) {
              underTiles.add((
                index: denseItem,
                columnOffset: columnOffset,
                rowOffset: rowOffset,
                rect: tile,
                opacity: hasSparse ? 1.0 : crossfade,
                targetSize: denserTileSize,
                // The lone warp keys on the slot's rectangle flag: a
                // departing photo inside the morph region warps with
                // it; outside it stays rigid coverage, matching the
                // zoom-out contract (the debug veil keys on this flag
                // too — the heatmap draws the rectangle, not items).
                onNextScreen: onNextScreen,
                arriving: false,
              ));
            }
            // The arriving stop's rest tile always emits (`crossfade <=
            // 0` keeps stop-boundary frames exact) — but off-screen
            // slots only inside the boundary band, so their cells hold
            // the departing photo until the stop is actually reached.
            // A padding slot's fade-in stays keyed at off-screen slots
            // too, but paints at 0 outside its boundary band — popping
            // the key in or out mid-window would break continuity.
            if (hasSparse && ((crossfade <= 0 && arrivingVisible) || (!hasDense && crossfade < 1))) {
              underTiles.add((
                index: sparseItem,
                columnOffset: columnOffset,
                rowOffset: rowOffset,
                rect: tile,
                opacity: rowSlidesOut || crossfade <= 0 ? 1.0 : (arrivingVisible ? 1 - crossfade : 0.0),
                targetSize: largerTileSize,
                onNextScreen: onNextScreen,
                // The sparse item is the arriving stop's content — the
                // rest-keyed carrier and the padding materialise alike.
                arriving: true,
              ));
            }
            // `denseItem == sparseItem` lands here only when the slot is
            // off the next screen — the "arriving" side is the same
            // departing photo, so no ghost layer may emit for it. The
            // ghost itself stays keyed but paints at 0 off the next
            // screen outside the boundary band.
            if (hasSparse && hasDense && crossfade > 0 && denseItem != sparseItem) {
              overTiles.add((
                index: sparseItem,
                columnOffset: columnOffset,
                rowOffset: rowOffset,
                rect: tile,
                opacity: arrivingVisible ? 1 - crossfade : 0.0,
                targetSize: largerTileSize,
                onNextScreen: onNextScreen,
                arriving: true,
              ));
            }
          } else {
            // Departing `sparse` stays solid under `dense`; `dense`
            // materialises only inside the denser stop's next screen.
            // Departing `sparse` stays rigid: a slot whose arriving copy
            // can't paint (off the focal window, or its wrapped item
            // outside the item row window) keeps it to the interval end
            // (`progress < 1`) since nothing arrives to cover it —
            // `crossfade` saturates early and would drop it mid-frame
            // leaving an uncovered pop.
            if (hasSparse && (rowSlidesOut || crossfade < 1 || (!arrivingPaints && progress < 1))) {
              underTiles.add((
                index: sparseItem,
                columnOffset: columnOffset,
                rowOffset: rowOffset,
                rect: tile,
                opacity: hasDense || rowSlidesOut ? 1.0 : 1 - crossfade,
                targetSize: largerTileSize,
                // Same slot-rectangle flag as the zoom-in departing
                // copy — a departing op never lone-warps, so it only
                // steers the veil, and the question it answers stays
                // "is this slot inside the destination screen's
                // rectangle".
                onNextScreen: onNextScreen,
                arriving: false,
              ));
            }
            // `denseItem == sparseItem` lands here only when the slot is
            // off the next screen — no ghost of the departing photo.
            // The ghost stays keyed but paints at 0 off the next screen
            // outside the boundary band, where the rest-key identity
            // needs it opaque.
            if (hasDense && crossfade > 0 && denseItem != sparseItem) {
              overTiles.add((
                index: denseItem,
                columnOffset: columnOffset,
                rowOffset: rowOffset,
                rect: tile,
                opacity: arrivingVisible ? crossfade : 0.0,
                targetSize: denserTileSize,
                onNextScreen: onNextScreen,
                arriving: true,
              ));
            }
          }
        }
        // Pills ride their tile's emitted top; arriving-layer pills
        // follow the same next-screen gate as their tiles.
        if (horizontallyVisible &&
            larger.showsLabels &&
            hasSparse &&
            isSectionStart(sparseItem) &&
            (zoomIn ? onNextScreen : crossfade < 1)) {
          pills.add((
            index: sparseItem,
            columnOffset: columnOffset,
            rowOffset: rowOffset,
            top: tile.top,
            opacity: 1 - crossfade,
            layer: 0,
          ));
        }
        if (horizontallyVisible &&
            denser.showsLabels &&
            hasDense &&
            isSectionStart(denseItem) &&
            (zoomIn ? crossfade > 0 : onNextScreen && crossfade > 0)) {
          pills.add((
            index: denseItem,
            columnOffset: columnOffset,
            rowOffset: rowOffset,
            top: tile.top,
            opacity: zoomIn ? 1.0 : crossfade,
            layer: 1,
          ));
        }
      }
    }
    return (underTiles, stableTiles, overTiles, pills);
  }
}

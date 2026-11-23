import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart' show immutable;

/// Rest layout of one density stop. Mirrors the real sliver grid exactly
/// (a padding of [spacing] around a fixed-count grid starting at the
/// measured grid origin), so overlay frames and the committed grid line up
/// pixel for pixel.
@immutable
final class MorphGridStop {
  const MorphGridStop._(
    this.columns,
    this.tileWidth,
    this.tileHeight,
    this.spacing,
    this.showsLabels,
    this.phase,
    this.mirrorRows,
  );

  /// Creates a stop whose cells fit [viewportWidth] with [spacing] gaps and
  /// a cell aspect of [aspect] (height / width).
  factory MorphGridStop(
    int columns,
    double viewportWidth, {
    required double spacing,
    required double aspect,
    bool showsLabels = false,
    int phase = 0,
    bool mirrorRows = false,
  }) {
    if (columns < 1) {
      throw ArgumentError.value(columns, 'columns', 'Must be at least 1.');
    }
    if (!viewportWidth.isFinite || viewportWidth <= 0) {
      throw ArgumentError.value(viewportWidth, 'viewportWidth', 'Must be finite and greater than 0.');
    }
    if (!spacing.isFinite || spacing < 0) {
      throw ArgumentError.value(spacing, 'spacing', 'Must be finite and non-negative.');
    }
    if (!aspect.isFinite || aspect <= 0) {
      throw ArgumentError.value(aspect, 'aspect', 'Must be finite and greater than 0.');
    }
    if (phase < 0 || phase >= columns) {
      throw ArgumentError.value(phase, 'phase', 'Must be in the range 0..columns-1.');
    }
    final width = math.max(1.0, (viewportWidth - (columns + 1) * spacing) / columns);
    return MorphGridStop._(columns, width, width * aspect, spacing, showsLabels, phase, mirrorRows);
  }

  /// Cells per row at this density.
  final int columns;

  /// Cell width in logical pixels, derived from the viewport.
  final double tileWidth;

  /// Cell height in logical pixels — [tileWidth] × the aspect.
  final double tileHeight;

  /// Gap between cells and around the grid edge.
  final double spacing;

  /// Section labels ride on this stop's tiles.
  final bool showsLabels;

  /// Leading empty slots the layout keeps — the column phase a pinch
  /// commits to so the zoomed photo settles at the center column.
  /// 0 = index-absolute layout.
  final int phase;

  /// iOS Photos' oldest→newest reading direction on a reversed scroll
  /// axis: each row's valid item run flips left-right inside its slot
  /// row. The flip is anchored to the row's own item range — row bases
  /// shift by [phase], so a chunked mirror of the item list would split
  /// reversed runs mid-row once the phase is nonzero.
  final bool mirrorRows;

  /// A copy of this stop with a different column [phase] (leading empty
  /// slots — used to land the pinched photo at the center column).
  MorphGridStop withPhase(int phase) {
    if (phase < 0 || phase >= columns) {
      throw ArgumentError.value(phase, 'phase', 'Must be in the range 0..columns-1.');
    }
    return MorphGridStop._(columns, tileWidth, tileHeight, spacing, showsLabels, phase, mirrorRows);
  }

  /// Column pitch — one cell's width plus its gap to the next.
  double get columnStride => tileWidth + spacing;

  /// Row pitch — one cell's height plus its gap to the next.
  double get rowStride => tileHeight + spacing;

  /// Cell width over height — the value a `SliverGridDelegate` takes.
  double get childAspectRatio => tileWidth / tileHeight;

  /// Cell height over width (e.g. 4:3 portrait for the single column).
  double get aspect => tileHeight / tileWidth;

  /// Item indices occupying [row]'s slots: `[lo, hi)` in layout order —
  /// always `row * columns − phase` clipped to the list, whether or not
  /// the row's contents are mirrored.
  (int, int) _rowRange(int row, int itemCount) =>
      (math.max(0, row * columns - phase), math.min(itemCount, row * columns + columns - phase));

  /// Mirrors a cell within its row's valid range — an involution, so
  /// [slotOf] and [itemAt] share it (the row argument is read from the
  /// input's own space: `index + phase` for slots, `slot` for items).
  int _flip(int cell, int row, int itemCount) {
    final (lo, hi) = _rowRange(row, itemCount);
    return lo + hi - 1 + phase - cell;
  }

  /// Layout slot [index] occupies — the phase shifts it right, leaving
  /// empty cells at the grid's head; under [mirrorRows] each row's valid
  /// item run flips left-right inside its slot span (partial head rows
  /// stay right-aligned, partial tail rows left-aligned).
  int slotOf(int index, int itemCount) {
    if (!mirrorRows) return index + phase;
    return _flip(index, (index + phase) ~/ columns, itemCount);
  }

  /// Item occupying layout [slot] — the inverse of [slotOf]. Returns -1
  /// for slots that hold no item (leading phase holes, partial tail
  /// rows), which the sliver renders as empty cells.
  int itemAt(int slot, int itemCount) {
    if (!mirrorRows) return slot - phase;
    final row = slot ~/ columns;
    final (lo, hi) = _rowRange(row, itemCount);
    final item = lo + hi - 1 + phase - slot;
    return item >= lo && item < hi ? item : -1;
  }

  /// Column the item at [index] occupies under [mirrorRows] and [phase].
  int columnOf(int index, int itemCount) => slotOf(index, itemCount) % columns;

  /// Row the item at [index] occupies.
  int rowOf(int index) => (index + phase) ~/ columns;

  /// Total rows needed to lay out [itemCount] items at this density.
  int rowCount(int itemCount) => (itemCount + phase + columns - 1) ~/ columns;

  /// Scroll-content y of [row]'s top edge; [origin] is where the grid sliver
  /// starts in the scroll content.
  double rowTop(int row, double origin) => origin + spacing + row * rowStride;

  /// Row containing scroll-content y [contentY], unclamped.
  int rowAtY(double contentY, double origin) => ((contentY - origin - spacing) / rowStride).floor();

  /// Scroll-content y of the item at [index]'s top edge.
  double tileTop(int index, double origin) => rowTop(rowOf(index), origin);

  /// Scroll-space rect of the item at [index].
  Rect tileRect(int index, double origin, int itemCount) => Rect.fromLTWH(
    spacing + columnOf(index, itemCount) * columnStride,
    rowTop(rowOf(index), origin),
    tileWidth,
    tileHeight,
  );

  /// The item whose tile center is nearest [contentPoint]. Cells capture a
  /// half-stride halo — a point on a seam or in a gap resolves to the closer
  /// tile instead of always the rightward/lower one. Hole slots resolve to
  /// the nearer edge item of their row under [mirrorRows].
  int indexAt(Offset contentPoint, int itemCount, double origin) {
    final row = ((contentPoint.dy - origin - spacing - tileHeight / 2) / rowStride)
        .round()
        .clamp(0, math.max(0, rowCount(itemCount) - 1))
        .toInt();
    final column = ((contentPoint.dx - spacing - tileWidth / 2) / columnStride).round().clamp(0, columns - 1);
    if (!mirrorRows) {
      return (row * columns + column - phase).clamp(0, math.max(0, itemCount - 1)).toInt();
    }
    final item = itemAt(row * columns + column, itemCount);
    if (item >= 0) return item;
    final (lo, hi) = _rowRange(row, itemCount);
    if (hi <= lo) return 0;
    // The run displays mirrored: the column nearest a head hole shows
    // `hi - 1`, the column nearest a tail hole shows `lo`.
    final firstValidColumn = lo + phase - row * columns;
    return column < firstValidColumn ? hi - 1 : lo;
  }
}

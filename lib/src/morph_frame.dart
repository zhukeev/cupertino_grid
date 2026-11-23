import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show immutable;

/// Everything one morph frame paints: every [MorphTile] and [MorphPill]
/// the lattice emits for the current pinch state, back to front, plus the
/// band bounds tiles may draw inside and where the header sits.
@immutable
final class MorphFrame {
  /// Creates a frame. [tiles] must be paint-ordered.
  const MorphFrame({
    required this.tiles,
    required this.pills,
    required this.clipTop,
    required this.clipBottom,
    required this.headerTop,
  });

  /// Tiles to draw this frame, back to front: the under layer (departing
  /// coverage), stable slots (same item in both lattices), then the over
  /// layer (arriving ghosts).
  final List<MorphTile> tiles;

  /// Section pills riding on tiles, per layer.
  final List<MorphPill> pills;

  /// Band bounds: tiles may paint in `clipTop..clipBottom` — under a
  /// reversed scroll axis the header hugs the bottom edge, so the clip
  /// runs `0..clipBottom` there instead of `clipTop..height`.
  final double clipTop;

  /// Band bounds: tiles may paint down to this viewport y.
  final double clipBottom;

  /// Screen y the header's top edge sits at this frame.
  final double headerTop;
}

/// One tile of a morph frame: [index] drawn at [rect].
///
/// [columnOffset]/[rowOffset] is its slot's offset from the focal slot —
/// together with the item that makes the tile's identity, which stays the
/// same across stop boundaries (so no tile remounts or reloads when a
/// pinch crosses a stop). [targetSize] is the emitting stop's tile width
/// in logical pixels — the thumbnail-resolution hint consumers pass to an
/// image builder or decode cache; it is NOT a column count and is never
/// used for layout (that is [rect]'s job). [onNextScreen] is the tile's
/// destination-rectangle gate: whether THIS SLOT lies inside the
/// rectangle the next zoom level's landing screen occupies — the
/// `columns`-wide band of slot offsets landing on the lattice's real
/// columns, times the rest-screen row window. Every op at the slot
/// shares it, so all morphing is confined to that rectangle. [arriving]
/// marks destination-lattice content — the arriving stop's item at this
/// slot — as opposed to departing coverage and same-item stable copies,
/// which stay rigid. Over-layer ghosts always carry it; the under layer
/// also carries it for a rest-keyed arriving carrier (a zoom-in padding
/// slot or a boundary carrier), which only emits when no departing op
/// covers the slot.
typedef MorphTile = ({
  int index,
  int columnOffset,
  int rowOffset,
  Rect rect,
  double opacity,
  int targetSize,
  bool onNextScreen,
  bool arriving,
});

/// A section pill riding on a tile. [layer] 0 belongs to the larger-tile
/// stop, 1 to the denser one (they are spaced independently).
typedef MorphPill = ({int index, int columnOffset, int rowOffset, double top, double opacity, int layer});

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Emission budget: per-frame work must be proportional to the visible
/// slot space, never the collection size. The emitter bounds emitted
/// slots to the union of both lattices' visible offsets plus a one-slot
/// margin, so a 5000-item library emits the same frame shape as a
/// 200-item one — an O(itemCount) regression would emit thousands.
void main() {
  const size = Size(390, 800);
  const origin = 100.0;

  final stops = [
    for (final c in [1, 3, 5]) MorphGridStop(c, 390, spacing: 2, aspect: 1.0),
  ];

  PinchMorph beginAt(int itemCount) {
    final m = PinchMorph()
      ..begin(
        stops: stops,
        startStop: 2,
        focalIndex: 12,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 400),
        startScroll: 300,
        minScroll: 0,
        trailing: 0,
        itemCount: itemCount,
        origin: origin,
        headerOrigin: 0,
        viewport: size,
      );
    addTearDown(m.dispose);
    return m;
  }

  /// Emitted tile count at [level] for the given collection size.
  int emittedAt(PinchMorph m, double level) {
    m.set(level: level);
    return m.frame((_) => false).tiles.length;
  }

  /// Loose geometric bound: the smallest cell anywhere on the ladder is
  /// the 5-column stop's, so the visible slot window can never exceed
  /// this, times the two candidate layers per slot.
  int slotBound(PinchMorph m, double level) {
    m.set(level: level);
    final tile = m.frame((_) => false).tiles.first;
    final visCols = (size.width / tile.rect.width).ceil() + 3;
    final visRows = (size.height / tile.rect.height).ceil() + 3;
    return visCols * visRows * 2;
  }

  const levels = [2.0, 1.7, 1.5, 1.3, 1.0, 0.5, 0.2, 0.0];

  test('tile emission stays within the visible-slot budget at every level', () {
    final m = beginAt(5000);
    for (final level in levels) {
      expect(
        emittedAt(m, level),
        lessThanOrEqualTo(slotBound(m, level)),
        reason: 'level $level emitted more tiles than the visible slot space allows',
      );
    }
  });

  test('emission is independent of collection size', () {
    final small = beginAt(200);
    final large = beginAt(5000);
    for (final level in levels) {
      final s = emittedAt(small, level);
      final l = emittedAt(large, level);
      // More items can only add slots (short content leaves some slot
      // space unemitted); they can never make the frame cheaper.
      expect(l, greaterThanOrEqualTo(s), reason: 'level $level: a larger collection emitted fewer tiles ($l < $s)');
      // …and the growth is bounded by end-of-content effects, not by a
      // per-item scan: same viewport, same lattice geometry.
      expect(
        l - s,
        lessThanOrEqualTo(2 * stops.last.columns),
        reason: 'level $level: +${l - s} tiles for +4800 items — emission tracks itemCount',
      );
    }
  });

  test('visibleIndices never exceeds the emitted set', () {
    final m = beginAt(5000);
    for (final level in levels) {
      m.set(level: level);
      final frame = m.frame((_) => false);
      expect(
        m.visibleIndices.length,
        lessThanOrEqualTo(math.max(1, frame.tiles.length)),
        reason: 'level $level requests more images than it paints',
      );
    }
  });
}

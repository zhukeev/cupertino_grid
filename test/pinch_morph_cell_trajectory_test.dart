import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Per-cell trajectories: while the fingers are down (`pin == 1`) every
/// emitted tile rides ONE shared rigid band —
/// `left − columnOffset·strideX` identical for all — and the band is
/// anchored by where the pinched cell sits: a bezel cell pins the
/// screen edge it rests on, an interior cell rides a uniform scale of
/// the parked grid about the viewport's horizontal centre. An interior
/// pinch produces exactly the motion a centre-image pinch does: column
/// edges stay equally clipped on both bezels at every level.
///
/// The regressions this guards: anchoring the band on the focal's
/// rest-position glide translated the whole lattice sideways toward the
/// landing column mid-gesture (the "lean" — a side landing dragged the
/// grid laterally); pivoting an interior focal on its own pinch-start
/// position held the photo in place but left the band off centre, so an
/// off-centre pinch clipped one bezel deeper than the other (the
/// one-sided padding); scaling a bezel focal about the centre instead
/// pulled its photo off the screen edge mid-gesture.
void main() {
  const size = Size(390, 800);
  const count = 709;
  const origin = 100.0;
  const trailing = 120.0;
  const spacing = 2.0;

  PinchMorph begin({required List<MorphGridStop> stops, required int focalIndex, required int startStop}) =>
      PinchMorph()..begin(
        stops: stops,
        startStop: startStop,
        focalIndex: focalIndex,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 400),
        startScroll: 0,
        minScroll: 0,
        trailing: trailing,
        itemCount: count,
        origin: origin,
        headerOrigin: 0,
        viewport: size,
        reversed: true,
        phase: 0,
        centerFocal: true,
      );

  void checkFrame(PinchMorph morph, int focalIndex, double level, int startStop) {
    final frame = morph.frame((i) => false);
    final lowerStop = math.min(level.floor(), morph.stops.length - 2);
    final larger = morph.stops[lowerStop];
    final denser = morph.stops[lowerStop + 1];
    final progress = level - lowerStop;
    final cellWidth = progress == 0
        ? larger.tileWidth
        : math.exp(lerpDouble(math.log(larger.tileWidth), math.log(denser.tileWidth), progress)!);
    final strideX = cellWidth + larger.spacing;
    String where(double level) => 'focal=$focalIndex level=${level.toStringAsFixed(2)}';

    // Every emitted tile rides ONE shared rigid band — the band anchor
    // `left − columnOffset·strideX` must be identical for all of them.
    double? anchor;
    for (final tile in frame.tiles) {
      final a = tile.rect.left - tile.columnOffset * strideX;
      if (anchor == null) {
        anchor = a;
        continue;
      }
      expect(
        (a - anchor).abs(),
        lessThan(0.01),
        reason:
            '${where(level)} item=${tile.index}: tile dragged off the shared '
            'band anchor ${anchor.toStringAsFixed(2)} (rides ${a.toStringAsFixed(2)}) — '
            'a cell is moving independently of the rigid lattice',
      );
    }
    expect(anchor, isNotNull, reason: '${where(level)}: no tiles emitted');

    // The focal tile always emits — a centre-scaled interior focal
    // legitimately slides past a bezel mid-gesture, but its slot stays
    // in the frame so position reads never lose it.
    var seen = false;
    for (final tile in frame.tiles) {
      if (tile.index == focalIndex && tile.rowOffset == 0 && tile.columnOffset == 0) {
        seen = true;
      }
    }
    expect(seen, isTrue, reason: '${where(level)}: focal tile culled');

    // The band anchor itself must be the focal slot's live left: a cell
    // resting on ONE bezel pins that screen edge; every other cell —
    // interior, or one spanning BOTH bezels (the 1-col stop, which has
    // no edge to hug) — rides its parked left scaled about the viewport
    // centre, the same motion a centre pinch produces.
    final start = morph.stops[startStop].tileRect(focalIndex, origin, count);
    final leftBezel = start.left <= spacing + 0.5;
    final rightBezel = start.right >= size.width - spacing - 0.5;
    final expected = leftBezel != rightBezel
        ? leftBezel
              ? start.left
              : start.right - cellWidth
        : size.width / 2 + (start.left - size.width / 2) * cellWidth / start.width;
    expect(
      anchor,
      closeTo(expected, 0.6),
      reason:
          '${where(level)}: band anchor emitted at ${anchor!.toStringAsFixed(2)}, '
          'live position is ${expected.toStringAsFixed(2)} — the band is '
          'off its anchor contract',
    );
  }

  test('every cell rides the shared band through the whole zoom-in', () {
    for (final mirrored in [false, true]) {
      final stops = [
        for (final c in [1, 3, 5, 16])
          MorphGridStop(c, size.width, spacing: spacing, aspect: 1.0, mirrorRows: mirrored),
      ];
      // One full 16-column row of focals — every landing column is covered.
      for (var focalIndex = 96; focalIndex < 112; focalIndex++) {
        final morph = begin(stops: stops, focalIndex: focalIndex, startStop: 3);
        addTearDown(morph.dispose);
        for (final level in [2.95, 2.8, 2.6, 2.4, 2.2, 2.05, 1.9, 1.7, 1.5, 1.3, 1.1]) {
          morph.set(level: level, overscale: 1, pin: 1);
          checkFrame(morph, focalIndex, level, 3);
        }
      }
    }
  });

  test('every cell rides the shared band through the whole zoom-out', () {
    for (final mirrored in [false, true]) {
      final stops = [
        for (final c in [1, 3, 5, 16])
          MorphGridStop(c, size.width, spacing: spacing, aspect: 1.0, mirrorRows: mirrored),
      ];
      // Same row of focals, pinch rooted at the sparsest stop — every
      // landing column of the densest stop is covered.
      for (var focalIndex = 96; focalIndex < 112; focalIndex++) {
        final morph = begin(stops: stops, focalIndex: focalIndex, startStop: 0);
        addTearDown(morph.dispose);
        for (final level in [0.05, 0.2, 0.4, 0.6, 0.8, 0.95, 1.1, 1.3, 1.5, 1.7, 1.9, 2.1, 2.4, 2.7]) {
          morph.set(level: level, overscale: 1, pin: 1);
          checkFrame(morph, focalIndex, level, 0);
        }
      }
    }
  });
}

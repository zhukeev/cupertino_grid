import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Focal edge-clamp contract. While the fingers are down (`pin == 1`) the
/// focal cell's top is clamped into
/// `[min(clipTop, startTop), max(bandBottom, startBottom) - cellHeight]`:
/// a cell already clipped at pinch start may drift back toward the band
/// (iOS's "come close to the focal image") but can never be pushed
/// *further* off-screen than where the pinch found it — and a cell that
/// started fully inside the band can never be pushed off it at all.
/// The fuzz harness measures this as the intentionally-large p99 drift;
/// these tests pin the underlying guarantee.
void main() {
  const size = Size(390, 800);
  const count = 709;
  const origin = 100.0;

  final stops = [
    for (final c in [1, 3, 5]) MorphGridStop(c, 390, spacing: 2, aspect: 1.0),
  ];

  Rect focalRect(PinchMorph m, int index) {
    final tile = m
        .frame((_) => false)
        .tiles
        .firstWhere((t) => t.index == index && t.columnOffset == 0 && t.rowOffset == 0);
    return tile.rect;
  }

  PinchMorph beginAt({
    required int startStop,
    required int focalIndex,
    required Offset focalFraction,
    required double startScroll,
    required double clipTop,
  }) {
    // Consistent gesture geometry: the focal point is the stamped cell
    // rect's fractional position on screen at pinch start.
    final start = stops[startStop].tileRect(focalIndex, origin, count).translate(0, -startScroll);
    final point = start.topLeft + Offset(focalFraction.dx * start.width, focalFraction.dy * start.height);
    final m = PinchMorph()
      ..begin(
        stops: stops,
        startStop: startStop,
        focalIndex: focalIndex,
        focalFraction: focalFraction,
        focalPoint: point,
        startScroll: startScroll,
        minScroll: 0,
        trailing: 0,
        itemCount: count,
        origin: origin,
        headerOrigin: origin - clipTop,
        viewport: size,
      );
    addTearDown(m.dispose);
    return m;
  }

  test('a top-clipped focal cell is never pushed further off the band top', () {
    // clipTop = max(0, origin - startScroll) = 0; focal row 2 sits with
    // its top ~43px above the band at pinch start.
    final m = beginAt(
      startStop: 2,
      focalIndex: 12,
      focalFraction: const Offset(0.5, 0.75),
      startScroll: 300,
      clipTop: 0,
    );
    final startTop = focalRect(m, 12).top;
    expect(startTop, lessThan(0)); // clipped at pinch start

    for (final level in [1.8, 1.4, 1.0, 0.6, 0.2, 0.0]) {
      m.set(level: level);
      final top = focalRect(m, 12).top;
      expect(
        top,
        greaterThanOrEqualTo(startTop - 1e-6),
        reason: 'level $level pushed the cell further off the top than pinch start',
      );
    }

    // Zoomed all the way in the unclamped anchor would sit hundreds of px
    // above the band — the clamp binds exactly to the pinch-start clip.
    expect(focalRect(m, 12).top, closeTo(startTop, 1e-6));
  });

  test('a bottom-clipped focal cell is never pushed further off the band bottom', () {
    // clipTop = 50, band bottom = 800; focal row 9's bottom extends past
    // the band at pinch start.
    final m = beginAt(
      startStop: 2,
      focalIndex: 47,
      focalFraction: const Offset(0.5, 0.5),
      startScroll: 50,
      clipTop: 50,
    );
    final start = focalRect(m, 47);
    expect(start.bottom, greaterThan(800)); // clipped at pinch start

    for (final level in [1.8, 1.4, 1.0, 0.6, 0.2, 0.0]) {
      m.set(level: level);
      final bottom = focalRect(m, 47).bottom;
      expect(
        bottom,
        lessThanOrEqualTo(start.bottom + 1e-6),
        reason: 'level $level pushed the cell further off the bottom than pinch start',
      );
    }

    expect(focalRect(m, 47).bottom, closeTo(start.bottom, 1e-6));
  });

  test('a fully-visible focal cell hugging the band top is never pushed off', () {
    // clipTop = 0; focal row 0's top sits ~2px inside the band — fully
    // visible but with no headroom, so zooming would drag it off without
    // the clamp.
    final m = beginAt(startStop: 2, focalIndex: 2, focalFraction: const Offset(0.5, 0.3), startScroll: 100, clipTop: 0);
    final startTop = focalRect(m, 2).top;
    expect(startTop, greaterThanOrEqualTo(0));
    expect(startTop, lessThan(10)); // ~no headroom

    for (final level in [1.8, 1.4, 1.0, 0.6, 0.2, 0.0]) {
      m.set(level: level);
      final rect = focalRect(m, 2);
      expect(
        rect.top,
        greaterThanOrEqualTo(-1e-6),
        reason: 'level $level clipped a cell that was fully visible at pinch start',
      );
      expect(rect.bottom, lessThanOrEqualTo(800 + 1e-6));
    }
  });
}

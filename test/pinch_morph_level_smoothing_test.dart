import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// The pinch-level low-pass: interleaved per-finger move events jitter the
/// raw span sub-pixel — invisible on the cell-size curve, but inside the
/// reflow window it lands on an amplified slope and the lattice lurches a
/// few pixels at random (the "wobbling" regression). [PinchMorph.trackLevel]
/// filters the gesture path while the settle still writes [PinchMorph.set]
/// directly.
void main() {
  const size = Size(390, 800);
  const count = 709;
  const spacing = 2.0;

  List<MorphGridStop> stops() => [
    for (final c in [1, 3, 5, 16]) MorphGridStop(c, size.width, spacing: spacing, aspect: 1.0),
  ];

  PinchMorph begin() => PinchMorph()
    ..begin(
      stops: stops(),
      startStop: 1,
      focalIndex: 200,
      focalFraction: const Offset(0.5, 0.5),
      focalPoint: const Offset(195, 400),
      startScroll: 300,
      minScroll: 0,
      trailing: 120,
      itemCount: count,
      origin: 100,
      headerOrigin: 0,
      viewport: size,
    );

  test('trackLevel filters per-event jitter; first sample snaps', () {
    final m = begin();
    addTearDown(m.dispose);
    // First sample has no event-clock delta — it must snap, not lag.
    m.trackLevel(1.4);
    expect(m.level, 1.4);
    // Alternating ±0.03 jitter on a slow ramp at ~120 Hz event rate.
    var prev = m.level;
    var maxStep = 0.0;
    for (var i = 1; i <= 30; i++) {
      final raw = 1.4 + i * 0.005 + (i.isEven ? 0.03 : -0.03);
      m.trackLevel(raw, dtSeconds: 0.008);
      maxStep = math.max(maxStep, (m.level - prev).abs());
      prev = m.level;
    }
    // Raw samples jump 0.05+ per event; the filter must cut that ~4×.
    expect(maxStep, lessThan(0.015));
  });

  test('trackLevel converges on a held level (no steady-state lag)', () {
    final m = begin();
    addTearDown(m.dispose);
    m.trackLevel(1.6);
    for (var i = 0; i < 40; i++) {
      m.trackLevel(1.6, dtSeconds: 0.008);
    }
    expect(m.level, closeTo(1.6, 1e-9));
  });

  test('levelSmoothing = 0 disables the filter', () {
    final m = PinchMorph(style: const PinchMorphStyle(levelSmoothing: 0))
      ..begin(
        stops: stops(),
        startStop: 1,
        focalIndex: 200,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 400),
        startScroll: 300,
        minScroll: 0,
        trailing: 120,
        itemCount: count,
        origin: 100,
        headerOrigin: 0,
        viewport: size,
      );
    addTearDown(m.dispose);
    m.trackLevel(1.4, dtSeconds: 0.008);
    m.trackLevel(1.35, dtSeconds: 0.008);
    expect(m.level, 1.35);
  });
}

import 'package:material_ui/material_ui.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

List<MorphGridStop> _ladder(double width, [List<int> columns = const [1, 3, 5]]) => [
  for (final c in columns) MorphGridStop(c, width, spacing: 2, aspect: 1),
];

PinchMorph _begunMorph({bool reversed = false, double level = 1.5}) {
  final morph = PinchMorph()
    ..begin(
      stops: _ladder(390),
      startStop: 1,
      focalIndex: 12,
      focalFraction: const Offset(0.5, 0.5),
      focalPoint: const Offset(200, 400),
      startScroll: 100,
      minScroll: 0,
      trailing: 400,
      itemCount: 60,
      origin: 50,
      headerOrigin: 20,
      viewport: const Size(390, 800),
      reversed: reversed,
    )
    ..set(level: level);
  addTearDown(morph.dispose);
  return morph;
}

void main() {
  group('PinchMorph.reframe', () {
    test('keeps level and phases while re-deriving viewport geometry', () {
      final morph = _begunMorph();
      final before = morph.restScrolls[0];

      morph.reframe(viewport: const Size(500, 900), stops: _ladder(500), minScroll: 0, trailing: 500);

      // Gesture state survives; ladder-dependent metrics re-derive.
      expect(morph.level, 1.5);
      expect(morph.startStop, 1);
      expect(morph.settleStop, 1);
      expect(morph.viewport, const Size(500, 900));
      expect(morph.stops[0].tileWidth, isNot(_ladder(390)[0].tileWidth));
      // The new extent changes the trailing clamp on rest scrolls.
      expect(morph.restScrolls[0], isNot(before));
      // Still emits a valid frame at the same level.
      expect(morph.frame((_) => false).tiles, isNotEmpty);
    });

    test('re-mirrors the focal point about the new height on a reversed axis', () {
      final morph = _begunMorph(reversed: true);
      // begin mirrored the touch: 800 − 400 = 400.
      expect(morph.focalPoint.dy, 400);

      morph.reframe(viewport: const Size(390, 1000), stops: _ladder(390), minScroll: 0, trailing: 400);

      expect(morph.focalPoint.dy, 600);
    });

    test('remaps indices and level when the ladder itself changes', () {
      final morph = _begunMorph();
      // A resize into a different density ladder — no shared column counts
      // except the 1-column stop: 3→4 and 5→6 remap to the nearest columns.
      morph.reframe(viewport: const Size(700, 800), stops: _ladder(700, [1, 4, 6]), minScroll: 0, trailing: 400);

      expect(morph.stops.map((s) => s.columns), [1, 4, 6]);
      expect(morph.startStop, 1); // nearest to the old 3-column stop
      // level 1.5 between old stops 1 and 2 remaps between new stops 1 and 2.
      expect(morph.level, 1.5);
      expect(morph.frame((_) => false).tiles, isNotEmpty);
    });

    test('preserves stamped phases on matching column counts', () {
      final morph = PinchMorph()
        ..begin(
          stops: _ladder(390),
          startStop: 1,
          focalIndex: 12,
          focalFraction: const Offset(0.5, 0.5),
          focalPoint: const Offset(200, 400),
          startScroll: 100,
          minScroll: 0,
          trailing: 400,
          itemCount: 60,
          origin: 50,
          headerOrigin: 20,
          viewport: const Size(390, 800),
          centerFocal: true,
        )
        ..set(level: 0.5);
      addTearDown(morph.dispose);
      final phases = [for (final s in morph.stops) s.phase];

      morph.reframe(viewport: const Size(500, 800), stops: _ladder(500), minScroll: 0, trailing: 400);

      expect([for (final s in morph.stops) s.phase], phases);
    });
  });
}

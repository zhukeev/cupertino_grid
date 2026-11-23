import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Landing phases: [PinchMorph.begin] stamps each non-start stop's leading
/// empty slots so the pinched photo lands on the column nearest its start
/// column. Under [MorphGridStop.mirrorRows] a partial row flips inside its
/// OCCUPIED slots — the displayed column is row-relative and moves with the
/// phase, so no closed form maps target → phase. A 5-photo gallery pinching
/// 5→16 is the concrete regression: the leftmost-displayed photo departed
/// column 0 and must land column 1, not column 11.
void main() {
  const size = Size(390, 800);

  PinchMorph begin({required int focalIndex, int itemCount = 5}) {
    final morph = PinchMorph()
      ..begin(
        stops: [
          for (final c in [3, 5, 16]) MorphGridStop(c, size.width, spacing: 2, aspect: 1.0, mirrorRows: true),
        ],
        startStop: 1,
        focalIndex: focalIndex,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 400),
        startScroll: 0,
        minScroll: 0,
        trailing: 0,
        itemCount: itemCount,
        origin: 0,
        headerOrigin: 0,
        viewport: size,
        reversed: true,
        phase: 0,
        centerFocal: true,
      );
    addTearDown(morph.dispose);
    return morph;
  }

  test('mirrored partial row keeps the leftmost photo on the left', () {
    // Item 4 displays leftmost at 5 columns (mirrored order) — pinching it
    // to 16 columns must land it on column 1, the column nearest its start
    // column, which a mirrored partial row reaches with phase 1. The old
    // closed form clamped the target by items-after-focal (0) and derived
    // phase 11 — the photo materialised at column 11, mid-screen.
    final morph = begin(focalIndex: 4);
    expect(morph.stops[2].columnOf(4, 5), 1);
  });

  test('mirrored partial row keeps the rightmost photo on the right', () {
    // Item 0 displays rightmost at 5 columns (column 4) — its nearest
    // landing column at 16 is 14, reachable at phase 10. The old form
    // clamped to column 4 and emitted phase 11, landing it on column 15.
    final morph = begin(focalIndex: 0);
    expect(morph.stops[2].columnOf(0, 5), 14);
  });

  test('mirrored partial row keeps a middle photo middle', () {
    // Item 2 sits at column 2 — the nearest landing column at 16 is 8
    // (phase 6), matching the keep-position rule every interior cell obeys.
    final morph = begin(focalIndex: 2);
    expect(morph.stops[2].columnOf(2, 5), 8);
  });
}

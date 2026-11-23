import 'package:material_ui/material_ui.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

void main() {
  test('reflow enters and exits with near-zero boundary motion', () {
    const viewport = Size(390, 844);
    final startStop = MorphGridStop(3, 390, spacing: 2, aspect: 1);
    final morph = PinchMorph()
      ..begin(
        stops: [startStop, MorphGridStop(5, 390, spacing: 2, aspect: 1)],
        startStop: 0,
        focalIndex: 50,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 422),
        // A real gesture parks the focal under the finger — scroll 0 would
        // leave row 16 two screens below the band and emit nothing.
        startScroll: startStop.tileTop(50, 0) + 0.5 * startStop.tileHeight - 422,
        minScroll: 0,
        trailing: 0,
        itemCount: 120,
        origin: 0,
        headerOrigin: 0,
        viewport: viewport,
      );

    addTearDown(morph.dispose);

    MorphTile tileAt(double level) {
      morph.set(level: level);
      // The focal slot is emitted exactly once — items may double-emit at
      // two slot offsets (departing at one, arriving at another), so an
      // index-keyed lookup is ambiguous.
      return morph.frame((_) => false).tiles.firstWhere((tile) => tile.columnOffset == 0 && tile.rowOffset == 0);
    }

    // The default reflow window is [0.375, 0.625]. A quintic
    // smootherstep has zero first and second derivatives at both edges,
    // so a nearby frame must not JUMP this tile — a re-column snap would
    // shift it by a column stride (~77px at 5 columns). The bound sits
    // far below that while allowing the column glide's legitimate
    // mid-flight velocity (the emitted band anchors on the focal slot's
    // rest-position glide, which is still easing through the early
    // reflowX window here).
    final start = tileAt(0.375);
    final nearStart = tileAt(0.38);
    final nearEnd = tileAt(0.62);
    final end = tileAt(0.625);

    expect((nearStart.rect.center - start.rect.center).distance, lessThan(12.0));
    expect((end.rect.center - nearEnd.rect.center).distance, lessThan(12.0));
  });
}

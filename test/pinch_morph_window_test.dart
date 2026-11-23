import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Next-viewport gating: during a pinch a slot may swap its photo only
/// when the item the arriving layer would paint lands inside the
/// destination stop's rest viewport — checked on the item's own
/// destination row (the helical wrap can sit a slot one row off its
/// item's row). Horizontally nothing is gated: the destination viewport
/// shows every column edge to edge, so a pinch on a side cell morphs
/// exactly like a pinch on the middle one. A slot outside that window
/// keeps showing the departing photo instead of materializing a ghost
/// the destination screen doesn't have.
void main() {
  const size = Size(390, 800);
  const count = 709;
  const origin = 100.0;

  test('reflow window scales with the interval density jump', () {
    // Unequal log steps: 1↔3 spans more log width than the ladder
    // average, 3↔5 spans less — so the reflow window opens earlier on
    // the big jump and later on the small one. Distinct aspects per stop
    // make the reflow blend observable as the emitted tile's aspect.
    final adaptive = [
      MorphGridStop(1, 390, spacing: 2, aspect: 1.0),
      MorphGridStop(3, 390, spacing: 2, aspect: 1.6),
      MorphGridStop(5, 390, spacing: 2, aspect: 2.2),
    ];
    final m = PinchMorph()
      ..begin(
        stops: adaptive,
        startStop: 0,
        focalIndex: 40,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 400),
        startScroll: 300,
        minScroll: 0,
        trailing: 0,
        itemCount: count,
        origin: origin,
        headerOrigin: 0,
        viewport: size,
      );
    addTearDown(m.dispose);

    double aspectAt(double level) {
      m.set(level: level);
      final tile = m.frame((_) => false).tiles.first;
      return tile.rect.height / tile.rect.width;
    }

    // Interval 0→1 (1↔3, ~1.36× the average step): the window opens at
    // ~0.33, so at 0.34 the aspect blend has already left the sparse
    // stop — a fixed 0.25 window would still be exactly 1.0.
    expect(aspectAt(0.34), greaterThan(1.0));
    // Interval 1→2 (3↔5, ~0.64× the average): the window doesn't open
    // until ~0.42, so at 0.40 the aspect is still exactly the departing
    // stop's — a fixed window would already be blending.
    expect(aspectAt(1.40), closeTo(1.6, 0.0001));
  });

  test('a widened position window does not pull the photo swap earlier', () {
    // Regression: the adaptive reflow window drives tile POSITIONS only.
    // Photo content swaps on style.reflowWindow — a widened position
    // window must not bleed the arriving photo in early (the "images
    // replaced mid-gesture" artifact the next-screen gating fixed).
    // 5→16 is the app's biggest jump: adaptive window ~0.32 vs style
    // 0.25, so the swap must still wait for progress ≈0.375.
    final bigJump = [
      for (final c in [1, 3, 5, 16]) MorphGridStop(c, 390, spacing: 2, aspect: 1.0),
    ];
    const scroll = 300.0;
    const focal = Offset(195, 400);
    final s0 = bigJump[2];
    final fi = s0.indexAt(focal + const Offset(0, scroll), count, origin);
    final fr = s0.tileRect(fi, origin, count).shift(const Offset(0, -scroll));
    final m = PinchMorph()
      ..begin(
        stops: bigJump,
        startStop: 2,
        focalIndex: fi,
        focalFraction: Offset((focal.dx - fr.left) / fr.width, (focal.dy - fr.top) / fr.height),
        focalPoint: focal,
        startScroll: scroll,
        minScroll: 0,
        trailing: 0,
        itemCount: count,
        origin: origin,
        headerOrigin: 0,
        viewport: size,
      );
    addTearDown(m.dispose);

    // Zoom-out toward 16 — interval 2→3, the ladder's biggest jump: a
    // slot emitting two different item indices is a swap in progress —
    // the arriving ghost only exists once crossfade leaves 0, which the
    // style window gates to progress >0.375.
    int swappingSlots(double progress) {
      m.set(level: 2 + progress);
      final bySlot = <String, Set<int>>{};
      for (final tile in m.frame((_) => false).tiles) {
        bySlot.putIfAbsent('${tile.columnOffset}|${tile.rowOffset}', () => {}).add(tile.index);
      }
      return bySlot.values.where((items) => items.length > 1).length;
    }

    expect(swappingSlots(0.20), 0);
    expect(swappingSlots(0.36), 0);
    expect(swappingSlots(0.55), greaterThan(0));
  });

  final stops = [
    for (final c in [1, 3, 5]) MorphGridStop(c, 390, spacing: 2, aspect: c == 1 ? 4 / 3 : 1.0, showsLabels: c >= 7),
  ];

  /// Sweeps the zoomIn/zoomOut interval between stops [a] and [b] and
  /// asserts every tile emitted at an off-next-screen slot offset shows
  /// the departing stop's photo (never an arriving swap), while at
  /// least one on-next slot does swap items.
  void checkWindow({
    required int start,
    required int lower,
    required MorphGridStop dest,
    required MorphGridStop depart,
    required bool zoomIn,
  }) {
    const scroll = 300.0;
    const focal = Offset(195, 400);
    final s0 = stops[start];
    final fi = s0.indexAt(focal + const Offset(0, scroll), count, origin);
    final fr = s0.tileRect(fi, origin, count).shift(const Offset(0, -scroll));
    final m = PinchMorph()
      ..begin(
        stops: stops,
        startStop: start,
        focalIndex: fi,
        focalFraction: Offset((focal.dx - fr.left) / fr.width, (focal.dy - fr.top) / fr.height),
        focalPoint: focal,
        startScroll: scroll,
        minScroll: 0,
        trailing: 0,
        itemCount: count,
        origin: origin,
        headerOrigin: 0,
        viewport: size,
      );

    // A slot is off the next screen when its slot offset lands outside
    // the destination screen's own rectangle — the `columns`-wide band
    // of offsets landing on real lattice columns, times the rest-screen
    // row window (the emitter resolves items linearly, so wrapped
    // column offsets reach neighbouring rows' items — the rectangle is
    // measured on the SLOT's destination coordinates, not the item's).
    // Zoom-out keeps an extra escape: slots whose departing photo wasn't
    // on the start screen slide in as new territory and may materialise
    // their arriving copy regardless of the window.
    final destFocalRow = dest.rowOf(fi);
    final destFocalColumn = dest.columnOf(fi, count);
    final windowTop = dest.rowAtY(m.restScrolls[zoomIn ? lower : lower + 1], origin);
    final windowBottom = dest.rowAtY(m.restScrolls[zoomIn ? lower : lower + 1] + size.height, origin);
    final startStop = m.stops[start];
    final startFocalRow = startStop.rowOf(fi);
    final startFocalTop = startStop.rowTop(startFocalRow, origin) - scroll;
    final startVisibleTop = startFocalRow - (startFocalTop / startStop.rowStride).ceil();
    final startVisibleBottom = startFocalRow + ((size.height - startFocalTop) / startStop.rowStride).floor();
    bool wasOnStartScreen(int index) =>
        index >= 0 && startStop.rowOf(index) >= startVisibleTop && startStop.rowOf(index) <= startVisibleBottom;
    final departFocalColumn = depart.columnOf(fi, count);
    final departFocalRow = depart.rowOf(fi);
    int departingItem(int columnOffset, int rowOffset) =>
        depart.itemAt((departFocalRow + rowOffset) * depart.columns + departFocalColumn + columnOffset, count);
    bool offNext(int columnOffset, int rowOffset) {
      final inRect =
          (destFocalColumn + columnOffset) >= 0 &&
          (destFocalColumn + columnOffset) < dest.columns &&
          (destFocalRow + rowOffset) >= windowTop &&
          (destFocalRow + rowOffset) <= windowBottom;
      return !inRect && (zoomIn || wasOnStartScreen(departingItem(columnOffset, rowOffset)));
    }

    // Sweep essentially the whole traverse: only the boundary bands
    // (the last ~3% each side) may carry arriving content so a frame
    // just past a stop keys the same rest tiles as the stop itself.
    // Everywhere else an off-screen slot must show the departing photo.
    final itemsPerOffNextSlot = <String, Set<int>>{};
    final itemsPerOnNextSlot = <String, Set<int>>{};
    for (var level = lower + 0.04; level <= lower + 0.96; level += 0.04) {
      m.set(level: level);
      for (final t in m.frame((i) => false).tiles) {
        if (t.opacity < 0.5) continue;
        final slot = '${t.columnOffset}|${t.rowOffset}';
        (offNext(t.columnOffset, t.rowOffset) ? itemsPerOffNextSlot : itemsPerOnNextSlot)
            .putIfAbsent(slot, () => {})
            .add(t.index);
      }
    }

    var exercised = 0;
    for (final e in itemsPerOffNextSlot.entries) {
      final parts = e.key.split('|');
      final dc = int.parse(parts[0]);
      final dr = int.parse(parts[1]);
      final expected = departingItem(dc, dr);
      exercised++;
      expect(e.value.length, 1, reason: 'off-next slot $e.key swapped photos to ${e.value} (departing item $expected)');
      expect(e.value.single, expected, reason: 'off-next slot $e.key does not show the departing photo');
    }
    expect(exercised, greaterThan(0), reason: 'no off-next slots emitted during the sweep');
    expect(
      itemsPerOnNextSlot.values.any((items) => items.length > 1),
      isTrue,
      reason: 'no on-next slot swapped photos — the morph did not run',
    );
  }

  test('zoom-in 5->3: slots outside the 3-column screen keep the 5-column photo', () {
    checkWindow(start: 2, lower: 1, dest: stops[1], depart: stops[2], zoomIn: true);
  });

  test('zoom-out 3->5: slots outside the 5-column screen keep the 3-column photo', () {
    checkWindow(start: 1, lower: 1, dest: stops[2], depart: stops[1], zoomIn: false);
  });
}

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// The "next smaller zoom" viewport: while a pinch travels toward a denser
/// stop, only slots whose destination lands inside that stop's rest
/// viewport may swap their photo — every other cell keeps the departing
/// image until the commit. Two halves under test: the window math itself
/// (which rows the denser grid shows at `restScrolls[k]` — the focal row
/// plus the row strides fitting above and below its rest screen top) and
/// the emission gate that honors it mid-gesture — under the gallery's
/// real axis (reversed + mirrored rows + centred landings + trailing
/// footer), not just the plain forward ladder.
void main() {
  const size = Size(390, 800);
  const count = 709;
  const origin = 100.0;
  const trailing = 120.0;

  PinchMorph begin({
    required List<MorphGridStop> stops,
    required int start,
    required int focalIndex,
    required double scroll,
    int itemCount = count,
    bool reversed = false,
    bool centerFocal = false,
    int phase = 0,
    Offset focalPoint = const Offset(195, 400),
  }) => PinchMorph()
    ..begin(
      stops: stops,
      startStop: start,
      focalIndex: focalIndex,
      focalFraction: const Offset(0.5, 0.5),
      focalPoint: focalPoint,
      startScroll: scroll,
      minScroll: 0,
      trailing: trailing,
      itemCount: itemCount,
      origin: origin,
      headerOrigin: 0,
      viewport: size,
      reversed: reversed,
      phase: phase,
      centerFocal: centerFocal,
    );

  group('rest-viewport window', () {
    // The window [winTop, winBot] the emitter derives for a denser stop —
    // the focal row minus the row strides fitting above its rest screen
    // top, plus those fitting below — must bracket exactly the rows that
    // stop's grid shows at its rest scroll: every visible row inside, no
    // phantom rows outside. A systematic offset (wrong edge, wrong axis,
    // off-by-one row) leaves arriving photos materialising on slots the
    // land never shows.
    void checkWindowBracketsViewport({required bool mirrored, required bool reversed, required bool centered}) {
      final stops = [
        for (final c in [1, 3, 5, 16]) MorphGridStop(c, size.width, spacing: 2, aspect: 1.0, mirrorRows: mirrored),
      ];
      for (final start in [0, 1, 2]) {
        final s0 = stops[start];
        final maxScroll = math.max(0.0, s0.rowTop(s0.rowCount(count), origin) + trailing - size.height);
        for (final focalIndex in [0, 5, 40, 200, count - 1]) {
          for (final scroll in [0.0, 300.0, maxScroll]) {
            final m = begin(
              stops: stops,
              start: start,
              focalIndex: focalIndex,
              scroll: scroll,
              reversed: reversed,
              centerFocal: centered,
            );
            addTearDown(m.dispose);
            for (var k = start + 1; k < stops.length; k++) {
              final dest = m.stops[k];
              final rest = m.restScrolls[k];
              final winTop = dest.rowAtY(rest, origin);
              final winBot = dest.rowAtY(rest + size.height, origin);
              // Rows whose rest screen-rect intersects the viewport. Under
              // a reversed axis scroll-space [rest, rest + height] maps to
              // the same screen band upside-down — the interval is the
              // same either way.
              var minVisible = 1 << 30;
              var maxVisible = -1;
              for (var row = 0; row < dest.rowCount(count); row++) {
                final top = dest.rowTop(row, origin);
                final bottom = dest.rowTop(row + 1, origin) - dest.spacing;
                final visible = bottom > rest && top < rest + size.height;
                if (visible) {
                  minVisible = math.min(minVisible, row);
                  maxVisible = math.max(maxVisible, row);
                }
              }
              if (maxVisible >= 0) {
                expect(
                  winTop,
                  lessThanOrEqualTo(minVisible),
                  reason:
                      'mirrored=$mirrored reversed=$reversed centered=$centered '
                      'start=$start k=$k f=$focalIndex sc=$scroll: winTop $winTop misses visible row $minVisible',
                );
                expect(
                  winBot,
                  greaterThanOrEqualTo(maxVisible),
                  reason:
                      'mirrored=$mirrored reversed=$reversed centered=$centered '
                      'start=$start k=$k f=$focalIndex sc=$scroll: winBot $winBot misses visible row $maxVisible',
                );
                // Overhang into phantom space (negative rows above the
                // grid origin, rows past the content end) is harmless —
                // no slot there can hold an item — so the exactness
                // bound applies over real rows only.
                final lastRow = dest.rowCount(count) - 1;
                if (winTop >= 0) {
                  expect(
                    winTop,
                    greaterThanOrEqualTo(minVisible - 2),
                    reason:
                        'mirrored=$mirrored reversed=$reversed centered=$centered '
                        'start=$start k=$k f=$focalIndex sc=$scroll: winTop $winTop hangs $minVisible-real-rows out',
                  );
                }
                if (winBot <= lastRow) {
                  expect(
                    winBot,
                    lessThanOrEqualTo(maxVisible + 2),
                    reason:
                        'mirrored=$mirrored reversed=$reversed centered=$centered '
                        'start=$start k=$k f=$focalIndex sc=$scroll: winBot $winBot hangs past $maxVisible',
                  );
                }
              }
            }
          }
        }
      }
    }

    test('brackets the denser rest viewport — plain ladder', () {
      checkWindowBracketsViewport(mirrored: false, reversed: false, centered: false);
    });
    test('brackets the denser rest viewport — reversed axis', () {
      checkWindowBracketsViewport(mirrored: false, reversed: true, centered: false);
    });
    test('brackets the denser rest viewport — production axis', () {
      checkWindowBracketsViewport(mirrored: true, reversed: true, centered: true);
    });
    test('brackets the denser rest viewport — underfilled content', () {
      // Fewer items than a screen of denser rows: the window covers the
      // whole rest layout, so nothing may be excluded from the swap.
      final stops = [
        for (final c in [1, 3, 5, 16]) MorphGridStop(c, size.width, spacing: 2, aspect: 1.0, mirrorRows: true),
      ];
      const small = 24;
      final m = begin(
        stops: stops,
        start: 1,
        focalIndex: 9,
        scroll: 0,
        itemCount: small,
        reversed: true,
        centerFocal: true,
      );
      addTearDown(m.dispose);
      for (var k = 2; k < stops.length; k++) {
        final dest = m.stops[k];
        final winTop = dest.rowAtY(m.restScrolls[k], origin);
        final winBot = dest.rowAtY(m.restScrolls[k] + size.height, origin);
        expect(
          winTop <= 0 && winBot >= dest.rowOf(small - 1),
          isTrue,
          reason: 'k=$k window $winTop..$winBot does not cover all ${dest.rowCount(small)} rows',
        );
      }
    });
  });

  group('zoom-out emission gate', () {
    /// Sweeps the zoom-out interval [lower, lower+1] under [config] and
    /// asserts every tile emitted at an off-next-viewport slot shows the
    /// departing photo (never an arriving swap outside the boundary
    /// band), while at least one on-screen slot does swap. [lower] may
    /// sit past [start] — a multi-hop pinch keeps emitting under the
    /// interval's larger stop while the window targets its denser stop.
    void checkGating({
      required int start,
      required int lower,
      required bool mirrored,
      required bool reversed,
      required bool centered,
      int focalIndex = 200,
      double scroll = 300,
      int itemCount = count,
      int phase = 0,
      double aspect = 1.0,
      Offset focalPoint = const Offset(195, 400),
      bool parkFocal = false,
    }) {
      final stops = [
        for (final c in [1, 3, 5, 16]) MorphGridStop(c, size.width, spacing: 2, aspect: aspect, mirrorRows: mirrored),
      ];
      // A real pinch lands on a visible photo — park the scroll so the
      // focal cell's centre sits at the screen's centre on the phased
      // start layout. The band's edge rows then reach past the landing
      // window, which is what the gate has to hold back.
      final parked = parkFocal
          ? stops[start].withPhase(phase).tileTop(focalIndex, origin) + 0.5 * stops[start].tileHeight - size.height / 2
          : scroll;
      final m = begin(
        stops: stops,
        start: start,
        focalIndex: focalIndex,
        scroll: parked,
        itemCount: itemCount,
        reversed: reversed,
        centerFocal: centered,
        phase: phase,
        focalPoint: focalPoint,
      );
      addTearDown(m.dispose);

      final dest = m.stops[lower + 1];
      final depart = m.stops[lower];
      final destFocalRow = dest.rowOf(focalIndex);
      final destFocalColumn = dest.columnOf(focalIndex, itemCount);
      final windowTop = dest.rowAtY(m.restScrolls[lower + 1], origin);
      final windowBottom = dest.rowAtY(m.restScrolls[lower + 1] + size.height, origin);
      final departFocalColumn = depart.columnOf(focalIndex, itemCount);
      final departFocalRow = depart.rowOf(focalIndex);
      int departingItem(int columnOffset, int rowOffset) =>
          depart.itemAt((departFocalRow + rowOffset) * depart.columns + departFocalColumn + columnOffset, itemCount);

      // The pinch-start screen — the emitter's focal-anchored `nextScreen`
      // window: slots whose departing photo wasn't visible there are new
      // territory sliding in and may materialise their arriving copy
      // regardless of the destination window.
      final startStop = m.stops[start];
      final startFocalRow = startStop.rowOf(focalIndex);
      final startFocalTop = startStop.rowTop(startFocalRow, origin) - parked;
      final startVisibleTop = startFocalRow - (startFocalTop / startStop.rowStride).ceil();
      final startVisibleBottom = startFocalRow + ((size.height - startFocalTop) / startStop.rowStride).floor();
      bool wasOnStartScreen(int index) =>
          index >= 0 && startStop.rowOf(index) >= startVisibleTop && startStop.rowOf(index) <= startVisibleBottom;

      // A slot is off the next screen when its slot offset lands outside
      // the destination screen's own rectangle — the `columns`-wide band
      // of offsets landing on real lattice columns, times the rest-screen
      // row window — AND its departing photo was on the start screen. The
      // rectangle is measured on the SLOT's destination coordinates: the
      // linear `itemAt` resolution wraps off-grid column offsets to real
      // items from neighbouring rows, so membership tests over-flag.
      bool offNext(int columnOffset, int rowOffset) {
        final inRect =
            (destFocalColumn + columnOffset) >= 0 &&
            (destFocalColumn + columnOffset) < dest.columns &&
            (destFocalRow + rowOffset) >= windowTop &&
            (destFocalRow + rowOffset) <= windowBottom;
        return !inRect && wasOnStartScreen(departingItem(columnOffset, rowOffset));
      }

      // Sweep inside the ±3% boundary band the arriving side owns at each
      // edge — a frame just past a stop keys the same rest tiles as the
      // stop itself, so the band may legitimately show the next photo.
      final itemsPerOffNextSlot = <String, Set<int>>{};
      final itemsPerOnNextSlot = <String, Set<int>>{};
      for (var level = lower + 0.04; level <= lower + 0.96; level += 0.04) {
        m.set(level: level);
        for (final t in m.frame((i) => false).tiles) {
          if (t.opacity < 0.02) continue;
          final slot = '${t.columnOffset}|${t.rowOffset}';
          (offNext(t.columnOffset, t.rowOffset) ? itemsPerOffNextSlot : itemsPerOnNextSlot)
              .putIfAbsent(slot, () => {})
              .add(t.index);
        }
      }

      for (final e in itemsPerOffNextSlot.entries) {
        final parts = e.key.split('|');
        final dc = int.parse(parts[0]);
        final dr = int.parse(parts[1]);
        final expected = departingItem(dc, dr);
        expect(
          e.value.length,
          1,
          reason:
              'mirrored=$mirrored reversed=$reversed centered=$centered '
              'f=$focalIndex sc=$scroll: off-viewport slot ${e.key} swapped to ${e.value} '
              '(departing item $expected)',
        );
        expect(
          e.value.single,
          expected,
          reason:
              'mirrored=$mirrored reversed=$reversed centered=$centered '
              'f=$focalIndex sc=$scroll: off-viewport slot ${e.key} does not show the departing photo',
        );
      }
      // The sweep must emit slots and swap inside the window — otherwise
      // the gate checks ran vacuously. Off-window slots can't be forced:
      // a small landing window can sit inside the emitted band entirely.
      expect(
        itemsPerOffNextSlot.length + itemsPerOnNextSlot.length,
        greaterThan(0),
        reason: 'the sweep emitted no tiles at all',
      );
      expect(
        itemsPerOnNextSlot.values.any((items) => items.length > 1),
        isTrue,
        reason: 'no on-viewport slot swapped photos — the morph did not run',
      );
    }

    test('zoom-out 5->16 mid-list — production axis', () {
      checkGating(start: 2, lower: 2, mirrored: true, reversed: true, centered: true);
    });
    test('zoom-out 3->5 mid-list — production axis', () {
      checkGating(start: 1, lower: 1, mirrored: true, reversed: true, centered: true);
    });
    test('zoom-out 5->16 mid-list — plain ladder', () {
      checkGating(start: 2, lower: 2, mirrored: false, reversed: false, centered: false);
    });
    test('zoom-out 5->16 from a parked top edge — the rest scroll clamps', () {
      // Scroll 0 pins the viewport to the content head; the denser rest
      // scroll clamps to minScroll and the window must bracket the head
      // rows, not extrapolate the pinch position.
      checkGating(start: 2, lower: 2, mirrored: true, reversed: true, centered: true, focalIndex: 3, scroll: 0);
    });
    test('zoom-out 5->16 from the content tail — the rest scroll clamps', () {
      // A bottom-of-list pinch lands the denser rest scroll on max — the
      // window must bracket the tail rows.
      final stops = [
        for (final c in [1, 3, 5, 16]) MorphGridStop(c, size.width, spacing: 2, aspect: 1.0, mirrorRows: true),
      ];
      final maxScroll = math.max(0.0, stops[2].rowTop(stops[2].rowCount(count), origin) + trailing - size.height);
      checkGating(
        start: 2,
        lower: 2,
        mirrored: true,
        reversed: true,
        centered: true,
        focalIndex: count - 2,
        scroll: maxScroll,
      );
    });
    test('zoom-out 5->16 mid multi-hop — the pinch began at 1 col', () {
      // The gesture swept 1->3->5->16 in one motion: the departing photo is
      // the interval's 5-col item, `wasOnStartScreen` resolves under the
      // parked 1-col layout — the window still has to bracket the 16-col
      // rest viewport.
      checkGating(start: 0, lower: 2, mirrored: true, reversed: true, centered: true);
    });
    test('zoom-out 3->5 under a phased start stop', () {
      // A committed centre-focal phase shifts the start stop's item
      // mapping — the departing photo resolves through the phased
      // lattice, the window through the phased destination.
      checkGating(start: 1, lower: 1, mirrored: true, reversed: true, centered: true, phase: 2, parkFocal: true);
    });
    test('zoom-out 5->16 from a pinch rooted at the bezel edge', () {
      // A focal point near the screen edge parks the rest scroll at a
      // clamp — the window follows the clamped rest, not the touch point.
      checkGating(
        start: 2,
        lower: 2,
        mirrored: true,
        reversed: true,
        centered: true,
        focalPoint: const Offset(20, 780),
      );
    });
    test('zoom-out 5->16 with non-square cells', () {
      checkGating(start: 2, lower: 2, mirrored: true, reversed: true, centered: true, aspect: 0.72);
    });
  });
}

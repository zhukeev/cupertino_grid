// Shared body of the `per-cell morph` fuzz — extracted so the shards can
// run in parallel test processes. `flutter test -j` only parallelizes
// across FILES, so this single ~2-minute randomized sweep used to be the
// suite's critical path; each `pinch_morph_cells_*_test.dart` shard calls
// this with its own seed/trial slice.
// Prints carry the drift report and failure list — the check's diagnostics.
// ignore_for_file: avoid_print

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Runs [trials] randomized pinch-morph trials (seeded by [seed]) on a
/// [reversed]-axis or normal scroll axis and asserts the morph invariants:
/// first frame equals the real grid, frames are continuous, stops are
/// seamless, no coverage holes, and the settled frame equals the target
/// stop's rest layout.
void runPerCellMorph({required bool reversed, required int seed, required int trials}) {
  const size = Size(390, 800);
  final stops = [
    for (final c in [1, 3, 4, 5, 7, 11])
      // The production axis pairs the reversed scroll direction with
      // mirrored rows — exercise the same pairing in the fuzz.
      MorphGridStop(c, 390, spacing: 2, aspect: c == 1 ? 4 / 3 : 1.0, showsLabels: c >= 7, mirrorRows: reversed),
  ];
  const count = 709;
  const origin = 100.0;
  final rnd = math.Random(seed);
  var fails = 0;
  void check(bool ok, String msg) {
    if (!ok && fails++ < 12) print(msg);
  }

  // Screen-space transforms — normal: y = scrollY − scroll; reversed:
  // y = height + scroll − scrollY.
  Rect screenRect(Rect r, double sc) => reversed
      ? Rect.fromLTRB(r.left, size.height + sc - r.bottom, r.right, size.height + sc - r.top)
      : r.shift(Offset(0, -sc));

  final drift = <double>[];
  Map<String, (Rect, double)> keyed(List<MorphTile> tiles) => {
    for (final t in tiles) '${t.index}|${t.columnOffset}|${t.rowOffset}': (t.rect, t.opacity),
  };
  for (var trial = 0; trial < trials; trial++) {
    final start = rnd.nextInt(stops.length);
    final s0 = stops[start];
    final maxS = math.max(0.0, s0.rowTop(s0.rowCount(count), origin) - size.height);
    final scroll = trial % 4 == 0 ? 0.0 : (trial % 4 == 1 ? maxS : rnd.nextDouble() * maxS);
    final focal = Offset(rnd.nextDouble() * 390, 110 + rnd.nextDouble() * 680);
    final fi = reversed
        ? s0.indexAt(Offset(focal.dx, scroll + size.height - focal.dy), count, origin)
        : s0.indexAt(focal + Offset(0, scroll), count, origin);
    final fr = screenRect(s0.tileRect(fi, origin, count), scroll);
    final frac = Offset((focal.dx - fr.left) / fr.width, (focal.dy - fr.top) / fr.height);
    final m = PinchMorph()
      ..begin(
        stops: stops,
        startStop: start,
        focalIndex: fi,
        focalFraction: frac,
        focalPoint: focal,
        startScroll: scroll,
        minScroll: 0,
        trailing: 0,
        itemCount: count,
        origin: origin,
        headerOrigin: 0,
        viewport: size,
        reversed: reversed,
      );
    bool ms(int i) => i % 37 == 0;

    // 1. first frame == real grid. m.stops carries the committed column
    // phase (begin restamps each non-start stop — index-absolute unless
    // centerFocal was set) — the real grid reveals exactly that layout.
    void expectRest(int k, double sc, String what) {
      final f = m.frame(ms);
      final st = m.stops[k];
      final got = {
        for (final t in f.tiles)
          if (t.opacity > 0.99) t.index: t.rect,
      };
      final bandTop = reversed ? 0.0 : math.max(0.0, origin - sc);
      final bandBottom = reversed ? (size.height + sc - origin).clamp(0.0, size.height) : size.height;
      for (var i = 0; i < count; i++) {
        final r = screenRect(st.tileRect(i, origin, count), sc);
        final vis = r.bottom > bandTop + 0.5 && r.top < bandBottom - 0.5 && r.right > 0.5 && r.left < 389.5;
        if (!vis) continue;
        final g = got[i];
        check(
          g != null &&
              (g.topLeft - r.topLeft).distance < 1e-6 &&
              (g.width - r.width).abs() < 1e-6 &&
              (g.height - r.height).abs() < 1e-6,
          '$what: tile $i ${g ?? "missing"} vs $r',
        );
      }
    }

    expectRest(start, scroll, 'start frame');

    // sweep one interval each way
    Map<String, (Rect, double)>? prev;
    for (
      var level = math.max(0.0, start - 1.0);
      level <= math.min(stops.length - 1.0, start + 1.0) + 1e-9;
      level += 0.004
    ) {
      final lvl = math.min(level, stops.length - 1.0);
      m.set(level: lvl);
      final f = m.frame(ms);
      // 3. coverage inside the content band
      final tiles = f.tiles;
      // Column counts of the two morphing lattices — needed to map a
      // slot offset (dc/dr) back to the item it would hold at rest.
      final lower = lvl.floor().clamp(0, stops.length - 1);
      final aCols = stops[lower].columns;
      final bCols = stops[math.min(lower + 1, stops.length - 1)].columns;
      // The DEPARTING layer's tiles all ride the shared band anchor
      // (`left − columnOffset·strideX` identical); arriving tiles emit on
      // their own centred lattice, so a covering tile's slot no longer
      // equals the point's slot. Resolve the point's own slot through
      // the band anchor instead, so coverage is still demanded exactly
      // where the band's content grid lives — and a centred ghost over a
      // legitimately-empty departing cell is not counted a hole.
      final zoomInNow = lvl < start;
      final depStop = zoomInNow ? stops[math.min(lower + 1, stops.length - 1)] : stops[lower];
      final depSize = depStop.tileWidth.ceil();
      MorphTile? bandTile;
      for (final t in tiles) {
        if (t.targetSize == depSize) {
          bandTile = t;
          break;
        }
      }
      final bandStrideX = bandTile == null ? 0.0 : bandTile.rect.width + depStop.spacing;
      final bandStrideY = bandTile == null ? 0.0 : bandTile.rect.height + depStop.spacing;
      final bandAnchorX = bandTile == null ? 0.0 : bandTile.rect.left - bandTile.columnOffset * bandStrideX;
      // Reversed tiles mirror about the horizontal axis, so their top
      // runs `top0 − rowOffset·strideY` instead of `top0 + rowOffset·strideY`.
      final bandAnchorY = bandTile == null
          ? 0.0
          : reversed
          ? bandTile.rect.top + bandTile.rowOffset * bandStrideY
          : bandTile.rect.top - bandTile.rowOffset * bandStrideY;
      for (var yi = 0; yi < 24; yi++) {
        final y = f.clipTop + 1 + (f.clipBottom - f.clipTop - 2) * yi / 23;
        for (var xi = 0; xi < 12; xi++) {
          final x = 1 + 388 * xi / 11;
          var cover = 0.0;
          for (final t in tiles) {
            if (t.rect.inflate(1.6).contains(Offset(x, y))) {
              cover = math.max(cover, t.opacity);
            }
          }
          if (bandTile == null) continue;
          // Slot off covers [anchor + off·stride, anchor + (off+1)·stride)
          // — floor, never round, or edge points snap into a neighbour
          // slot and demand coverage a phase-hole slot does not owe.
          final colFrac = (x - bandAnchorX) / bandStrideX;
          final rowFrac = (reversed
              ? (bandAnchorY + bandTile.rect.height - y) / bandStrideY
              : (y - bandAnchorY) / bandStrideY);
          final pointColumnOffset = colFrac.floor();
          final pointRowOffset = rowFrac.floor();
          // Points inside the 2-px spacing gutter between tiles are
          // legitimately uncovered — the real grid shows background there
          // too. Only demand coverage inside a tile's own footprint.
          if ((colFrac - pointColumnOffset) * bandStrideX >= bandTile.rect.width ||
              (rowFrac - pointRowOffset) * bandStrideY >= bandTile.rect.height) {
            continue;
          }
          // The point belongs to exactly one band slot; check coverage
          // only where that slot holds a real photo at BOTH ends of the
          // interval — resolved through the morph's OWN stamped stops
          // (m.stops carries the committed phase, matching the emitter's
          // itemAt calls) so clamped edge rows and phase holes stay
          // legitimately uncovered. Padding slots — beyond either end of
          // the item range — hold a fading layer or nothing.
          final aStop = m.stops[lower];
          final bStop = m.stops[math.min(lower + 1, m.stops.length - 1)];
          final dense = bStop.itemAt(
            (bStop.rowOf(fi) + pointRowOffset) * bCols + bStop.columnOf(fi, count) + pointColumnOffset,
            count,
          );
          final partner = aStop.itemAt(
            (aStop.rowOf(fi) + pointRowOffset) * aCols + aStop.columnOf(fi, count) + pointColumnOffset,
            count,
          );
          if (dense < 0 || dense >= count || partner < 0 || partner >= count) continue;
          // 0.985 tolerates the instant a beyond-content slot fades
          // out (1 − fade ≈ 0.9896 at fade start) — real holes sit far
          // below this.
          check(cover > 0.985, 'hole at ($x,$y) L=$lvl start=$start');
        }
      }
      // 4. tracking of the pinched photo (mid-list only). Informational,
      // not asserted: pinches rooted near a bezel intentionally let the
      // cell drift off the fingers — it stays on screen rather than
      // clipping behind the edge — so p99 drift is expected to be large.
      if (trial % 4 >= 2) {
        final ft = tiles.where((t) => t.index == fi && t.columnOffset == 0 && t.rowOffset == 0).firstOrNull;
        if (ft != null) {
          drift.add((ft.rect.topLeft + Offset(frac.dx * ft.rect.width, frac.dy * ft.rect.height) - focal).distance);
        }
      }
      // 2. per-tile continuity between consecutive samples (small steps)
      final cur = keyed(tiles);
      if (prev != null) {
        for (final e in cur.entries) {
          final p = prev[e.key];
          final slot = e.key.substring(e.key.indexOf('|'));
          final wasCovered = prev.entries.any((c) => c.key.endsWith(slot) && c.value.$2 > 0.99);
          final r0 = e.value.$1;
          final enters =
              r0.right <= 3e1 || r0.left >= 360 || r0.top >= f.clipBottom - 30 || r0.bottom <= f.clipTop + 30;
          if (p == null) {
            check(
              e.value.$2 < 0.08 || wasCovered || enters,
              'tile ${e.key} popped in at opacity ${e.value.$2.toStringAsFixed(2)} L=$lvl',
            );
            continue;
          }
          // A keyed tile may switch between its band copy and its
          // centred arriving copy as the slot's layers hand off — that
          // is a materialisation, not a teleport, and is fine while an
          // opaque tile still covers the old pixel.
          final handedOff = cur.values.any((c) => c.$1.inflate(1).contains(p.$1.center) && c.$2 > 0.99);
          check(
            (p.$1.center - e.value.$1.center).distance < 30 || handedOff,
            'tile ${e.key} jumped ${(p.$1.center - e.value.$1.center).distance.toStringAsFixed(1)} L=$lvl',
          );
        }
        for (final e in prev.entries) {
          if (!cur.containsKey(e.key)) {
            final r = e.value.$1;
            final offscreen =
                r.right <= 30 || r.left >= 360 || r.bottom <= f.clipTop + 30 || r.top >= f.clipBottom - 30;
            final slot = e.key.substring(e.key.indexOf('|'));
            final covered = cur.entries.any((c) => c.key.endsWith(slot) && c.value.$2 > 0.99);
            check(
              e.value.$2 < 0.08 || offscreen || covered,
              'tile ${e.key} vanished at opacity ${e.value.$2.toStringAsFixed(2)} L=$lvl',
            );
          }
        }
      }
      prev = cur;
    }
    // 2b. exact continuity at every stop
    for (var k = 1; k < stops.length; k++) {
      m.set(level: k - 1e-9);
      final below = keyed(m.frame(ms).tiles);
      m.set(level: k.toDouble());
      final at = keyed(m.frame(ms).tiles);
      m.set(level: k + 1e-9);
      final above = keyed(m.frame(ms).tiles);
      for (final side in [below, if (k < stops.length - 1) above]) {
        for (final e in at.entries) {
          final o = side[e.key];
          check(
            o != null && (o.$1.topLeft - e.value.$1.topLeft).distance < 0.01 && (o.$2 - e.value.$2).abs() < 0.01,
            'stop $k: ${e.key} differs',
          );
        }
      }
    }
    // 5. settle lands exactly on the real grid of the target
    final target = rnd.nextInt(stops.length);
    m.settleStop = target;
    m.set(level: target.toDouble(), pin: 0, overscale: 1);
    expectRest(target, m.restScrolls[target], 'settled frame');
  }
  drift.sort();
  if (drift.isNotEmpty) {
    String q(double p) => drift[((drift.length - 1) * p).round()].toStringAsFixed(2);
    print('focal drift from fingers (mid-list): median=${q(.5)} p90=${q(.9)} p99=${q(.99)} max=${q(1)} px');
  }
  print('failures: $fails');
  expect(fails, 0);
}

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Horizontal anchoring during a pinch: while the fingers are down the
/// band is one rigid lattice scaled about the viewport's horizontal
/// centre — every pinch produces exactly the motion a centre-image
/// pinch does, so both bezels clip equally at every level, never
/// anchored to the finger's x and never translated toward the focal's
/// landing column (the video regressions: mid zoom-in leaned toward a
/// bezel; a side focal's band held its own pinch-start point and left
/// the margins lopsided). On release the pin glide carries the band to
/// the settle stop's rest lattice — both parked and committed grids
/// are exact.
void main() {
  const size = Size(390, 800);
  const count = 709;
  const origin = 100.0;
  const trailing = 120.0;
  const spacing = 2.0;

  List<MorphGridStop> stops({bool mirrored = false}) => [
    for (final c in [1, 3, 5, 16]) MorphGridStop(c, size.width, spacing: spacing, aspect: 1.0, mirrorRows: mirrored),
  ];

  PinchMorph begin({
    required List<MorphGridStop> stops,
    required int start,
    required int focalIndex,
    required double scroll,
    int itemCount = count,
    bool reversed = false,
    bool centerFocal = false,
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
      centerFocal: centerFocal,
    );

  group('column-true horizontal anchor', () {
    test('anchor.dx ignores the finger x — off-centre pinch, both axes', () {
      for (final mirrored in [false, true]) {
        for (final reversed in [false, true]) {
          final s = stops(mirrored: mirrored);
          // A pinch rooted far left vs far right of the same focal cell:
          // only the touch x differs — the emitted band must not care.
          final anchors = <double>[];
          for (final fingerX in [60.0, 195.0, 330.0]) {
            final m = begin(
              stops: s,
              start: 1,
              focalIndex: 200,
              scroll: 300,
              reversed: reversed,
              centerFocal: true,
              focalPoint: Offset(fingerX, 400),
            );
            addTearDown(m.dispose);
            for (final level in [1.0, 1.25, 1.5, 1.9]) {
              m.set(level: level);
              m.frame((i) => false); // anchor is consumed inside frame()
              anchors.add(m.anchor.dx);
            }
          }
          // Three finger x values × four levels: anchor.dx must collapse
          // to the four level-distinct values only.
          for (var i = 0; i < 4; i++) {
            final a = anchors[i], b = anchors[4 + i], c = anchors[8 + i];
            expect(
              (a - b).abs() < 1e-9 && (b - c).abs() < 1e-9,
              isTrue,
              reason:
                  'mirrored=$mirrored reversed=$reversed level[$i]: anchor.dx follows the finger '
                  '($a / $b / $c) — the band would sit off-centre',
            );
          }
        }
      }
    });

    test('emitted columns land exactly on the destination lattice', () {
      // At a settled stop boundary every on-window tile must sit on its
      // true landing column — no horizontal shear residue. If the band
      // were finger-anchored, the lattice would arrive shifted by
      // however far the touch point was from the focal's rest column.
      final s = stops();
      const focal = 202; // start col 1 of 3 — lands centre under keep-screen-column
      final m = begin(
        stops: s,
        start: 1,
        focalIndex: focal,
        scroll: 300,
        centerFocal: true,
        focalPoint: const Offset(60, 400), // fingers far left of centre
      );
      addTearDown(m.dispose);
      final destFocalCol = m.stops[2].columnOf(focal, count);
      expect(destFocalCol, 2, reason: 'test needs a centre-column landing');
      m.settleStop = 2;
      m.set(level: 2.0, pin: 0);
      final frame = m.frame((i) => false);
      var checked = 0;
      for (final t in frame.tiles) {
        if (!t.onNextScreen || t.opacity < 0.5) continue;
        final destCol = destFocalCol + t.columnOffset;
        final expectedLeft = spacing + destCol * m.stops[2].columnStride;
        expect(
          t.rect.left,
          closeTo(expectedLeft, 1e-6),
          reason:
              'tile at dest column $destCol sits at ${t.rect.left}, '
              'not the true column left $expectedLeft — landing shear',
        );
        checked++;
      }
      expect(checked, greaterThan(0), reason: 'no on-window tiles emitted');
    });

    test('centre-column landing — left/right band gaps stay identical', () {
      // Production axis: mirrored rows + reversed scroll + centred focal.
      // The on-window band's edges are what the landing grid will show —
      // their distance to the screen edges must stay identical, or the
      // un-zoomed slack pools on one side (the video regression).
      final s = stops(mirrored: true);
      const focal = 202; // start col 1 of 3 — lands centre under keep-screen-column
      final m = begin(
        stops: s,
        start: 1,
        focalIndex: focal,
        scroll: 300,
        reversed: true,
        centerFocal: true,
        focalPoint: const Offset(90, 400), // fingers well left of centre
      );
      addTearDown(m.dispose);
      final dest = m.stops[2];
      final destFocalCol = dest.columnOf(focal, count);
      expect(destFocalCol, 2, reason: 'test needs a centre-column focal');
      for (var level = 1.05; level <= 1.95; level += 0.1) {
        m.set(level: level);
        final frame = m.frame((i) => false);
        var bandLeft = double.infinity, bandRight = -double.infinity;
        for (final t in frame.tiles) {
          if (t.opacity < 0.5) continue;
          bandLeft = math.min(bandLeft, t.rect.left);
          bandRight = math.max(bandRight, t.rect.right);
        }
        expect(bandLeft.isFinite, isTrue, reason: 'level=$level: no emitted tiles');
        final leftGap = math.max(bandLeft, 0.0), rightGap = math.max(size.width - bandRight, 0.0);
        expect(
          (leftGap - rightGap).abs(),
          lessThan(1.0),
          reason:
              'level=$level: centre-column band left lopsided gaps — '
              'left ${leftGap.toStringAsFixed(1)} vs right ${rightGap.toStringAsFixed(1)} '
              '(edges must meet together)',
        );
      }
    });

    test('middle start column landing centre — band centres early, stays centred', () {
      // A focal starting on the middle column keeps the centre under
      // keep-position — but its landing phase still differs from the
      // start's, so the band must reach that landing position early in the
      // gesture and hold it: slack splits symmetrically, both edges grow
      // at the same rate — instead of riding the start column's x and
      // translating sideways mid-gesture.
      final s = stops(mirrored: true);
      // 212 % 5 == 2 → the middle column of the 5-col start (mirrored to
      // display column 2 — dead centre); nearest-column keeps it centred
      // at the 3-col destination.
      const focal = 212;
      final m = begin(
        stops: s,
        start: 2,
        focalIndex: focal,
        scroll: 300,
        reversed: true,
        centerFocal: true,
        focalPoint: const Offset(120, 620),
      );
      addTearDown(m.dispose);
      final dest = m.stops[1];
      expect(dest.columnOf(focal, count), 1, reason: 'test needs a centre-column landing');
      for (var level = 1.7; level >= 1.05; level -= 0.1) {
        m.set(level: level);
        final frame = m.frame((i) => false);
        var bandLeft = double.infinity, bandRight = -double.infinity;
        for (final t in frame.tiles) {
          if (t.opacity < 0.5) continue;
          bandLeft = math.min(bandLeft, t.rect.left);
          bandRight = math.max(bandRight, t.rect.right);
        }
        expect(bandLeft.isFinite, isTrue, reason: 'level=$level: no emitted tiles');
        final leftGap = math.max(bandLeft, 0.0), rightGap = math.max(size.width - bandRight, 0.0);
        expect(
          (leftGap - rightGap).abs(),
          lessThan(1.0),
          reason:
              'level=$level: off-centre-start focal drags the band — '
              'left ${leftGap.toStringAsFixed(1)} vs right ${rightGap.toStringAsFixed(1)} '
              '(the landing column must hold centre, edges grow together)',
        );
      }
    });

    test('edge-column landing — margins stay identical, edge lands on its margin', () {
      // An edge focal glides to its landing column INSIDE a centred band:
      // the left/right margins stay identical at every level — the same
      // geometry a middle pinch has — while the band bleeds symmetric off
      // both edges mid-reflow. At the boundary the pinned edge arrives
      // exactly on the lattice margin.
      final s = stops();
      // A focal item in the start lattice's leading column — under
      // keep-position it lands on the 5-col stop's leading edge.
      const focal = 201; // 201 % 3 == 0
      final m = begin(stops: s, start: 1, focalIndex: focal, scroll: 300, centerFocal: true);
      addTearDown(m.dispose);
      final dest = m.stops[2];
      final destFocalCol = dest.columnOf(focal, count);
      expect(destFocalCol, 0, reason: 'test needs an edge-column landing');
      for (var level = 1.05; level <= 1.95; level += 0.05) {
        m.set(level: level);
        final frame = m.frame((i) => false);
        var bandLeft = double.infinity, bandRight = -double.infinity;
        for (final t in frame.tiles) {
          if (t.opacity < 0.5) continue;
          bandLeft = math.min(bandLeft, t.rect.left);
          bandRight = math.max(bandRight, t.rect.right);
        }
        expect(bandLeft.isFinite, isTrue, reason: 'level=$level: no emitted tiles');
        // The bezel clamp may pin the band's edge AT the screen edge to
        // keep the pinched photo onscreen while the span overscales past
        // both bezels — asymmetry there is invisible, so compare only
        // what a viewer sees: the positive margins. A few px of
        // slot-quantization slack is allowed — a fading boundary tile can
        // end just inside the bezel; the failure mode this guards was
        // ~250px of one-sided slack.
        final leftGap = math.max(bandLeft, 0.0), rightGap = math.max(size.width - bandRight, 0.0);
        expect(
          (leftGap - rightGap).abs(),
          lessThan(4.0),
          reason:
              'level=$level: edge-landing band lopsided — '
              'left ${leftGap.toStringAsFixed(1)} vs right ${rightGap.toStringAsFixed(1)} '
              '(visible margins must stay identical like a middle pinch)',
        );
      }
      // Exact stop boundary (the loop's float tail lands inside the next
      // interval): the pinned edge sits exactly on the lattice margin.
      m.settleStop = 2;
      m.set(level: 2.0, pin: 0);
      final landed = m.frame((i) => false);
      var landedGap = double.infinity;
      for (final t in landed.tiles) {
        if (!t.onNextScreen || t.opacity < 0.5) continue;
        if (destFocalCol + t.columnOffset != 0) continue;
        landedGap = math.min(landedGap, t.rect.left);
      }
      expect(landedGap, closeTo(spacing, 1e-6), reason: 'leading edge must land on the lattice margin');
    });

    test('zoom-in focal — the band scales about the viewport centre', () {
      // The band is one rigid lattice scaled about the screen's
      // horizontal centre while the fingers are down: the pinched
      // cell's emitted left edge is its parked left scaled by
      // cellW/startW about centre — the same motion a pinch on the
      // middle image produces, so both bezels clip equally at every
      // level. Holding the focal's own pinch-start point instead left
      // an off-centre focal's band off balance — one bezel ate a
      // clipped column while the other kept nearly a full one.
      final s = stops();
      // 16 -> 5, the video's direction. focals land left / right / centre
      // under keep-position at the 5-col stop.
      for (final focal in [4, 14, 9]) {
        final m = begin(stops: s, start: 3, focalIndex: focal, scroll: 400, centerFocal: true);
        addTearDown(m.dispose);
        final start = m.stops[3].tileRect(focal, origin, count);
        for (var level = 2.95; level >= 2.0; level -= 0.05) {
          m.set(level: level);
          final lower = level.floor().clamp(0, s.length - 2);
          final progress = level - lower;
          final cellWidth = progress == 0
              ? s[lower].tileWidth
              : math.exp(lerpDouble(math.log(s[lower].tileWidth), math.log(s[lower + 1].tileWidth), progress)!);
          final expected = size.width / 2 + (start.left - size.width / 2) * cellWidth / start.width;
          double? band;
          for (final t in m.frame((i) => false).tiles) {
            final a = t.rect.left - t.columnOffset * (cellWidth + spacing);
            if (band == null) {
              band = a;
            } else {
              expect(
                (a - band).abs(),
                lessThan(0.6),
                reason: 'level=$level focal=$focal: tile ${t.index} off the shared band',
              );
            }
          }
          expect(band, isNotNull, reason: 'level=$level focal=$focal: no tiles emitted');
          expect(
            band,
            closeTo(expected, 0.6),
            reason:
                'level=$level focal=$focal: band anchor ${band!.toStringAsFixed(1)}, '
                'centre-scaled ${expected.toStringAsFixed(1)} — the band is not '
                'scaling about the viewport centre',
          );
        }
        // On release the pin glide lands the cell on its rest column.
        m.settleStop = 2;
        m.set(level: 2.0, pin: 0);
        final destCol = m.stops[2].columnOf(focal, count);
        double? left;
        for (final t in m.frame((i) => false).tiles) {
          if (t.index == focal && t.rowOffset == 0 && t.columnOffset == 0) left = t.rect.left;
        }
        expect(
          left,
          closeTo(spacing + destCol * m.stops[2].columnStride, 1e-6),
          reason: 'focal=$focal: settled cell missed its rest column',
        );
      }
    });

    test('zoom-out edge focal — holds its bezel, no sweep toward centre', () {
      // Video regression: zooming OUT to a denser stop dragged an edge
      // focal's emitted slot ~40px toward the centre while the blend
      // still rode the departing lattice's shrinking centred span, then
      // swung it back out — a left-right wobble. A bezel focal pins the
      // screen edge it rests on through the whole gesture (the centre
      // scale applies only to interior cells — an edge photo scaled
      // about the centre pulls off its bezel mid-gesture), so the
      // photo never leaves the screen edge.
      final s = stops();
      for (final edgeFocal in [500, 504]) {
        // 500 % 5 == 0 → leading column; 504 % 5 == 4 → trailing.
        final m = begin(stops: s, start: 2, focalIndex: edgeFocal, scroll: 1200, centerFocal: true);
        addTearDown(m.dispose);
        final leading = s[2].columnOf(edgeFocal, count) == 0;
        // The emitted focal cell must hold its screen edge through the
        // overscale — under the mid-window blend it left the bezel for a
        // ~40px excursion toward the centre first. The bound is one
        // landing column + spacing inside the bezel: an edge landing sits
        // up to a column inboard by design, so hugging closer would be
        // wrong — while the departed-span sweep pushed it ~40px past that.
        final edgeLimit = spacing + m.stops[3].columnStride + spacing;
        for (var level = 2.0; level <= 2.8; level += 0.05) {
          m.set(level: level);
          var seen = false;
          for (final t in m.frame((i) => false).tiles) {
            if (t.index == edgeFocal && t.rowOffset == 0 && t.columnOffset == 0 && t.opacity >= 0.5) {
              seen = true;
              expect(
                leading ? t.rect.left <= edgeLimit : t.rect.right >= size.width - edgeLimit,
                isTrue,
                reason:
                    'level=$level focal=$edgeFocal: edge focal left its bezel — '
                    'rect $t (the departed-span sweep-back wobble)',
              );
            }
          }
          expect(seen, isTrue, reason: 'level=$level focal=$edgeFocal: focal tile culled');
        }
        // …then lands on its own column at the boundary.
        m.settleStop = 3;
        m.set(level: 3.0, pin: 0);
        final destCol = m.stops[3].columnOf(edgeFocal, count);
        double? left;
        for (final t in m.frame((i) => false).tiles) {
          if (t.index == edgeFocal && t.rowOffset == 0 && t.columnOffset == 0) {
            left = t.rect.left;
          }
        }
        expect(left, closeTo(spacing + destCol * m.stops[3].columnStride, 1e-6));
      }
    });

    test('every cell in a row — interior clips evenly, edge cells hold their bezel', () {
      // Sweep every column of one 5-col row as the pinch focal: the two
      // bezel columns pin their screen edge (the pinned side's clip
      // stays 0), the three interior columns ride the centre scale —
      // the off-screen clip depth must be equal on both bezels at every
      // level, exactly the padding a centre-image pinch shows. The
      // regression this guards: the focal-pivot anchor held an off-centre
      // focal's own point, piling all the clip onto one bezel.
      final s = stops();
      for (var focal = 30; focal <= 34; focal++) {
        // Items 30..34 = row 6 of the 5-col stop → columns 0..4.
        final m = begin(stops: s, start: 2, focalIndex: focal, scroll: 300, centerFocal: true);
        addTearDown(m.dispose);
        final start = s[2].tileRect(focal, origin, count);
        final leftBezel = start.left <= spacing + 0.5;
        final rightBezel = start.right >= size.width - spacing - 0.5;
        for (var level = 1.95; level >= 1.05; level -= 0.1) {
          m.set(level: level, pin: 1);
          var bandLeft = double.infinity, bandRight = -double.infinity;
          for (final t in m.frame((i) => false).tiles) {
            if (t.opacity < 0.5) continue;
            bandLeft = math.min(bandLeft, t.rect.left);
            bandRight = math.max(bandRight, t.rect.right);
          }
          expect(bandLeft.isFinite, isTrue, reason: 'level=$level focal=$focal: no emitted tiles');
          final leftClip = math.max(0 - bandLeft, 0.0);
          final rightClip = math.max(bandRight - size.width, 0.0);
          if (leftBezel) {
            expect(leftClip, lessThan(0.6), reason: 'level=$level focal=$focal: left-bezel cell lost its screen edge');
          } else if (rightBezel) {
            expect(
              rightClip,
              lessThan(0.6),
              reason: 'level=$level focal=$focal: right-bezel cell lost its screen edge',
            );
          } else {
            expect(
              (leftClip - rightClip).abs(),
              lessThan(4.0),
              reason:
                  'level=$level focal=$focal: interior focal clips lopsided — '
                  'left ${leftClip.toStringAsFixed(1)} vs right ${rightClip.toStringAsFixed(1)} '
                  '(an off-centre pinch must pad like a centre pinch)',
            );
          }
        }
      }
    });
  });
}

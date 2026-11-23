// Golden coverage for the pinch morph: every ordered density pair of the
// {3,5,16} ladder on both scroll axes, captured mid-gesture, mid-settle and
// after commit. Tiles are numbered (index painted as pixel digits over a
// hue band) so a shifted lattice shows up as wrong digits under the pinch
// point — the failure mode of the unmirrored restScrolls regression, where
// only the released snap was visible and end-state assertions stayed green.
//
// Each transition pinches the item that resolves to a MID-RANGE scroll at
// the destination density — near the scroll bounds a wrong rest target
// clamps to the same edge as the correct one and the suite goes blind.
//
// Regenerate: flutter test --update-goldens test/core/veya_ui/pinch_morph_golden_test.dart
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

const _viewport = Size(390, 780);
const _spacing = 2.0;
const _counts = [1, 3, 5, 16];
const _pairs = [(1, 3), (3, 1), (3, 5), (5, 3), (3, 16), (16, 3), (5, 16), (16, 5)];

const _count = 1600;

// The 1-column hero stop morphs cell shape too — the real ladder gives it
// 4:3 tiles while every denser stop stays square.
MorphGridStop _stop(int columns, {bool mirror = false}) =>
    MorphGridStop(columns, _viewport.width, spacing: _spacing, aspect: columns == 1 ? 4 / 3 : 1.0, mirrorRows: mirror);

double _tileWidth(int columns) => _stop(columns).tileWidth;

/// The item, pinch point and starting scroll that land the commit at a
/// mid-range offset (~1400) on the destination stop: index [item]'s pinch
/// point resolves to [scroll], and at [from] the item sits under [focal].
/// The item's column at [from] must leave [halfGap] of screen on both
/// sides or the synthetic fingers land off-viewport and no pinch fires.
({int item, Offset focalPoint, double scroll}) _pinchPlan(int from, int to, bool reversed, double halfGap) {
  final stopA = _stop(from, mirror: reversed);
  final stopB = _stop(to, mirror: reversed);
  const resolved = 1400.0;
  // Morph-space y the pinch point keeps: mirrored (H − 560) on a reversed
  // axis, raw 560 otherwise.
  final anchor = reversed ? _viewport.height - 560.0 : 560.0;
  final rowB = ((resolved + anchor - stopB.tileHeight / 2 - _spacing) / stopB.rowStride).round();
  final colOrder = [for (var c = 0; c < to; c++) c]
    ..sort((a, b) => (a - (to - 1) / 2).abs().compareTo((b - (to - 1) / 2).abs()));
  for (var dr = 0; dr <= 8; dr++) {
    for (final row in (dr == 0 ? [rowB] : [rowB + dr, rowB - dr])) {
      if (row < 0) continue;
      for (final colB in colOrder) {
        final item = stopB.itemAt(row * to + colB, _count);
        if (item < 0) continue;
        final centerA = stopA.tileRect(item, 0, _count).center;
        final focalX = centerA.dx;
        if (focalX - halfGap < 8 || focalX + halfGap > _viewport.width - 8) {
          continue;
        }
        // Put the item at screen y 560 when the list can scroll it there;
        // at the boundary it sits wherever it sits — pinch its position.
        final scroll = math.max(0.0, centerA.dy - anchor);
        final focalY = reversed ? _viewport.height + scroll - centerA.dy : centerA.dy - scroll;
        if (focalY < 40 || focalY > _viewport.height - 40) continue;
        return (item: item, focalPoint: Offset(focalX, focalY), scroll: scroll);
      }
    }
  }
  throw StateError('no pinchable item for $from->$to reversed=$reversed');
}

Future<void> _snap(WidgetTester tester, String name) =>
    expectLater(find.byKey(const ValueKey('morph')), matchesGoldenFile('goldens/pinch_morph/$name.png'));

void main() {
  for (final reversed in [false, true]) {
    for (final (from, to) in _pairs) {
      final axis = reversed ? 'rev' : 'fwd';
      testWidgets('morph golden $axis $from->$to', tags: 'golden', (tester) async {
        tester.view.physicalSize = _viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final controller = ScrollController();
        addTearDown(controller.dispose);
        var committed = from;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: RepaintBoundary(
                key: const ValueKey('morph'),
                child: CupertinoGrid(
                  itemCount: _count,
                  columnCounts: _counts,
                  initialColumns: from,
                  reverse: reversed,
                  mirrorRows: reversed,
                  scrollController: controller,
                  onColumnsChanged: (columns) => committed = columns,
                  itemKey: (index) => 'item-$index',
                  itemBuilder: (context, index, targetSize) => _NumberedTile(index),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final needed = _tileWidth(to) / _tileWidth(from);
        // 95% of the log-scale span: firmly past the commit threshold, not
        // clamped into the neighbouring stop.
        final effective = math.exp(math.log(needed) * 0.95);
        final gap0 = needed > 1 ? 44.0 : 120.0;
        // The widest distance a finger travels from the focal point —
        // contract pinches start wide, spreads end wide.
        final halfGap = gap0 * math.max(effective, 1.0) / 2;
        final plan = _pinchPlan(from, to, reversed, halfGap);
        controller.jumpTo(plan.scroll);
        await tester.pump();

        final tag = '${axis}_${from}to$to';
        await _snap(tester, '${tag}_0_start');
        expect(
          tester.getRect(find.byKey(ValueKey<Object?>('item-${plan.item}')).first).contains(plan.focalPoint),
          isTrue,
          reason: 'pinch must land on the planned item',
        );

        final center = plan.focalPoint;

        final finger1 = await tester.createGesture();
        final finger2 = await tester.createGesture();
        await finger1.down(Offset(center.dx - gap0 / 2, center.dy));
        await finger2.down(Offset(center.dx + gap0 / 2, center.dy));
        await tester.pump();
        for (var step = 1; step <= 3; step++) {
          final half = gap0 * math.exp(math.log(effective) * step / 3) / 2;
          await finger1.moveTo(Offset(center.dx - half, center.dy));
          await finger2.moveTo(Offset(center.dx + half, center.dy));
          await tester.pump();
          await _snap(tester, '${tag}_g$step');
        }
        await finger1.up();
        await finger2.up();
        for (var step = 1; step <= 3; step++) {
          await tester.pump(const Duration(milliseconds: 80));
          await _snap(tester, '${tag}_s$step');
        }
        await tester.pumpAndSettle();
        await _snap(tester, '${tag}_end');
        expect(committed, to);
        // The settled grid must keep the pinched item under the release
        // point vertically — horizontal position realigns to the item's
        // canonical column at the new density by design.
        final tile = find.byKey(ValueKey<Object?>('item-${plan.item}')).first;
        final rect = tester.getRect(tile);
        expect(
          rect.top <= center.dy && rect.bottom >= center.dy,
          isTrue,
          reason: 'pinched item must stay under the finger after commit',
        );
      });
    }
  }
}

/// A grid cell that paints its index as pixel digits on an index-derived
/// hue — self-contained (no font asset) so goldens stay deterministic.
class _NumberedTile extends StatelessWidget {
  const _NumberedTile(this.index);

  final int index;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _NumberedTilePainter(index));
}

class _NumberedTilePainter extends CustomPainter {
  const _NumberedTilePainter(this.index);

  final int index;

  static const _glyphs = [
    [7, 5, 5, 5, 7], // 0
    [2, 6, 2, 2, 7], // 1
    [7, 1, 7, 4, 7], // 2
    [7, 1, 7, 1, 7], // 3
    [5, 5, 7, 1, 1], // 4
    [7, 4, 7, 1, 7], // 5
    [7, 4, 7, 5, 7], // 6
    [7, 1, 2, 2, 2], // 7
    [7, 5, 7, 5, 7], // 8
    [7, 5, 7, 1, 7], // 9
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = HSLColor.fromAHSL(1, (index * 137) % 360 + .0, .55, .45).toColor());
    final digits = index.toString();
    final cell = math.min(size.width / (digits.length * 4 - 1), size.height / 5);
    if (cell >= 1.2) {
      final paint = Paint()..color = HSLColor.fromAHSL(1, (index * 137) % 360 + .0, .9, .16).toColor();
      var dx = (size.width - (digits.length * 4 - 1) * cell) / 2;
      final top = (size.height - 5 * cell) / 2;
      for (var d = 0; d < digits.length; d++) {
        final glyph = _glyphs[digits.codeUnitAt(d) - 48];
        for (var row = 0; row < 5; row++) {
          for (var bit = 0; bit < 3; bit++) {
            if (glyph[row] & (4 >> bit) == 0) continue;
            canvas.drawRect(Rect.fromLTWH(dx + bit * cell, top + row * cell, cell * .85, cell * .85), paint);
          }
        }
        dx += 4 * cell;
      }
    }
    canvas.drawRect(
      rect.deflate(.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x55000000),
    );
  }

  @override
  bool shouldRepaint(_NumberedTilePainter oldDelegate) => index != oldDelegate.index;
}

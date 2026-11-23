// Semantics-tree regression for the pinch morph overlay.
//
// On device, a pinch produced this every frame:
//   Failed assertion: '!semantics.parentDataDirty': is not true
//
// Mechanism: overlay slots mount mid-gesture via onSlotsNeeded while pointer
// moves keep marking the overlay's render object needsLayout. When a flush
// runs with the overlay still layout-dirty, the framework drops it from the
// semantics update list before it can assign parentData to its freshly
// adopted children — the debug tree check then finds the dirty child and
// trips. The fix keeps the overlay subtree out of the semantics tree
// entirely (ExcludeSemantics): the morphing tiles are transient visual
// duplicates of the resting grid, which stays the a11y source underneath.
//
// The test holds a SemanticsHandle so flushSemantics runs its debug check
// every frame. A CustomPaint sibling repaints every frame via a ticking
// animation and fires overlayImagesListenable from inside its paint — a
// markNeedsLayout landing after layout, the same window a real pointer
// event hits mid-frame on device. (Marking during own layout/paint trips
// framework guards; marking another node does not.)
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

const _viewport = Size(390, 780);
const _counts = [1, 3, 5, 16];
const _count = 1600;

/// Repaints every frame and fires [onPaint] from inside the paint phase.
final class _MarkingPainter extends CustomPainter {
  _MarkingPainter({required this.onPaint, required Listenable repaint}) : super(repaint: repaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

void main() {
  testWidgets('pinch morph keeps the semantics tree clean while slots mount', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Without a held handle semantics never flushes and the assert path is
    // unreachable — this is why the crash only showed on a real device.
    final semantics = tester.ensureSemantics();

    final invalidator = ChangeNotifier();
    addTearDown(invalidator.dispose);

    final ticker = AnimationController(vsync: tester, duration: const Duration(seconds: 1));
    addTearDown(ticker.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              CupertinoGrid(
                itemCount: _count,
                columnCounts: _counts,
                initialColumns: 3,
                itemKey: (index) => 'item-$index',
                itemBuilder: (context, index, targetSize) => Container(
                  color: Colors.grey.shade300,
                  child: Center(child: Text('$index')),
                ),
                overlayImagesListenable: invalidator,
              ),
              // Paints after the grid every frame; the invalidate lands the
              // overlay's markNeedsLayout after its layout pass, so it stays
              // dirty into that frame's semantics flush — the on-device race.
              IgnorePointer(
                child: CustomPaint(
                  size: _viewport,
                  painter: _MarkingPainter(onPaint: invalidator.notifyListeners, repaint: ticker),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    ticker.repeat();
    addTearDown(ticker.stop);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(tester.takeException(), isNull);

    // Two fingers down on the centre cell, contract toward the 16-col stop.
    const center = Offset(195, 390);
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(center - const Offset(60, 0));
    await finger2.down(center + const Offset(60, 0));
    await tester.pump();

    // Drive the pinch in steps. Each pump: build adopts new overlay children
    // (onSlotsNeeded's deferred setState), paint fires the invalidate —
    // recreating the adopt-while-needsLayout window every frame.
    for (var step = 1; step <= 6; step++) {
      final half = 60.0 * math.exp(math.log(0.25) * step / 6);
      await finger1.moveTo(center - Offset(half, 0));
      await finger2.moveTo(center + Offset(half, 0));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'semantics assert at pinch step $step');
    }
    await finger1.up();
    await finger2.up();
    for (var step = 0; step < 6; step++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull, reason: 'semantics assert at settle step $step');
    }
    ticker.stop();
    await tester.pump();
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}

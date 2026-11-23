import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Ports the invariants of docs/gallery_pinch_morph_check.sh onto the
/// public [PinchMorph]/[MorphGridStop] API: first frame equals the real
/// grid, frames are continuous, stops are seamless, no coverage holes, and
/// the settled frame equals the target stop's rest layout.
void main() {
  testWidgets('grid renders items and a two-finger pinch morphs and commits', (tester) async {
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CustomScrollView), findsOneWidget);

    // Pinch out (contract -> smaller cells, more columns).
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(180, 400));
    await finger2.moveTo(const Offset(220, 400));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    expect(committed, 5);
  });

  testWidgets('a pinch under disableAnimations still commits, instantly', (tester) async {
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: CupertinoGrid(
              itemCount: 60,
              columnCounts: const [1, 3, 5],
              initialColumns: 3,
              onColumnsChanged: (columns) => committed = columns,
              itemKey: (index) => 'item-$index',
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(180, 400));
    await finger2.moveTo(const Offset(220, 400));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    // No morph overlay or settle spring runs — two pumps cover the
    // commit's post-frame scroll jump and teardown; pumpAndSettle proves
    // nothing remains animating.
    await tester.pump();
    await tester.pump();
    expect(committed, 5);
    await tester.pumpAndSettle();
  });

  testWidgets('reduce-motion pinch holds the landing phase until controlled columns land', (tester) async {
    // Regression: with `columns` owned by the parent, the density lands a
    // rebuild AFTER the release handler stamps the settle stop's landing
    // phase — which can exceed the old grid's column count. The instant
    // finalize path built `_currentStop` with that phase and threw in
    // MorphGridStop's phase range check, inside the pointer-up handler.
    // Item 14's landing phase at 12 columns is 8 — past 5's range.
    var columns = 5;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: CupertinoGrid(
                itemCount: 40,
                columns: columns,
                columnCounts: const [3, 5, 12],
                onColumnsChanged: (next) => setState(() => columns = next),
                onVisibleAnchorChanged: (_, _, _) {},
                centerFocalOnCommit: true,
                itemKey: (index) => 'item-$index',
                itemBuilder: (context, index, targetSize) =>
                    ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Contract the fingers around item 14 (row 2, column 4 at 5 columns)
    // — the gesture's focal point resolves the pinched cell.
    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(590, 400));
    await f2.down(const Offset(780, 400));
    await tester.pump();
    await f1.moveTo(const Offset(690, 400));
    await f2.moveTo(const Offset(730, 400));
    await tester.pump();
    await f1.up();
    await f2.up();
    // The instant finalize, the post-frame jump, and the parent's density
    // adoption each land a pump apart — none may throw.
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(columns, 12);
  });

  testWidgets('pinch from a fitting grid lands the last row at the real scroll edge', (tester) async {
    // Regression: `_scrollMetrics` only derived the content tail while the
    // current grid overflowed. A fitting grid recorded trailing 0, so the
    // destination's rest-scroll clamp ended `footer` short of the real
    // extent — pinching the last row landed it above the footer chrome.
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 80,
            columnCounts: const [3, 5, 16],
            initialColumns: 16,
            scrollController: controller,
            onColumnsChanged: (_) {},
            footer: const SizedBox(height: 100),
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.position.maxScrollExtent, 0, reason: 'five 16-column rows fit the viewport');

    // Spread around the last items (row 4, columns 14–15 at 16 columns —
    // the deepest row of the sparse destination, whose rest scroll
    // overshoots the max extent and must clamp onto it, not land short
    // of it by the footer height).
    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(665, 225));
    await f2.down(const Offset(770, 225));
    await tester.pump();
    await f1.moveTo(const Offset(300, 225));
    await f2.moveTo(const Offset(795, 225));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1),
      reason: 'the last row must land flush with the footer edge, not footer-height above it',
    );
  });

  testWidgets('slow release mid-transition springs back to the nearer stop', (tester) async {
    // Regression: the release commit used the pinch direction with an 18%
    // momentum threshold — releasing ~37% into the 3->1 transition while
    // still moving carried on to the FAR stop instead of springing back
    // (onColumnsChanged never fires when the settle returns to the start).
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(110, 400));
    await f2.moveTo(const Offset(290, 400));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(committed, 0);
  });

  testWidgets('a flick release mid-transition carries on to the next stop', (tester) async {
    // Same ~37% landing as the slow-release case, but the fingers are
    // still moving fast at release — momentum commits the next stop.
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(110, 400), timeStamp: const Duration(milliseconds: 16));
    await f2.moveTo(const Offset(290, 400), timeStamp: const Duration(milliseconds: 32));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(committed, 1);
  });

  testWidgets('a mid-pinch resize keeps the morph coherent and the commit lands', (tester) async {
    // begin() stamps the viewport once — a resize mid-gesture must
    // re-stamp the ladder, mirrored focal state, and rest scrolls rather
    // than commit against stale metrics on release.
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(120, 400), timeStamp: const Duration(milliseconds: 16));
    await f2.moveTo(const Offset(280, 400), timeStamp: const Duration(milliseconds: 16));
    await tester.pump();

    // Surface resizes with the fingers still down — the next frame's
    // LayoutBuilder must re-stamp the morph instead of leaving it stale.
    await tester.binding.setSurfaceSize(const Size(700, 600));
    await tester.pump();

    await f1.moveTo(const Offset(90, 300), timeStamp: const Duration(milliseconds: 32));
    await f2.moveTo(const Offset(310, 500), timeStamp: const Duration(milliseconds: 32));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    // The fingers spread apart through the resize — a zoom-in that must
    // still land on the 1-column stop, same as an uninterrupted gesture.
    expect(committed, 1);
  });

  testWidgets('a backward flick at release still lands on the nearer stop', (tester) async {
    // Momentum only carries in the direction the gesture actually
    // travelled — a sharp reverse jerk in the final event must not bounce
    // a mostly-travelled transition back to the start stop.
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    // Contract ~35%: spread 120 -> ~80 lands deep into the 3 -> 5 travel.
    await f1.moveTo(const Offset(160, 400), timeStamp: const Duration(milliseconds: 16));
    await f2.moveTo(const Offset(240, 400), timeStamp: const Duration(milliseconds: 16));
    await tester.pump();
    // A fast 6px backward jerk — high reverse velocity, tiny level change.
    await f1.moveTo(const Offset(157, 400), timeStamp: const Duration(milliseconds: 24));
    await f2.moveTo(const Offset(243, 400), timeStamp: const Duration(milliseconds: 24));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(committed, 5);
  });

  testWidgets('release momentum carries into the settle spring', (tester) async {
    // Identical pinches released at the same level — once with a live
    // forward velocity, once held nearly still — commit the same stop but
    // the carried spring converges onto the rest position sooner.
    // The morph focal is the item under the pinch centre at gesture
    // start — the scroll anchor, so it lands onscreen at settle. Read it
    // off the resting grid: whichever mid-gesture tile happens to sit
    // nearest the point may scroll out and leave nothing to compare.
    int? overlayIndex;
    int focalGridIndex(WidgetTester tester) {
      var index = -1;
      var best = double.infinity;
      for (final element in tester.elementList(
        find.byWidgetPredicate((w) => w.key is ValueKey<Object?> && (w.key! as ValueKey<Object?>).value is String),
      )) {
        final value = (element.widget.key! as ValueKey<Object?>).value! as String;
        if (!value.startsWith('item-')) continue;
        final rect = tester.getRect(find.byWidget(element.widget));
        final d = (rect.center - const Offset(200, 400)).distance;
        if (rect.contains(const Offset(200, 400)) && d < best) {
          best = d;
          index = int.parse(value.substring(5));
        }
      }
      return index;
    }

    Future<Rect> run({required bool fast}) async {
      var committed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CupertinoGrid(
              key: ValueKey('grid-$fast'),
              itemCount: 60,
              columnCounts: const [1, 3, 5],
              initialColumns: 3,
              onColumnsChanged: (columns) => committed = columns,
              itemKey: (index) => 'item-$index',
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      overlayIndex = focalGridIndex(tester);

      final f1 = await tester.createGesture();
      final f2 = await tester.createGesture();
      await f1.down(const Offset(140, 400));
      await f2.down(const Offset(260, 400));
      await tester.pump();
      // Contract the spread to land ~2/3 into the 3 -> 5 interval.
      await f1.moveTo(const Offset(160, 400), timeStamp: const Duration(milliseconds: 16));
      await f2.moveTo(const Offset(240, 400), timeStamp: const Duration(milliseconds: 16));
      await tester.pump();
      if (fast) {
        // Still contracting at release: velocity points at the 5-stop.
        await f1.moveTo(const Offset(162, 400), timeStamp: const Duration(milliseconds: 32));
        await f2.moveTo(const Offset(238, 400), timeStamp: const Duration(milliseconds: 32));
      } else {
        // Slight reverse at lift-off: velocity away from the target stop is
        // direction-clamped, so this settle starts at ~zero carry.
        await f1.moveTo(const Offset(158, 400), timeStamp: const Duration(milliseconds: 160));
        await f2.moveTo(const Offset(242, 400), timeStamp: const Duration(milliseconds: 160));
      }
      await tester.pump();
      await f1.up();
      await f2.up();
      // Mid-settle probe: the spring is ~300ms, so 80ms in the carried
      // run should already be measurably closer to the rest rect. Compare
      // tile widths — the level channel — since centre distance also
      // measures the still-parked position and inverts on tile size.
      await tester.pump(const Duration(milliseconds: 80));
      final mid = tester.getRect(find.byKey(ValueKey('tile|item-$overlayIndex')));
      await tester.pumpAndSettle();
      expect(committed, 5);
      return mid;
    }

    final slowMid = await run(fast: false);
    final restRect = tester.getRect(find.byKey(ValueKey<Object?>('item-$overlayIndex')));
    final fastMid = await run(fast: true);

    expect((fastMid.width - restRect.width).abs(), lessThan((slowMid.width - restRect.width).abs()));
  });

  testWidgets('lift-off wobble past the midpoint still settles on the nearer stop', (tester) async {
    // Regression: releasing a pinch-in jitters the spread back a few
    // pixels; the trailing reverse-velocity samples counted as a reverse
    // flick, so a release ~60% into the transition bounced back to the
    // start stop instead of landing on the nearer one.
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    // ~70% into the 3->5 transition.
    await f1.moveTo(const Offset(158, 400), timeStamp: const Duration(milliseconds: 16));
    await f2.moveTo(const Offset(242, 400), timeStamp: const Duration(milliseconds: 32));
    // Lift-off wobble: two fast reverse jitters — the level stays past
    // the midpoint but the flick estimate flips sign.
    await f2.moveTo(const Offset(246, 400), timeStamp: const Duration(milliseconds: 37));
    await f1.moveTo(const Offset(156, 400), timeStamp: const Duration(milliseconds: 42));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(committed, 5);
  });

  testWidgets('slow pinch-in release past the momentum threshold springs back', (tester) async {
    // Same rule on the denser side: ~30% into the 3->5 transition is past
    // _commitThreshold, but a slow release lands on the nearer stop.
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(155, 400));
    await f2.moveTo(const Offset(258, 400));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(committed, 0);
  });

  testWidgets('a second pinch landing mid-settle interrupts and morphs again', (tester) async {
    var committed = 0;
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            scrollController: controller,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // First pinch contracts 3 -> 5.
    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(180, 400));
    await f2.moveTo(const Offset(220, 400));
    await tester.pump();
    await f1.up();
    await f2.up();
    // A few frames into the settle/fade window — _morphActive still true.
    await tester.pump(const Duration(milliseconds: 60));

    // Second pinch spreads back out during that window — it must
    // interrupt the settle, not be ignored for its whole lifetime.
    // ~1.7x spread ≈ one stop back toward 3 columns.
    final g1 = await tester.createGesture();
    final g2 = await tester.createGesture();
    await g1.down(const Offset(170, 400));
    await g2.down(const Offset(230, 400));
    await tester.pump();
    await g1.moveTo(const Offset(160, 400));
    await g2.moveTo(const Offset(262, 400));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    expect(committed, 3);
  });

  Widget buildGrid({required int itemCount, void Function(Set<int>)? onVisibleItemsChanged}) {
    return MaterialApp(
      home: Scaffold(
        body: CupertinoGrid(
          itemCount: itemCount,
          columnCounts: const [1, 3, 5],
          initialColumns: 3,
          onVisibleItemsChanged: onVisibleItemsChanged,
          itemKey: (index) => 'item-$index',
          itemBuilder: (context, index, targetSize) =>
              ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
        ),
      ),
    );
  }

  testWidgets('a third finger mid-pinch never perturbs the engaged pair', (tester) async {
    // The recognizer locks the first two pointers as the gesture pair —
    // the old mean-of-all-pointers focal and first↔last span let a third
    // finger move the focal AND change the scale basis at once.
    var visibleChanges = 0;
    await tester.pumpWidget(buildGrid(itemCount: 200, onVisibleItemsChanged: (_) => visibleChanges++));
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    final f3 = await tester.createGesture();
    await f1.down(const Offset(160, 400));
    await f2.down(const Offset(240, 400));
    await tester.pump();
    // Engage the morph — the pair is locked from here.
    await f1.moveTo(const Offset(140, 400));
    await f2.moveTo(const Offset(260, 400));
    await tester.pump();
    expect(visibleChanges, greaterThan(0));
    visibleChanges = 0;

    // The third finger lands and sweeps the screen: it must not move the
    // focal, change the scale, or morph a single tile.
    await f3.down(const Offset(200, 200));
    await tester.pump();
    await f3.moveTo(const Offset(400, 600));
    await tester.pump();
    await f3.moveTo(const Offset(20, 620));
    await tester.pump();
    expect(visibleChanges, 0);

    // Lifting the extra finger is equally inert, and the locked pair
    // keeps morphing afterwards.
    await f3.up();
    await tester.pump();
    await f1.moveTo(const Offset(180, 400));
    await tester.pump();
    expect(visibleChanges, greaterThan(0));

    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();
  });

  testWidgets('lifting an engaged finger ends the pinch even with an extra finger down', (tester) async {
    // Removal of a PAIR member ends the gesture deterministically —
    // remaining fingers (pair survivor or swallowed extras) must not keep
    // morphing or silently re-form a pair.
    var visibleChanges = 0;
    await tester.pumpWidget(buildGrid(itemCount: 200, onVisibleItemsChanged: (_) => visibleChanges++));
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    final f3 = await tester.createGesture();
    await f1.down(const Offset(160, 400));
    await f2.down(const Offset(240, 400));
    await tester.pump();
    await f1.moveTo(const Offset(140, 400));
    await f2.moveTo(const Offset(260, 400));
    await tester.pump();

    await f3.down(const Offset(200, 200));
    await tester.pump();
    await f1.up();
    // The end-of-gesture settle runs its course before we observe.
    await tester.pumpAndSettle();
    visibleChanges = 0;

    // The gesture is dead: neither the surviving pair member nor the
    // extra finger can keep it alive.
    await f2.moveTo(const Offset(320, 400));
    await tester.pump();
    await f3.moveTo(const Offset(80, 600));
    await tester.pump();
    expect(visibleChanges, 0);

    await f2.up();
    await f3.up();
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling an engaged finger ends the pinch with no stale state', (tester) async {
    var visibleChanges = 0;
    await tester.pumpWidget(buildGrid(itemCount: 200, onVisibleItemsChanged: (_) => visibleChanges++));
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(160, 400));
    await f2.down(const Offset(240, 400));
    await tester.pump();
    await f1.moveTo(const Offset(140, 400));
    await f2.moveTo(const Offset(260, 400));
    await tester.pump();

    await f1.cancel(); // PointerCancelEvent — same end path as an up.
    await tester.pumpAndSettle();
    visibleChanges = 0;
    await f2.moveTo(const Offset(340, 400));
    await tester.pump();
    expect(visibleChanges, 0);
    await f2.up();
    await tester.pumpAndSettle();

    // A fresh pair pinches again — no wedged positions from the cancel.
    final g1 = await tester.createGesture();
    final g2 = await tester.createGesture();
    await g1.down(const Offset(160, 400));
    await g2.down(const Offset(240, 400));
    await tester.pump();
    await g1.moveTo(const Offset(140, 400));
    await g2.moveTo(const Offset(260, 400));
    await tester.pump();
    expect(visibleChanges, greaterThan(0));
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a second clean pinch after full settle re-engages and commits', (tester) async {
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // First pinch contracts 3 -> 5; after a FULL settle the second pinch
    // must re-engage from scratch and spread back 5 -> 3.
    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(180, 400));
    await f2.moveTo(const Offset(220, 400));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();
    expect(committed, 5);

    final g1 = await tester.createGesture();
    final g2 = await tester.createGesture();
    await g1.down(const Offset(140, 400));
    await g2.down(const Offset(260, 400));
    await tester.pump();
    await g1.moveTo(const Offset(110, 400));
    await g2.moveTo(const Offset(290, 400));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();
    expect(committed, 3);
  });

  test('style hot-swap applies to subsequent engine reads', () {
    // Every PinchMorphStyle knob is read lazily at the point of use — a
    // morph mid-flight computes on the NEW style's next frame, never on
    // constants captured by the old one.
    final morph = PinchMorph(style: const PinchMorphStyle(rubberBand: 0.35));
    morph.begin(
      stops: [MorphGridStop(3, 390, spacing: 2, aspect: 1), MorphGridStop(5, 390, spacing: 2, aspect: 1)],
      startStop: 0,
      focalIndex: 10,
      focalFraction: const Offset(0.5, 0.5),
      focalPoint: const Offset(195, 350),
      startScroll: 0,
      minScroll: 0,
      trailing: 0,
      itemCount: 200,
      origin: 0,
      headerOrigin: 0,
      viewport: const Size(390, 700),
    );
    // Past the largest-tile stop, levelForLogTile returns an overscale
    // rubber-banded by style.rubberBand — same input, stiffer band, more
    // resistance once the style is swapped.
    final pastFirst = morph.logTileWidth(0) + 1;
    final soft = morph.levelForLogTile(pastFirst).$2;
    morph.style = const PinchMorphStyle(rubberBand: 1.0);
    final firm = morph.levelForLogTile(pastFirst).$2;
    expect(soft, greaterThan(1));
    expect(firm, greaterThan(soft));
  });

  testWidgets('style swap mid-gesture and mid-settle keeps a consistent configuration', (tester) async {
    // didUpdateWidget pushes widget.style into the engine (mutable style
    // field) — the overlay render object reads the same widget.style —
    // so a hot-swap can't leave geometry and paint on different knobs.
    var committed = 0;
    Widget grid(PinchMorphStyle style) => MaterialApp(
      home: Scaffold(
        body: CupertinoGrid(
          itemCount: 60,
          columnCounts: const [1, 3, 5],
          initialColumns: 3,
          style: style,
          onColumnsChanged: (columns) => committed = columns,
          itemKey: (index) => 'item-$index',
          itemBuilder: (context, index, targetSize) =>
              ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
        ),
      ),
    );
    await tester.pumpWidget(grid(const PinchMorphStyle()));
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(180, 400));
    await f2.moveTo(const Offset(220, 400));
    await tester.pump();
    // Swap mid-GESTURE — fingers still down, morph active.
    await tester.pumpWidget(grid(const PinchMorphStyle(reflowWindow: 0.15, coverageBlendSpan: 0.5)));
    await f1.moveTo(const Offset(190, 400));
    await f2.moveTo(const Offset(210, 400));
    await tester.pump();
    await f1.up();
    await f2.up();
    // Swap again mid-SETTLE before the glide finishes.
    await tester.pumpWidget(grid(const PinchMorphStyle(rubberBand: 0.9)));
    await tester.pumpAndSettle();
    expect(committed, 5);
  });

  testWidgets('pillExtent drives the rendered pill band — before and after a style swap', (tester) async {
    // The rest-state layer and the overlay render object both pin pills
    // to style.pillExtent — a deliberately 999px-tall custom pill is
    // clipped to the band, and a style swap resizes it on relayout.
    Widget grid(double extent) => MaterialApp(
      home: Scaffold(
        body: CupertinoGrid(
          itemCount: 60,
          columnCounts: const [3, 9],
          initialColumns: 9,
          minLabelColumns: 9,
          style: PinchMorphStyle(pillExtent: extent),
          sectionLabelFor: (index) => index % 18 == 0 ? 'section-$index' : null,
          sectionLabelBuilder: (context, label) => SizedBox(key: ValueKey('pill-$label'), height: 999),
          itemKey: (index) => 'item-$index',
          itemBuilder: (context, index, targetSize) =>
              ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
        ),
      ),
    );
    await tester.pumpWidget(grid(26));
    await tester.pumpAndSettle();

    Size pillSize() => tester.renderObject<RenderBox>(find.byKey(const ValueKey('pill-section-0'))).size;
    expect(pillSize().height, 26);

    await tester.pumpWidget(grid(40));
    await tester.pumpAndSettle();
    expect(pillSize().height, 40);
  });

  test('reversed restScrolls pin the mirrored focal point', () {
    // Regression: begin() mirrored this.focal/this.fraction but computed
    // restScrolls from the UNMIRRORED parameters — on a reversed axis the
    // settle glide targeted a scroll offset mirrored about the viewport
    // while the commit jump used the mirrored formula, snapping the grid
    // by ~2×(focal − screen center) on release.
    final morph = PinchMorph();
    const viewport = Size(390, 700);
    final stops = [MorphGridStop(1, 390, spacing: 2, aspect: 0.75), MorphGridStop(3, 390, spacing: 2, aspect: 1)];
    morph.begin(
      stops: stops,
      startStop: 1,
      focalIndex: 7,
      focalFraction: const Offset(0.4, 0.3),
      focalPoint: const Offset(120, 620),
      startScroll: 50,
      minScroll: 0,
      trailing: 118,
      itemCount: 200,
      origin: 119,
      headerOrigin: 0,
      viewport: viewport,
      reversed: true,
    );

    // Mirrored fields: focal' = (120, 80) — the touch point itself, with
    // only y flipped about the viewport (the pivot is the live finger
    // midpoint, not the cell centre) — fraction' = (0.4, 0.7).
    expect(morph.focalPoint, offsetMoreOrLessEquals(const Offset(120, 80), epsilon: 1e-6));
    expect(morph.focalFraction, const Offset(0.4, 0.7));
    final expected = stops[0].tileRect(7, 119, 200).top + 0.7 * stops[0].tileHeight - 80;
    expect(morph.restScrolls[0], closeTo(expected, 1e-6));
  });

  test('lattice glides continuously across the screen-height boundary', () {
    // Regression: pinching a library that FITS the screen at the dense end
    // (13 rows of 16 << viewport) pivoted the lattice ~35px in one step —
    // the coverage clamp switched from the top-anchored position to the
    // pinched one the instant the blended content outgrew the band, and
    // the grid visibly hopped down mid-gesture. The handoff now eases
    // over a slice of the interval around the solved crossing.
    const viewport = Size(390, 844);
    final stops = [
      for (final c in [1, 3, 5, 16]) MorphGridStop(c, 390, spacing: 2, aspect: c == 1 ? 4 / 3 : 1, mirrorRows: true),
    ];
    const count = 198; // 13 rows at 16 columns — shorter than the band
    final morph = PinchMorph()
      ..begin(
        stops: stops,
        startStop: 3,
        focalIndex: 30,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 600),
        startScroll: 0,
        minScroll: 0,
        trailing: 60,
        itemCount: count,
        origin: 300,
        headerOrigin: 0,
        viewport: viewport,
        reversed: true,
        centerFocal: true,
      );

    double focalY(double level) {
      morph.set(level: level);
      final tile = morph
          .frame((_) => false)
          .tiles
          .firstWhere((t) => t.index == 30 && t.rowOffset == 0 && t.columnOffset == 0);
      return tile.rect.center.dy;
    }

    for (final (from, to) in [(3.0, 2.0), (2.0, 3.0)]) {
      final dir = (to - from).sign;
      final step = 0.01 * dir;
      var prev = focalY(from);
      var maxStep = 0.0;
      for (var l = from + step; (to - l) * dir >= -1e-9; l += step) {
        final y = focalY(l);
        maxStep = math.max(maxStep, (y - prev).abs());
        prev = y;
      }
      expect(maxStep, lessThan(12), reason: 'focal tile moved ${maxStep}px in a 0.01-level step');
    }
  });

  PinchMorph begunMorph({int itemCount = 200, int startStop = 1, int focalIndex = 10, double startScroll = 0}) {
    return PinchMorph()..begin(
      stops: [MorphGridStop(3, 390, spacing: 2, aspect: 1), MorphGridStop(5, 390, spacing: 2, aspect: 1)],
      startStop: startStop,
      focalIndex: focalIndex,
      focalFraction: const Offset(0.5, 0.5),
      focalPoint: const Offset(195, 350),
      startScroll: startScroll,
      minScroll: 0,
      trailing: 0,
      itemCount: itemCount,
      origin: 0,
      headerOrigin: 0,
      viewport: const Size(390, 700),
    );
  }

  test('a one-item library emits its single tile and nothing else', () {
    final morph = begunMorph(itemCount: 1, startStop: 0, focalIndex: 0);
    for (final level in [0.0, 0.5, 1.0]) {
      morph.set(level: level);
      final tiles = morph.frame((_) => false).tiles;
      expect(tiles.every((t) => t.index == 0), isTrue, reason: 'level $level emitted items that do not exist');
      expect(tiles.every((t) => t.rect.isFinite), isTrue);
    }
  });

  test('a huge library still emits only the visible window — frame cost is viewport-bound', () {
    // The emit loop walks the union of the two lattices' visible windows,
    // not the item list: 50k items must not turn frame() into a full
    // scan or the gesture would stall on large libraries. The pinch is
    // parked ON the focal — startScroll places item 25000 under the
    // finger, as a real gesture does.
    final startStop = MorphGridStop(5, 390, spacing: 2, aspect: 1);
    final parkedScroll = startStop.tileTop(25000, 0) + 0.5 * startStop.tileHeight - 350;
    final morph = begunMorph(itemCount: 50000, focalIndex: 25000, startScroll: parkedScroll);
    morph.set(level: 0.5);
    final tiles = morph.frame((_) => false).tiles;
    expect(tiles, isNotEmpty);
    expect(tiles.length, lessThan(400));
    expect(tiles.every((t) => t.index >= 0 && t.index < 50000), isTrue);
  });

  test('every emitted targetSize is one of the two stop tile widths', () {
    // Thumbnail contract (audit, plan §6): stable tiles always carry the
    // LARGER stop's width — one decode covers both ends of the morph with
    // no upscale — while arriving ghosts carry the denser stop's. A size
    // outside the pair would mean a third decode bucket slipped in.
    final morph = begunMorph();
    final stops = morph.stops;
    final allowed = {for (final s in stops) s.tileWidth.ceil()};
    for (var l = 0.0; l <= 1.0; l += 0.1) {
      morph.set(level: l);
      for (final tile in morph.frame((_) => false).tiles) {
        expect(allowed, contains(tile.targetSize), reason: 'level $l emitted targetSize ${tile.targetSize}');
      }
    }
  });

  testWidgets('a viewport resize mid-settle completes to a valid stop', (tester) async {
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(const Offset(140, 400));
    await f2.down(const Offset(260, 400));
    await tester.pump();
    await f1.moveTo(const Offset(180, 400));
    await f2.moveTo(const Offset(220, 400));
    await tester.pump();
    await f1.up();
    await f2.up();

    // Rotation-class event mid-settle: the surface resizes while the
    // spring is running — geometry must rebuild around the settle, not
    // wedge or throw.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();

    expect(committed, 5);
    expect(tester.takeException(), isNull);
  });

  test('release glides from a clamped park without dipping below rest', () {
    // Regression: releasing mid-interval after the coverage clamp had
    // moved the lattice plunged the focal tile ~120px BELOW its rest
    // slot, then pulled it back — the clip edge the clamp measures eases
    // with the header during settle, so the anchored/cap targets chased
    // a collapsing band mid-settle (the down-then-up wobble on release).
    // The settle now glides the latched parked position straight to rest.
    const viewport = Size(390, 844);
    final stops = [
      for (final c in [1, 3, 5, 16]) MorphGridStop(c, 390, spacing: 2, aspect: c == 1 ? 4 / 3 : 1, mirrorRows: true),
    ];
    const count = 198; // 13 rows at 16 columns — shorter than the band
    final morph = PinchMorph()
      ..begin(
        stops: stops,
        startStop: 3,
        focalIndex: 30,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 600),
        startScroll: 0,
        minScroll: 0,
        trailing: 60,
        itemCount: count,
        origin: 300,
        headerOrigin: 0,
        viewport: viewport,
        reversed: true,
        centerFocal: true,
      )
      ..settleStop = 2;

    double focalY() {
      final tile = morph
          .frame((_) => false)
          .tiles
          .firstWhere((t) => t.index == 30 && t.rowOffset == 0 && t.columnOffset == 0);
      return tile.rect.center.dy;
    }

    // Park mid-interval — the coverage clamp holds the lattice against
    // the band edge, the position the release starts from — then take
    // the settled end as the reference the glide must not overshoot.
    morph.set(level: 2.8, pin: 1);
    final parked = focalY();
    morph.set(level: 2.0, pin: 0);
    final rest = focalY();

    var prev = parked;
    var maxOvershoot = 0.0;
    var maxStep = 0.0;
    for (var p = 0.95; p > -1e-9; p -= 0.05) {
      final pin = p.clamp(0.0, 1.0);
      // The release spring eases the level to the settle stop as pin falls.
      morph.set(level: 2.8 - 0.8 * (1 - pin), pin: pin);
      final y = focalY();
      maxOvershoot = math.max(maxOvershoot, (y - rest) * (rest - parked).sign);
      maxStep = math.max(maxStep, (y - prev).abs());
      prev = y;
    }
    expect(
      maxOvershoot,
      lessThan(2),
      reason: 'focal tile dipped ${maxOvershoot.toStringAsFixed(1)}px past its rest position',
    );
    expect(maxStep, lessThan(30), reason: 'focal tile moved ${maxStep.toStringAsFixed(1)}px in a 0.05-pin step');
  });

  test('edge pinch: coverage floor never drags the lattice past a rest margin', () {
    // Regression from an on-device trace (5→16 zoom-out, focal one row from
    // the leading edge): coverageLeading eased the band floor ~70px deeper
    // than the margin every rest layout leaves, so the coverage push dragged
    // the whole lattice ~200px off the finger, then the settle and the
    // commit's rest re-aim each snapped a leg of the return — the up/down
    // wobble on release. The floors are now capped by the margins the rest
    // layouts leave, so an edge pinch rides its parked margin and lands
    // with no manufactured excursion to glide back out of.
    const viewport = Size(390, 844);
    final stops = [
      for (final c in [1, 3, 5, 16]) MorphGridStop(c, 390, spacing: 2, aspect: 1),
    ];
    const count = 709;
    const origin = 100.0;
    // Parked at the leading edge: scroll-space row 0 shows at ~95 — the same
    // sliver every rest layout leaves inside the band.
    const scroll = 5.0;
    const focal = Offset(195, 274);
    final start = stops[2];
    final fi = start.indexAt(focal + const Offset(0, scroll), count, origin);
    final fr = start.tileRect(fi, origin, count).shift(const Offset(0, -scroll));
    final morph = PinchMorph()
      ..begin(
        stops: stops,
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
        viewport: viewport,
        coverageLeading: 25,
      );
    addTearDown(morph.dispose);

    double? focalTop() {
      final tiles = morph
          .frame((_) => false)
          .tiles
          .where((t) => t.index == fi && t.rowOffset == 0 && t.columnOffset == 0);
      return tiles.isEmpty ? null : tiles.first.rect.top;
    }

    // The destination rest parks the focal's row at the leading margin —
    // the position the whole arc must never dip below.
    morph.settleStop = 3;
    morph.set(level: 3.0, pin: 0);
    final restTop = focalTop()!;

    var lowest = double.infinity;
    var culled = false;
    for (var l = 2.0; l <= 3.0 + 1e-9; l += 0.02) {
      morph.set(level: math.min(l, 3.0), pin: 1);
      final top = focalTop();
      if (top == null) {
        culled = true;
      } else {
        lowest = math.min(lowest, top);
      }
    }
    // Without the bound the push drove the emitted focal past the bezel —
    // culled from the band entirely — then the settle had to fly it back
    // to the rest margin. The parked-margin floor keeps the whole arc
    // inside ~5px of the landing edge.
    expect(culled, isFalse, reason: 'the pinched tile left the band mid-gesture');
    expect(
      lowest,
      greaterThanOrEqualTo(restTop - 10),
      reason: 'edge pinch dragged the focal ${(restTop - lowest).toStringAsFixed(1)}px below its landing rest margin',
    );
  });

  test('pinch commits keep the focal\'s screen column, clamped at the list edges', () {
    // iOS Photos re-chunks the ribbon around the pinch in BOTH directions:
    // the row boundaries slide so the focal photo keeps its screen column —
    // leading edge → column 0, trailing edge → the last column, interior →
    // the centre — clamped only when the list can't fill the flanks.
    // The commit is a column phase: leading holes that put the focal's
    // slot on the preserved column.
    MorphGridStop landedStop(int fromColumns, int toColumns, int focal, int itemCount, {bool mirror = false}) {
      final low = math.min(fromColumns, toColumns);
      final high = math.max(fromColumns, toColumns);
      final stops = [
        MorphGridStop(low, 390, spacing: 2, aspect: 1, mirrorRows: mirror),
        MorphGridStop(high, 390, spacing: 2, aspect: 1, mirrorRows: mirror),
      ];
      final start = fromColumns < toColumns ? 0 : 1;
      final morph = PinchMorph()
        ..begin(
          stops: stops,
          startStop: start,
          focalIndex: focal,
          focalFraction: const Offset(0.5, 0.5),
          focalPoint: const Offset(195, 400),
          startScroll: 0,
          minScroll: 0,
          trailing: 0,
          itemCount: itemCount,
          origin: 0,
          headerOrigin: 0,
          viewport: const Size(390, 800),
          centerFocal: true,
        );
      return morph.stops[1 - start];
    }

    int landedColumn(int from, int to, int focal, int itemCount, {bool mirror = false}) =>
        landedStop(from, to, focal, itemCount, mirror: mirror).columnOf(focal, itemCount);

    // The items sharing the focal's committed row — the visible shape of
    // the re-chunk.
    List<int> landedRow(int from, int to, int focal, int itemCount) {
      final stop = landedStop(from, to, focal, itemCount);
      final base = stop.rowOf(focal) * stop.columns;
      return [for (var c = 0; c < stop.columns; c++) stop.itemAt(base + c, itemCount)];
    }

    // The measured Photos maps (indices ascend left-to-right here; Photos'
    // descending display is the mirrored variant covered below).
    //
    // Zoom-in 5→3 on row |30 31 32 33 34|: the pinched photo keeps its
    // screen position — it lands on the column nearest to where it
    // started, so 31/32/33 all converge on the |31 32 33| window, each at
    // its own column.
    expect(landedRow(5, 3, 30, 60), [30, 31, 32]);
    expect(landedColumn(5, 3, 30, 60), 0);
    expect(landedRow(5, 3, 31, 60), [31, 32, 33]);
    expect(landedColumn(5, 3, 31, 60), 0);
    expect(landedRow(5, 3, 32, 60), [31, 32, 33]);
    expect(landedColumn(5, 3, 32, 60), 1);
    expect(landedRow(5, 3, 33, 60), [31, 32, 33]);
    expect(landedColumn(5, 3, 33, 60), 2);
    expect(landedRow(5, 3, 34, 60), [32, 33, 34]);
    expect(landedColumn(5, 3, 34, 60), 2);
    //
    // Zoom-out 3→5 on row |30 31 32|: the block stays contiguous and
    // lands so the focal keeps its column — left, centre, right.
    expect(landedRow(3, 5, 30, 60), [30, 31, 32, 33, 34]);
    expect(landedColumn(3, 5, 30, 60), 0);
    expect(landedRow(3, 5, 31, 60), [29, 30, 31, 32, 33]);
    expect(landedColumn(3, 5, 31, 60), 2);
    expect(landedRow(3, 5, 32, 60), [28, 29, 30, 31, 32]);
    expect(landedColumn(3, 5, 32, 60), 4);

    // Zoom-in from a dense start: positions hold — the left ~third of the
    // start row lands left, the middle third centre, the right third
    // right — only the list edges clamp.
    expect(landedColumn(16, 3, 0, 5), 0); // |0|1|2| — head keeps the left edge
    expect(landedColumn(16, 3, 1, 5), 0); // |1|2|3| — col1 of 16 sits in the left third
    expect(landedColumn(16, 3, 2, 5), 0); // |2|3|4| — still left third
    expect(landedColumn(16, 3, 3, 5), 1); // |2|3|4| — tail clamp: only one item after it
    expect(landedColumn(16, 3, 4, 5), 2); // |2|3|4| — tail keeps the right edge
    // Deep list: the start row splits into thirds — left lands left,
    // middle centre, right right.
    expect(landedColumn(16, 3, 18, 48), 0); // col2 of 16 — the left third
    expect(landedColumn(16, 3, 0, 48), 0); // 16-col c0 — leading edge pins
    expect(landedColumn(16, 3, 47, 48), 2); // 16-col c15 — trailing edge pins
    // The same rule at 5 columns — the start row splits into fifths.
    expect(landedColumn(16, 5, 18, 48), 0); // col2 of 16 — the left fifth
    expect(landedColumn(16, 5, 1, 48), 0); // col1 — head keeps the left edge
    expect(landedColumn(16, 5, 46, 48), 4); // col14 — tail keeps the right edge
    // A single-column landing has nowhere to land — phase stays 0.
    expect(landedStop(16, 1, 7, 200).phase, 0);

    // Mirrored rows: columnOf reports the VISUAL column, so the same
    // keep-position rule reads against the display — the cell beside the
    // right edge keeps the right side; list-edge clamps swap sides.
    expect(landedColumn(16, 3, 0, 5, mirror: true), 2); // |2 1 0| — head right
    expect(landedColumn(16, 3, 1, 5, mirror: true), 1); // |2 1 0| — col3 targets left, tail clamp pulls to centre
    expect(landedColumn(16, 3, 2, 5, mirror: true), 0); // |2 1 0| — col2 is in the left third
    expect(landedColumn(16, 3, 3, 5, mirror: true), 0); // |3 2 1| — col1 too
    expect(landedColumn(16, 3, 4, 5, mirror: true), 0); // |4 3 2| — tail left
    expect(landedColumn(16, 3, 18, 48, mirror: true), 2); // col13 — the right third
    expect(landedColumn(16, 5, 18, 48, mirror: true), 4); // col13 — the right fifth
    expect(landedColumn(16, 3, 0, 48, mirror: true), 2);
    expect(landedColumn(16, 3, 47, 48, mirror: true), 0);
    // The mirrored 3→5 map — Photos' own descending display: the row
    // |32 31 30| keeps its block contiguous at the focal's edge.
    expect(landedColumn(3, 5, 32, 60, mirror: true), 0); // |32 31 30 …| left
    expect(landedColumn(3, 5, 31, 60, mirror: true), 2); // |… 31 …| centred
    expect(landedColumn(3, 5, 30, 60, mirror: true), 4); // |… 30| right
    // The video case — a mirrored 5-col row displays |34 33 32 31 30|;
    // pinching the cell beside the left edge (display col1 = index 33)
    // keeps that side: it lands the left column of |33 32 31|.
    expect(landedColumn(5, 3, 33, 60, mirror: true), 0);
  });

  testWidgets('committed grid keeps the pinched item on its side — no handoff jump', (tester) async {
    // Pinch apart on item 8 at 5 columns (right-of-centre column): the
    // 3-column commit lands it on the trailing edge — phase 0 keeps it
    // nearest its start column — so the real grid reveals |6 7 8|
    // exactly where the overlay glided to.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 5,
            centerFocalOnCommit: true,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) => ColoredBox(
              key: ValueKey<Object?>('tile-$index'),
              color: Colors.primaries[index % Colors.primaries.length],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = tester.getRect(find.byKey(const ValueKey<Object?>('tile-8')));
    // Test surface is 800 wide: at 5 columns item 8 sits in column 3.
    expect(before.center.dx, greaterThan(500));

    // A gentle ~1.5× spread lands mid-interval — the settle commits to 3.
    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(before.center - const Offset(20, 0));
    await f2.down(before.center + const Offset(20, 0));
    await tester.pump();
    await f1.moveTo(before.center - const Offset(30, 0));
    await f2.moveTo(before.center + const Offset(30, 0));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    // 3-col with phase 0: item 8 occupies slot 8 → row 2, trailing column
    // — |6 7 8| with the zoomed photo holding the edge nearest its start.
    final after = tester.getRect(find.byKey(const ValueKey<Object?>('tile-8')));
    expect(after.center.dx, closeTo(666, 30));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-6'))).center.dx, closeTo(134, 30));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-7'))).center.dx, closeTo(400, 30));

    // The phase is grid state, not a morph artifact: scroll away and back
    // and the re-chunked rows still hold — iOS keeps it until the next
    // pinch re-phases.
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final restOffset = scrollable.position.pixels;
    scrollable.position.jumpTo(restOffset + 1500);
    await tester.pumpAndSettle();
    scrollable.position.jumpTo(restOffset);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-6'))).center.dx, closeTo(134, 30));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-7'))).center.dx, closeTo(400, 30));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-8'))).center.dx, closeTo(666, 30));
  });

  testWidgets('zoom-out commit re-chunks around the focal — trailing edge holds', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var committed = 3;
    // Pinch IN on item 8 at 3 columns (trailing column, canonical): iOS
    // keeps the edge — the 5-column commit lands it at the last column of
    // the re-chunked row |4 5 6 7 8|.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            centerFocalOnCommit: true,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) => ColoredBox(
              key: ValueKey<Object?>('tile-$index'),
              color: Colors.primaries[index % Colors.primaries.length],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = tester.getRect(find.byKey(const ValueKey<Object?>('tile-8')));
    // Converge the fingers in three steps — the tile needs to shrink past
    // the interval midpoint (ratio ~0.61 carries 3→5 with margin).
    const downHalf = 36.0;
    const effective = 0.61;
    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(before.center - const Offset(downHalf, 0));
    await f2.down(before.center + const Offset(downHalf, 0));
    await tester.pump();
    for (var step = 1; step <= 3; step++) {
      final half = downHalf * math.exp(math.log(effective) * step / 3);
      await f1.moveTo(before.center - Offset(half, 0));
      await f2.moveTo(before.center + Offset(half, 0));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();
    expect(committed, 5, reason: 'converging pinch must commit 3→5');

    // 5-col phase 1: item 8 sits at slot 9 → row 1, last column —
    // |4 5 6 7 8| with the pinched photo holding its trailing edge.
    final after = tester.getRect(find.byKey(const ValueKey<Object?>('tile-8')));
    expect(after.center.dx, closeTo(720, 30));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-4'))).center.dy, closeTo(after.center.dy, 2));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-5'))).center.dy, closeTo(after.center.dy, 2));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-6'))).center.dy, closeTo(after.center.dy, 2));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-7'))).center.dy, closeTo(after.center.dy, 2));
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-9'))).top, greaterThan(after.bottom));
  });

  testWidgets('straddled pinch resolves the first finger\'s tile, not the midpoint\'s', (tester) async {
    // Finger 1 lands just inside tile 8's left edge, finger 2 lands deep
    // in tile 7 — the midpoint sits inside 7, but the pinch must zoom the
    // tile the FIRST touch claimed: the focal resolves per finger, and a
    // straddle breaks toward the chronologically-first tile.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 5,
            centerFocalOnCommit: true,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) => ColoredBox(
              key: ValueKey<Object?>('tile-$index'),
              color: Colors.primaries[index % Colors.primaries.length],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final r8 = tester.getRect(find.byKey(const ValueKey<Object?>('tile-8')));
    final r7 = tester.getRect(find.byKey(const ValueKey<Object?>('tile-7')));

    final f1 = await tester.createGesture();
    final f2 = await tester.createGesture();
    await f1.down(Offset(r8.left + 6, r8.center.dy));
    await f2.down(r7.center);
    await tester.pump();
    // Spread apart — midpoint of the down positions is inside tile 7.
    await f1.moveTo(Offset(r8.left + 36, r8.center.dy));
    await f2.moveTo(Offset(r7.center.dx - 30, r7.center.dy));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    // Item 8 keeps its right-of-centre column — phase 0 lands it on the
    // trailing edge of |6 7 8| — not the midpoint tile's centre landing.
    expect(tester.getRect(find.byKey(const ValueKey<Object?>('tile-8'))).center.dx, closeTo(666, 30));
  });

  testWidgets('reversed grid renders item 0 at the bottom edge', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 60,
            columnCounts: const [1, 3, 5],
            initialColumns: 3,
            reverse: true,
            scrollController: controller,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) =>
                ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(controller.offset, 0);

    // Scroll offset 0 anchors the bottom: item 0 sits in the lower half.
    final firstRect = tester.getRect(find.byKey(const ValueKey<Object?>('item-0')));
    expect(firstRect.center.dy, greaterThan(400));

    // Reversed axis: dragging content DOWN grows the offset — the
    // viewport travels toward the scroll-space end (older items slide
    // into view from the top edge).
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('mid-pinch itemCount shrink never hands the overlay a stale index', (tester) async {
    // A merge/stack-collapse landing mid-gesture shrinks itemCount under
    // the overlay — captured slots must be pruned before the item builder
    // dereferences an index the page no longer has (RangeError 372/371).
    var itemCount = 60;
    var sawOutOfRange = false;
    Widget host() => MaterialApp(
      home: Scaffold(
        body: CupertinoGrid(
          itemCount: itemCount,
          columnCounts: const [1, 3, 5],
          initialColumns: 3,
          itemKey: (index) => 'item-$index',
          itemBuilder: (context, index, targetSize) {
            if (index >= itemCount) sawOutOfRange = true;
            return const ColoredBox(color: Colors.blue);
          },
          overlayItemBuilder: (context, index, targetSize) {
            if (index >= itemCount) sawOutOfRange = true;
            return const ColoredBox(color: Colors.red);
          },
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(180, 400));
    await finger2.moveTo(const Offset(220, 400));
    await tester.pump();

    // The list shrinks while the morph overlay is live.
    itemCount = 20;
    await tester.pumpWidget(host());
    await finger1.moveTo(const Offset(190, 400));
    await finger2.moveTo(const Offset(210, 400));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    expect(sawOutOfRange, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('commit re-anchors the pinched item when the cell list reshapes', (tester) async {
    // Stack fold/unfold on density commit: at <=3 columns every group
    // member is its own cell; denser stops collapse each group to one
    // header. The pinch's focal index was captured against the expanded
    // list — jumping on it would land on a different photo entirely.
    const groups = 40;
    const members = 5;
    final density = ValueNotifier<int>(3);
    addTearDown(density.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);

    int cellCount() => density.value <= 3 ? groups * members : groups;
    Object? keyOf(int index) => density.value <= 3 ? 'm-${index ~/ members}-${index % members}' : 'h-$index';
    Object? anchorOf(int index) => 'g-${density.value <= 3 ? index ~/ members : index}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: density,
            builder: (context, _) => CupertinoGrid(
              itemCount: cellCount(),
              columnCounts: const [1, 3, 5],
              initialColumns: 3,
              scrollController: controller,
              onColumnsChanged: (columns) => density.value = columns,
              itemKey: keyOf,
              itemAnchorKey: anchorOf,
              itemBuilder: (context, index, targetSize) => ColoredBox(
                key: ValueKey<Object?>(keyOf(index)),
                color: Colors.primaries[index % Colors.primaries.length],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Index 76 = group 15's second member: row 25, column 1 at 3 columns,
    // so a scroll of 6262 puts its top edge at screen y 390.
    controller.jumpTo(6262);
    await tester.pump();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(390, 400));
    await finger2.down(const Offset(410, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(395, 400));
    await finger2.moveTo(const Offset(405, 400));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    // Group 15 collapsed to header index 15 → row 3 at 5 columns; the
    // committed scroll must put its pinch point back under the finger.
    // (A stale-index jump would land on old index 76 — clamped at the
    // bottom of the shrunken list, hundreds of pixels off.)
    expect(density.value, 5);
    expect(controller.offset, closeTo(86.8, 8));
  });

  testWidgets('commit keeps the pinched member under the finger, not its group header', (tester) async {
    // Expanded stacks: header cell precedes its members and shares their
    // anchor key. A pinch starting on a member must stay on THAT member
    // when the committed list still contains it — only a collapse that
    // removes the member may fall back to the header.
    const groups = 40;
    const members = 5;
    final density = ValueNotifier<int>(3);
    addTearDown(density.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);

    int cellCount() => groups * members;
    bool isHeader(int index) => index % members == 0;
    Object? keyOf(int index) => isHeader(index) ? 'h-${index ~/ members}' : 'm-${index ~/ members}-${index % members}';
    Object? anchorOf(int index) => 'g-${index ~/ members}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: density,
            builder: (context, _) => CupertinoGrid(
              itemCount: cellCount(),
              columnCounts: const [1, 3, 5],
              initialColumns: 3,
              scrollController: controller,
              onColumnsChanged: (columns) => density.value = columns,
              itemKey: keyOf,
              itemAnchorKey: anchorOf,
              itemBuilder: (context, index, targetSize) => ColoredBox(
                key: ValueKey<Object?>(keyOf(index)),
                color: Colors.primaries[index % Colors.primaries.length],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Index 9 = group 1's last member: row 3, column 0 at 3 columns — a
    // scroll of 500 puts its rect around screen y 400 at x 200.
    controller.jumpTo(500);
    await tester.pump();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    // Spread apart past the midpoint — zoom in towards the 1-column stop.
    await finger1.moveTo(const Offset(80, 400));
    await finger2.moveTo(const Offset(320, 400));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    // The pinch zoomed IN to the 1-column stop; stacks stay expanded, so
    // member 9 survives — its cell must still contain the release point.
    // Anchoring to group 1's header (index 5) would drop it offscreen.
    expect(density.value, 1);
    final member = tester.getRect(find.byKey(const ValueKey<Object?>('m-1-4')).first);
    expect(member.contains(const Offset(200, 400)), isTrue);
  });

  testWidgets('mid-settle insert keeps a pinched edge item on its edge column', (tester) async {
    // A cell inserted before the focal mid-settle — a stack unfolding a
    // member, a merge landing — shifts its index. The landing phase was
    // stamped at pinch start for the OLD index: it maps the moved item to
    // a different column, and the pinched edge photo lands one column in.
    // The settle must re-stamp the phase for the resolved index — the
    // edge keeps its edge.
    final cells = [for (var i = 0; i < 60; i++) 'item-$i'];
    var committed = 5;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => CupertinoGrid(
              itemCount: cells.length,
              columnCounts: const [1, 3, 5],
              initialColumns: 5,
              centerFocalOnCommit: true,
              onColumnsChanged: (columns) {
                committed = columns;
                // The density commit unfolds one member ahead of the
                // pinch's cell — every item after it shifts one index.
                if (cells.length == 60) {
                  setState(() => cells.insert(0, 'new-0'));
                }
              },
              itemKey: (index) => cells[index],
              itemBuilder: (context, index, targetSize) => ColoredBox(
                key: ValueKey<Object?>(cells[index]),
                color: Colors.primaries[index % Colors.primaries.length],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // item-9 sits at row 1, column 4 of the 5-column grid — the right edge.
    final before = tester.getRect(find.byKey(const ValueKey<Object?>('item-9')).first);
    expect(before.center.dx, greaterThan(600));
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(before.center - const Offset(20, 0));
    await finger2.down(before.center + const Offset(20, 0));
    await tester.pump();
    // A gentle ~1.5× spread lands mid-interval — the settle commits to 3.
    await finger1.moveTo(before.center - const Offset(30, 0));
    await finger2.moveTo(before.center + const Offset(30, 0));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    expect(committed, 3);
    // The head insert shifted item-9 to index 10. A phase still stamped
    // for index 9 lands it at the LEADING column — the re-stamped phase
    // puts it back on its trailing edge.
    final after = tester.getRect(find.byKey(const ValueKey<Object?>('item-9')).first);
    expect(after.center.dx, closeTo(666, 30));
  });

  testWidgets('mid-gesture insert keeps a pinched mirrored item on its landing column', (tester) async {
    // A reshape landing while the fingers are still DOWN resolves the
    // pinched item's new index while settleStop is still the start stop —
    // rephaseLanding's no-op case — so every destination keeps the phase
    // begin() stamped for the OLD index. Release then sees no index diff
    // and commits that stale phase: the photo lands a column off. The
    // release-time rephase must re-derive the destination for the
    // resolved index even though the index itself was already synced.
    final cells = [for (var i = 0; i < 60; i++) 'item-$i'];
    var committed = 5;
    StateSetter? rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return CupertinoGrid(
                itemCount: cells.length,
                columnCounts: const [1, 3, 5],
                initialColumns: 5,
                mirrorRows: true,
                centerFocalOnCommit: true,
                onColumnsChanged: (columns) => committed = columns,
                itemKey: (index) => cells[index],
                itemBuilder: (context, index, targetSize) => ColoredBox(
                  key: ValueKey<Object?>(cells[index]),
                  color: Colors.primaries[index % Colors.primaries.length],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Mirroring lays a full 5-column row out as 9,8,7,6,5 — item-7 still
    // sits at the centre column of row 1.
    final before = tester.getRect(find.byKey(const ValueKey<Object?>('item-7')).first);
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(before.center - const Offset(20, 0));
    await finger2.down(before.center + const Offset(20, 0));
    await tester.pump();
    await finger1.moveTo(before.center - const Offset(30, 0));
    await finger2.moveTo(before.center + const Offset(30, 0));
    await tester.pump();
    // The merge lands MID-GESTURE: fingers still down, settleStop still
    // the start stop. item-7 shifts to index 8.
    rebuild!(() => cells.insert(0, 'new-0'));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    expect(committed, 3);
    // A stale phase stamped for index 7 maps the moved item to the
    // adjacent column; the re-stamped phase lands index 8 back on the
    // centre column it started from.
    final after = tester.getRect(find.byKey(const ValueKey<Object?>('item-7')).first);
    expect(after.center.dx, closeTo(before.center.dx, 40));
  });

  testWidgets('pinch clamped to the densest stop stays dormant — no overlay tiles or image requests', (tester) async {
    var overlayBuilds = 0;
    var imageCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 200,
            columnCounts: const [1, 3, 5],
            initialColumns: 5,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) => const ColoredBox(color: Colors.blue),
            overlayItemBuilder: (context, index, targetSize) {
              overlayBuilds++;
              return const ColoredBox(color: Colors.red);
            },
            overlayImageFor: (index, targetSize) {
              imageCalls++;
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Contract hard — zooming out while already densest clamps to the
    // current stop, so the morph frame equals the resting grid: mounting
    // the overlay would only reload thumbnails and flash placeholders.
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(195, 400));
    await finger2.moveTo(const Offset(205, 400));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    expect(overlayBuilds, 0);
    expect(imageCalls, 0);
  });

  /// The squeeze transform riding the densest-stop bounce — scoped to the
  /// grid so unrelated Transforms can't pollute the assertion. The scale
  /// lives on the matrix diagonal (storage[0]) — getMaxScaleOnAxis
  /// misreads it.
  Iterable<Transform> squeezedGrid(WidgetTester tester) => tester
      .widgetList<Transform>(find.descendant(of: find.byType(CupertinoGrid), matching: find.byType(Transform)))
      .where((t) => t.transform.storage[0] < 1 - 1e-4);

  testWidgets('pinch past the densest stop bounces the grid — no overlay, no density change', (tester) async {
    var committed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 200,
            columnCounts: const [1, 3, 5],
            initialColumns: 5,
            onColumnsChanged: (columns) => committed = columns,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) => const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Contract hard past the densest stop — Photos' zoomBounce: the grid
    // squeezes around the focal point instead of morphing or navigating.
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(198, 400));
    await finger2.moveTo(const Offset(202, 400));
    await tester.pump();

    expect(squeezedGrid(tester), isNotEmpty);

    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    // The rebound lands back at the resting density — the bounce changes
    // nothing semantically.
    expect(committed, 0);
    expect(squeezedGrid(tester), isEmpty);
  });

  testWidgets('a bounced edge stays firm during the refractory window', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoGrid(
            itemCount: 200,
            columnCounts: const [1, 3, 5],
            initialColumns: 5,
            itemKey: (index) => 'item-$index',
            itemBuilder: (context, index, targetSize) => const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> pinchOut() async {
      final finger1 = await tester.createGesture();
      final finger2 = await tester.createGesture();
      await finger1.down(const Offset(140, 400));
      await finger2.down(const Offset(260, 400));
      await tester.pump();
      await finger1.moveTo(const Offset(198, 400));
      await finger2.moveTo(const Offset(202, 400));
      await tester.pump();
      await finger1.up();
      await finger2.up();
      await tester.pumpAndSettle();
    }

    // First bounce squeezes; the rebound arms the refractory window.
    await pinchOut();

    // An immediate second pinch on the same edge meets a hard stop —
    // Photos' zoomBounceRefractoryPeriod keeps bounce spam from looping.
    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(198, 400));
    await finger2.moveTo(const Offset(202, 400));
    await tester.pump();

    expect(squeezedGrid(tester), isEmpty);

    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();
  });

  /// Exhaustive position audit: after every pinch commit, EVERY rendered
  /// cell is checked against the stamped stop's predicted rect — a uniform
  /// phase, an exact `tileRect` match, no interior holes, and a strictly
  /// index-consecutive slot order. The overlay's settled frame equals the
  /// same stamped layout by construction (covered by the per-cell fuzz
  /// shards), so a green audit here proves the two grids agree cell for
  /// cell — and that any apparent "reorder" is exactly the intended
  /// per-pinch phase wrap, never scrambled slots.
  ///
  /// `centered` lands the focal on its preserved screen column (edges hold
  /// their edge, interior focals centre) — the nonzero phase that used to
  /// split mirrored row runs mid-row (the `…36 45` mosaic).
  for (final reversed in [false, true]) {
    for (final centered in [false, true]) {
      if (!reversed && centered) continue; // covered by the centred test above
      testWidgets(
        'position audit — every cell on its stamped slot, every landing (reversed=$reversed centered=$centered)',
        (tester) async {
          tester.view.physicalSize = const Size(390, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          const itemCount = 240;
          const spacing = 2.0;
          const vp = Size(390, 780);
          var committed = 5;
          final controller = ScrollController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: CupertinoGrid(
                  itemCount: itemCount,
                  columnCounts: const [1, 3, 5],
                  initialColumns: 5,
                  reverse: reversed,
                  mirrorRows: reversed,
                  centerFocalOnCommit: centered,
                  tileAspect: (_) => 1.0,
                  scrollController: controller,
                  onColumnsChanged: (columns) => committed = columns,
                  itemKey: (index) => 'item-$index',
                  itemBuilder: (context, index, targetSize) => ColoredBox(
                    key: ValueKey<Object?>('tile-$index'),
                    color: Colors.primaries[index % Colors.primaries.length],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          MorphGridStop stopAt(int columns, int phase) =>
              MorphGridStop(columns, vp.width, spacing: spacing, aspect: 1.0, phase: phase, mirrorRows: reversed);

          Map<int, Rect> rendered() {
            final out = <int, Rect>{};
            for (var i = 0; i < itemCount; i++) {
              final finder = find.byKey(ValueKey<Object?>('tile-$i'));
              final count = finder.evaluate().length;
              expect(count, lessThan(2), reason: 'tile $i mounted $count times — duplicated cell');
              if (count == 1) out[i] = tester.getRect(finder);
            }
            return out;
          }

          /// Scroll-space rect an item must occupy: `tileRect` for the stamped
          /// phase — on a reversed axis the rect mirrors about the viewport.
          Rect expectedScreen(MorphGridStop stop, int item, double scroll) {
            final r = stop.tileRect(item, 0, itemCount);
            return reversed
                ? Rect.fromLTRB(r.left, vp.height + scroll - r.bottom, r.right, vp.height + scroll - r.top)
                : r.translate(0, -scroll);
          }

          /// The audit itself. Infers δ from every rendered cell — they must
          /// ALL agree (a single scrambled slot breaks the consensus) — then
          /// compares each cell's rect to the stamped stop's prediction and
          /// walks every viewport slot expecting its item.
          int audit(int columns) {
            final tiles = rendered();
            expect(tiles, isNotEmpty, reason: 'no tiles rendered at $columns columns');
            final scroll = controller.offset;
            final base = stopAt(columns, 0);
            // Infer δ only from FULL rows — the head/tail rows hold the phase
            // holes, so a partial row's slot-vs-item arithmetic would read a
            // wrong wrap. Full-row items all infer the same δ in a sound
            // lattice; one disagreement means a scrambled slot.
            final byRow = <int, List<MapEntry<int, Rect>>>{};
            for (final entry in tiles.entries) {
              final rect = entry.value;
              final scrollTop = reversed ? vp.height + scroll - rect.bottom : rect.top + scroll;
              final row = ((scrollTop - spacing) / base.rowStride).round();
              byRow.putIfAbsent(row, () => []).add(entry);
            }
            var phase = -1;
            for (final row in byRow.keys) {
              final cells = byRow[row]!;
              if (cells.length < columns) continue;
              for (final entry in cells) {
                final col = ((entry.value.left - spacing) / base.columnStride).round();
                // Unmirrored: slot = item + δ → δ = slot − item. Mirrored: the
                // run flips inside its row → slot = row·cols + cols−1 −δ −item,
                // so δ = row·cols + cols−1 − col − item.
                final delta = reversed
                    ? row * columns + columns - 1 - col - entry.key
                    : row * columns + col - entry.key;
                if (phase < 0) {
                  phase = delta;
                  expect(delta, inInclusiveRange(0, columns - 1), reason: 'inferred phase $delta out of range');
                } else {
                  expect(
                    delta,
                    phase,
                    reason:
                        'item ${entry.key} sits on slot ${row * columns + col} (δ=$delta) but the lattice runs at δ=$phase — slot order scrambled',
                  );
                }
              }
            }
            if (phase < 0) phase = 0;
            final stop = stopAt(columns, phase);
            for (final entry in tiles.entries) {
              final want = expectedScreen(stop, entry.key, scroll);
              expect(entry.value.left, closeTo(want.left, 1.0), reason: 'item ${entry.key} left at δ=$phase');
              expect(entry.value.top, closeTo(want.top, 1.0), reason: 'item ${entry.key} top at δ=$phase');
              expect(entry.value.width, closeTo(want.width, 1.0), reason: 'item ${entry.key} width at δ=$phase');
              expect(entry.value.height, closeTo(want.height, 1.0), reason: 'item ${entry.key} height at δ=$phase');
            }
            // No interior holes: every viewport slot holds its predicted item,
            // and the visible items form one index-consecutive run.
            final lastRow = stop.rowCount(itemCount) - 1;
            final firstVisibleRow = stop.rowAtY(scroll, 0).clamp(0, lastRow);
            final lastVisibleRow = stop.rowAtY(scroll + vp.height, 0).clamp(0, lastRow);
            var prev = -1;
            for (final i in tiles.keys.toList()..sort()) {
              if (prev >= 0) {
                expect(i, prev + 1, reason: 'rendered items skip $prev → $i — interior hole or reorder');
              }
              prev = i;
            }
            for (var row = firstVisibleRow; row <= lastVisibleRow; row++) {
              for (var col = 0; col < columns; col++) {
                final item = stop.itemAt(row * columns + col, itemCount);
                if (item < 0 || item >= itemCount) continue;
                final r = expectedScreen(stop, item, scroll);
                if (r.bottom <= 0 || r.top >= vp.height) continue;
                expect(tiles.containsKey(item), isTrue, reason: 'slot r$row c$col (item $item) is a visible hole');
              }
            }
            return phase;
          }

          Future<void> pinchOn(int focal, int to) async {
            final from = committed;
            final stopA = stopAt(from, audit(from));
            // Centre the focal's row in the viewport (same solve both axes).
            controller.jumpTo(
              (stopA.tileRect(focal, 0, itemCount).center.dy - vp.height / 2).clamp(
                0.0,
                controller.position.maxScrollExtent,
              ),
            );
            await tester.pump();
            final rect = tester.getRect(find.byKey(ValueKey<Object?>('tile-$focal')));
            final needed = stopAt(to, 0).tileWidth / stopA.tileWidth;
            final effective = math.exp(math.log(needed) * 0.95);
            final downHalf = math.min(36.0, rect.width / 2 - 4);
            final finger1 = await tester.createGesture();
            final finger2 = await tester.createGesture();
            await finger1.down(Offset(rect.center.dx - downHalf, rect.center.dy));
            await finger2.down(Offset(rect.center.dx + downHalf, rect.center.dy));
            await tester.pump();
            for (var step = 1; step <= 3; step++) {
              final half = downHalf * math.exp(math.log(effective) * step / 3);
              await finger1.moveTo(Offset(rect.center.dx - half, rect.center.dy));
              await finger2.moveTo(Offset(rect.center.dx + half, rect.center.dy));
              await tester.pump();
            }
            await finger1.up();
            await finger2.up();
            await tester.pumpAndSettle();
            expect(committed, to, reason: 'pinch on $focal must commit $from→$to');
          }

          // iOS Photos' focal-relative landings: without `centered` δ stays 0
          // at every density — a photo's column is its natural column and a
          // round-trip restores the exact arrangement. Under `centered` EVERY
          // landing re-chunks around the pinch — zoom-out included: the row
          // boundaries slide so the focal keeps its screen column and the
          // phase persists as grid state.
          final startAtFive = rendered();
          await pinchOn(8, 3);
          if (centered) {
            audit(3);
          } else {
            expect(audit(3), 0, reason: 'index-absolute landing — phase stays 0');
          }
          await pinchOn(8, 5);
          if (centered) {
            // Item 8 trailing in |6 7 8| at 3 columns; the block holds and
            // lands on the trailing edge at 5 columns — |4 5 6 7 8| → δ=1.
            expect(audit(5), 1, reason: 'zoom-out landing keeps the focal\'s screen side — phased re-chunk');
          } else {
            expect(audit(5), 0, reason: 'index-absolute landing — phase stays 0');
            // Index-absolute round-trip: every cell back on its old slot.
            final backAtFive = rendered();
            expect(backAtFive.keys, startAtFive.keys, reason: 'round-trip lost or gained cells');
            for (final entry in startAtFive.entries) {
              final after = backAtFive[entry.key]!;
              expect(
                after.left,
                closeTo(entry.value.left, 1.0),
                reason: 'item ${entry.key} x moved across the round-trip',
              );
              expect(
                after.top,
                closeTo(entry.value.top, 1.0),
                reason: 'item ${entry.key} y moved across the round-trip',
              );
            }
          }
          // Under `centered` the focal holds its side — it sat on the
          // trailing edge of |6 7 8| at 3 columns and lands on the trailing
          // edge at 5 (mirrored: it drifted to the leading side and keeps
          // it); without `centered` the focal takes its natural column
          // (row-major 3, mirrored 1).
          expect(stopAt(5, audit(5)).columnOf(8, itemCount), centered ? (reversed ? 0 : 4) : (reversed ? 1 : 3));

          // More transitions — every landing audited cell by cell. Item 21
          // sits at the centre column under the carried-over phase and
          // lands centred — |19 20 21| → δ=1; index-absolute stays 0.
          await pinchOn(21, 3);
          expect(audit(3), centered ? 1 : 0);
          await pinchOn(11, 5);
          // Item 11 at the trailing column of its 3-col row → holds the last
          // column at 5: |11 12 13 14 15| → δ=4. Index-absolute stays 0.
          expect(audit(5), centered ? 4 : 0);
          await pinchOn(14, 1);
          audit(1);
          await pinchOn(14, 3);
          // From a single column there is no edge to preserve — the focal
          // centres: |13 14 15| → δ=2. Index-absolute stays 0.
          expect(audit(3), centered ? 2 : 0);
          // Head edge: item 0 can't sit right of slot 0 (nothing before
          // it), so the list-edge clamp always lands it on the head slot —
          // mirrored rows flip the edge columns to the same corners.
          await pinchOn(0, 5);
          expect(stopAt(5, audit(5)).columnOf(0, itemCount), reversed ? 4 : 0);
          await pinchOn(0, 3);
          expect(stopAt(3, audit(3)).columnOf(0, itemCount), reversed ? 2 : 0);
          await pinchOn(itemCount - 1, 5);
          expect(stopAt(5, audit(5)).columnOf(itemCount - 1, itemCount), reversed ? 0 : 4);
        },
      );
    }
  }

  test('visibleIndices tracks the painted set and moves with the frame', () {
    // The priority contract: an image cache reads visibleIndices to order
    // its decode queue — it must equal exactly the emitted tile indices
    // and follow the morph as the visible window shifts.
    const viewport = Size(390, 844);
    final stops = [
      for (final c in [1, 3, 5, 16]) MorphGridStop(c, 390, spacing: 2, aspect: 1),
    ];
    const count = 709;
    final morph = PinchMorph()
      ..begin(
        stops: stops,
        startStop: 3,
        focalIndex: 60,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 500),
        startScroll: 0,
        minScroll: 0,
        trailing: 60,
        itemCount: count,
        origin: 300,
        headerOrigin: 0,
        viewport: viewport,
        reversed: false,
      );

    for (final level in [3.0, 2.5, 2.0, 1.3, 1.0]) {
      morph.set(level: level);
      final frame = morph.frame((_) => false);
      final painted = {for (final t in frame.tiles) t.index};
      expect(morph.visibleIndices, painted, reason: 'visible set diverged from painted tiles at level $level');
      expect(morph.visibleIndices, contains(60), reason: 'focal index missing at level $level');
      expect(morph.visibleIndices.every((i) => i >= 0 && i < count), isTrue);
    }
  });
}

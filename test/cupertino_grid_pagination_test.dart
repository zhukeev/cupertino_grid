import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// The photo library's "jump during pagination" reproduction. The gallery
/// runs [CupertinoGrid] with `reverse: true` — index 0 (newest) anchors
/// the bottom edge, older pages grow the far end (screen top). Each test
/// parks or flings the grid, lands a production-style mutation, and
/// measures a tracked tile's screen position:
///  - tail append: a local page extending the loaded window;
///  - mid-list insert: a cloud page merging by capture date at indexes
///    before the visible range (the timeline interleave);
///  - spinner toggle: the load-more footer's extent appearing/disappearing.
double? _centerY(WidgetTester tester, Object key) {
  final finder = find.byKey(ValueKey<Object?>(key));
  if (finder.evaluate().isEmpty) return null;
  return tester.getRect(finder.first).center.dy;
}

/// The currently-rendered tile key nearest a screen y — picks an anchor the
/// lazy sliver actually has mounted instead of guessing an index.
Object _anchorNear(WidgetTester tester, double y) {
  Object? best;
  var bestDistance = double.infinity;
  for (final element in find.byType(Text).evaluate()) {
    final key = (element.widget as Text).data!;
    final tile = find.byKey(ValueKey<Object?>(key));
    if (tile.evaluate().isEmpty) continue; // not a tile (e.g. footer text)
    final center = tester.getRect(tile.first).center;
    final distance = (center.dy - y).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = key;
    }
  }
  return best ?? (throw StateError('no tiles rendered'));
}

/// Every mounted tile's screen center-y, keyed by item — the set changes
/// as the lazy sliver mounts/unmounts rows, so callers diff adjacent
/// frames on the shared keys.
Map<Object, double> _tileYs(WidgetTester tester) {
  final out = <Object, double>{};
  for (final element in find.byType(Text).evaluate()) {
    final key = (element.widget as Text).data!;
    final tile = find.byKey(ValueKey<Object?>(key));
    if (tile.evaluate().isEmpty) continue; // not a tile (e.g. footer text)
    out[key] = tester.getRect(tile.first).center.dy;
  }
  return out;
}

Widget _grid({required List<String> items, required ScrollController controller, bool loading = false}) {
  return MaterialApp(
    home: Scaffold(
      body: CupertinoGrid(
        itemCount: items.length,
        columnCounts: const [5],
        columns: 5,
        reverse: true,
        scrollController: controller,
        itemKey: (index) => items[index],
        itemsVersion: items,
        // Mirrors GalleryView's fixed-extent loader slot: the spinner's
        // footprint must survive exhaustion — its collapse shrank
        // maxScrollExtent under a viewport parked at the end and jumped
        // every visible tile. A static box keeps pumpAndSettle usable (a
        // real indicator animates forever).
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 40, child: loading ? const ColoredBox(color: Colors.black26) : null),
            const SizedBox(height: 64),
          ],
        ),
        itemBuilder: (context, index, targetSize) => ColoredBox(
          color: Colors.primaries[index % Colors.primaries.length],
          child: Center(child: Text(items[index])),
        ),
      ),
    ),
  );
}

void main() {
  // Reversed axis: pixels grows toward the TOP of the screen (older items).
  testWidgets('tail append while parked keeps the visible item stationary', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 100; i++) 'a$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final anchor = _anchorNear(tester, 300);
    final before = _centerY(tester, anchor);

    items = [...items, for (var i = 0; i < 20; i++) 'b$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    expect(_centerY(tester, anchor), closeTo(before!, 0.5));
  });

  testWidgets('cloud page merging before the visible range keeps the item stationary', (tester) async {
    // REPRODUCTION: a remote page whose items sort ahead of the viewport
    // (newer side) relocates keyed children to higher indexes. RenderSliver
    // Grid reports no scrollOffsetCorrection — every visible tile teleports
    // by the inserted extent. This is the gallery's "jump".
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 100; i++) 'a$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final anchor = _anchorNear(tester, 300);
    final before = _centerY(tester, anchor);

    // Eight cloud items sort in at index 20 — before the parked viewport.
    items = [...items.sublist(0, 20), for (var i = 0; i < 8; i++) 'c$i', ...items.sublist(20)];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    expect(_centerY(tester, anchor), closeTo(before!, 0.5));
  });

  testWidgets('cloud page merging past the visible range keeps the item stationary', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 100; i++) 'a$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final anchor = _anchorNear(tester, 300);
    final before = _centerY(tester, anchor);

    // Inserts beyond the last visible tile move nothing on screen.
    items = [...items.sublist(0, 90), for (var i = 0; i < 8; i++) 'd$i', ...items.sublist(90)];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    expect(_centerY(tester, anchor), closeTo(before!, 0.5));
  });

  testWidgets('mid-list insert landing mid-fling does not teleport content', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 140; i++) 'a$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent / 3);
    await tester.pumpAndSettle();

    // Fling toward the older end (reversed: pull content down, offset grows).
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 500), 1200);
    // The scroll offset legitimately STEPS by the corrected extent — the
    // compensation shifts pixels — so the invariant lives on screen: no
    // mounted tile may jump between consecutive frames. Tiles crossing the
    // mount boundary between samples are skipped by the shared-key diff.
    var previous = _tileYs(tester);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final current = _tileYs(tester);
      for (final entry in current.entries) {
        final before = previous[entry.key];
        if (before == null) continue;
        expect(
          (entry.value - before).abs(),
          lessThan(120),
          reason: 'tile ${entry.key} teleported ${entry.value - before}px at frame $i',
        );
      }
      previous = current;
      if (i == 4) {
        // Fifteen items (three rows) sort in before the viewport — big
        // enough that an uncorrected teleport (~3 row extents) dwarfs any
        // per-frame ballistic step (~30px).
        items = [...items.sublist(0, 10), for (var j = 0; j < 15; j++) 'c$j', ...items.sublist(10)];
        await tester.pumpWidget(_grid(items: items, controller: controller));
      }
    }
    await tester.pumpAndSettle();
  });

  testWidgets('folded cells before the anchor do not drag it during the collapse', (tester) async {
    // The seek-merge reproduction: an island splices in ahead of the
    // window while rendered members fold into stacks — a mixed
    // insert+remove diff. Cells folding between the leading edge and the
    // anchor used to animate the collapse, so the anchor kept drifting
    // for the duration even though the correction already assumed final
    // geometry — the residual motion read as a second jump.
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 100; i++) 'a$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();

    // The tile just above the leading edge's row: removing everything
    // rendered below it makes it the anchor the correction targets, so
    // it must land exactly — any in-window fold below it animating would
    // keep pulling it across the collapse.
    final mounted = _tileYs(tester).entries.where((entry) => (entry.key as String).startsWith('a')).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final anchor = mounted[5].key as String;
    final before = _centerY(tester, anchor);
    final anchorIndex = int.parse(anchor.substring(1));
    final foldStart = (anchorIndex - 10).clamp(0, anchorIndex);
    final folded = {for (var i = foldStart; i < anchorIndex; i++) items[i]};

    // A page splices in ahead while those cells fold — mixed
    // insert+remove diff, like the seek landing under the viewport.
    items = [
      ...items.sublist(0, 20),
      for (var i = 0; i < 8; i++) 'c$i',
      ...items.sublist(20).where((item) => !folded.contains(item)),
    ];
    await tester.pumpWidget(_grid(items: items, controller: controller));
    // Mid-collapse — the instant-fold path lands final geometry in one
    // frame; an animating slot would still be shrinking here.
    await tester.pump(const Duration(milliseconds: 100));
    expect(_centerY(tester, anchor), closeTo(before!, 1.0));
    await tester.pumpAndSettle();
    expect(_centerY(tester, anchor), closeTo(before, 0.5));
  });

  testWidgets('spinner removal while parked at the end does not shift content', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 60; i++) 'a$i'];
    var loading = true;
    await tester.pumpWidget(_grid(items: items, controller: controller, loading: loading));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final anchor = _anchorNear(tester, 200);
    final before = _centerY(tester, anchor);

    // Final page lands: spinner removed, tail appended.
    loading = false;
    items = [...items, for (var i = 0; i < 20; i++) 'b$i'];
    await tester.pumpWidget(_grid(items: items, controller: controller, loading: loading));
    await tester.pumpAndSettle();

    expect(_centerY(tester, anchor), closeTo(before!, 0.5));
  });

  testWidgets('exhaustion while parked at the end does not shift content', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final items = [for (var i = 0; i < 60; i++) 'a$i'];
    var loading = true;
    await tester.pumpWidget(_grid(items: items, controller: controller, loading: loading));
    await tester.pumpAndSettle();

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final anchor = _anchorNear(tester, 200);
    final before = _centerY(tester, anchor);

    // The listing turns out exhausted: the spinner vanishes with nothing
    // appended — the footer shrinks out from under the parked viewport.
    loading = false;
    await tester.pumpWidget(_grid(items: items, controller: controller, loading: loading));
    await tester.pumpAndSettle();

    expect(_centerY(tester, anchor), closeTo(before!, 0.5));
  });
}

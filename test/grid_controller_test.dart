import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Coverage for [CupertinoGridController] — the host-facing control
/// surface the gallery contract exercises: index navigation that
/// projects post-merge extents and suppresses the anchor hold, global-
/// point hit-testing, slot-space drag selection with edge auto-scroll,
/// scroll-driver classification with a settle report, and committed
/// stop-index reporting in the caller's own ladder order.
Widget _tile(String label) => ColoredBox(
  color: Colors.blueGrey,
  child: Center(child: Text(label)),
);

/// A plain reversed gallery: [count] items, [columns] columns.
Widget _grid({
  required int count,
  required ScrollController scroll,
  required CupertinoGridController grid,
  int columns = 5,
  bool reverse = true,
  bool mirrorRows = false,
  List<int>? columnCounts,
  ValueChanged<int>? onStopChanged,
  void Function(int anchorIndex, int direction)? onScrollSettled,
}) {
  final items = [for (var i = 0; i < count; i++) 'i$i'];
  return MaterialApp(
    home: Scaffold(
      body: CupertinoGrid(
        itemCount: count,
        columns: columns,
        columnCounts: columnCounts ?? [columns],
        reverse: reverse,
        mirrorRows: mirrorRows,
        controller: grid,
        scrollController: scroll,
        onStopChanged: onStopChanged,
        onScrollSettled: onScrollSettled,
        itemKey: (index) => items[index],
        itemsVersion: items,
        itemBuilder: (context, index, targetSize) => _tile(items[index]),
      ),
    ),
  );
}

void main() {
  const viewport = Size(390, 780);

  Future<(ScrollController, CupertinoGridController)> pump(
    WidgetTester tester, {
    int count = 200,
    int columns = 5,
    bool reverse = true,
    bool mirrorRows = false,
    List<int>? columnCounts,
    ValueChanged<int>? onStopChanged,
    void Function(int anchorIndex, int direction)? onScrollSettled,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final grid = CupertinoGridController();
    addTearDown(grid.dispose);
    await tester.pumpWidget(
      _grid(
        count: count,
        scroll: scroll,
        grid: grid,
        columns: columns,
        reverse: reverse,
        mirrorRows: mirrorRows,
        columnCounts: columnCounts,
        onStopChanged: onStopChanged,
        onScrollSettled: onScrollSettled,
      ),
    );
    await tester.pumpAndSettle();
    return (scroll, grid);
  }

  testWidgets('scrollToIndex lands the target row under the leading inset (reversed)', (tester) async {
    final (scroll, grid) = await pump(tester, count: 200);
    // Deep in the list — the target row is far off-screen.
    grid.scrollToIndex(150, leadingInset: 76);
    await tester.pumpAndSettle();
    // Reversed axis: the row's scroll-space bottom edge pins to
    // viewportTop + inset. Tile top on screen = inset + spacing.
    final stop = grid.stop!;
    final row = stop.rowOf(150);
    expect(scroll.offset, closeTo(stop.rowTop(row + 1, 0) + 76 - viewport.height, 2.0));
    // The painted tile clears the floating-bar band.
    final rect = tester.getRect(find.text('i150').first);
    expect(rect.top, greaterThanOrEqualTo(76));
  });

  testWidgets('scrollToIndex is a no-op while the row is fully visible', (tester) async {
    final (scroll, grid) = await pump(tester, count: 200);
    // Item 0's row sits at rest inside the viewport — the call must not
    // move the position.
    grid.scrollToIndex(0);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, 0.5));
  });

  testWidgets('scrollToIndex during a merge rebuild lands without anchor drift', (tester) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final grid = CupertinoGridController();
    addTearDown(grid.dispose);
    var items = [for (var i = 0; i < 200; i++) 'i$i'];
    Widget app() => MaterialApp(
      home: Scaffold(
        body: CupertinoGrid(
          itemCount: items.length,
          columns: 5,
          columnCounts: const [5],
          reverse: true,
          controller: grid,
          scrollController: scroll,
          itemKey: (index) => items[index],
          itemsVersion: items,
          itemBuilder: (context, index, targetSize) => _tile(items[index]),
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();

    // The seek merge: an island splices into the list in the same pass the
    // landing targets — the target count lets the call project the
    // post-merge extent and drop the anchor hold for the commit.
    items = [...items.sublist(0, 60), for (var i = 0; i < 30; i++) 'c$i', ...items.sublist(60)];
    await tester.pumpWidget(app());
    grid.scrollToIndex(75, targetItemCount: items.length, leadingInset: 76);
    await tester.pumpAndSettle();
    // Landing verified: the target row is inside the viewport and the
    // offset stays where it landed (no residual anchor correction).
    final stop = grid.stop!;
    final row = stop.rowOf(75);
    final rowTop = stop.rowTop(row, 0);
    final rowBottom = stop.rowTop(row + 1, 0);
    expect(rowTop, greaterThanOrEqualTo(scroll.offset - 0.5));
    expect(rowBottom, lessThanOrEqualTo(scroll.offset + viewport.height + 0.5));
    final landed = scroll.offset;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.offset, closeTo(landed, 0.5));
    }
  });

  testWidgets('indexAtGlobalPoint resolves the item under a screen point', (tester) async {
    final (scroll, grid) = await pump(tester, count: 200);
    final tile = tester.getRect(find.text('i0').first);
    expect(grid.indexAtGlobalPoint(tile.center), 0);
    // A point outside the painted content clamps to the nearest item —
    // the drag-select contract, which keeps extending past the edge.
    final off = grid.indexAtGlobalPoint(const Offset(-50, -50));
    expect(off, greaterThanOrEqualTo(0));
    expect(off, lessThan(200));
    // Deep scroll: a known tile's painted center still resolves to it.
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final probe = tester.getRect(find.text('i100').first);
    expect(grid.indexAtGlobalPoint(probe.center), 100);
  });

  testWidgets('drag selection sweeps a contiguous slot range (non-mirrored)', (tester) async {
    final (scroll, grid) = await pump(tester, count: 100, reverse: false);
    final a = tester.getRect(find.text('i10').first);
    final b = tester.getRect(find.text('i17').first);
    grid.beginSelectionDrag(10, a.center);
    grid.updateSelectionDrag(b.center);
    grid.endSelectionDrag();
    expect(grid.selectedIndices.value, {for (var i = 10; i <= 17; i++) i});
    expect(scroll.offset, closeTo(0, 0.5));
  });

  testWidgets('drag selection maps slots back through mirrored rows', (tester) async {
    final (_, grid) = await pump(tester, count: 100, mirrorRows: true);
    // Slots 10..17 contiguous on screen; under mirrorRows each row's item
    // run flips inside its occupied span, so the emitted items are not a
    // contiguous index range.
    final a = tester.getRect(find.text('i10').first);
    final b = tester.getRect(find.text('i17').first);
    grid.beginSelectionDrag(10, a.center);
    grid.updateSelectionDrag(b.center);
    grid.endSelectionDrag();
    expect(grid.selectedIndices.value, {10, 17, 18, 19});
  });

  testWidgets('selection drag near the trailing edge auto-scrolls', (tester) async {
    final (scroll, grid) = await pump(tester, count: 300, reverse: false);
    final anchor = tester.getRect(find.text('i0').first);
    grid.beginSelectionDrag(0, anchor.center);
    // Hold the pointer just above the bottom edge.
    grid.updateSelectionDrag(const Offset(195, 770));
    final before = scroll.offset;
    // Edge scroll ticks on a 16 ms timer — pump a second of wall time.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(scroll.offset, greaterThan(before + 10));
    grid.endSelectionDrag();
    final parked = scroll.offset;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(scroll.offset, closeTo(parked, 0.5));
  });

  testWidgets('scroll driver classifies drag → ballistic → idle with a settle report', (tester) async {
    final settled = <(int, int)>[];
    final (scroll, grid) = await pump(
      tester,
      count: 300,
      onScrollSettled: (anchor, direction) => settled.add((anchor, direction)),
    );
    expect(grid.scrollDriver, GridScrollDriver.idle);
    // Park mid-list so the fling has room, then hold a real drag and
    // release with velocity — the controller reports drag, ballistic
    // coast, then idle with a settle event.
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(Scrollable));
    final gesture = await tester.startGesture(center);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(grid.scrollDriver, GridScrollDriver.drag);
    await gesture.up();
    await tester.pumpAndSettle();
    // A real fling: compressed move timestamps give the release genuine
    // velocity, so the lift-off goes ballistic before it settles.
    // Reversed axis — dragging down scrolls toward older items (offset up).
    await tester.fling(find.byType(Scrollable), const Offset(0, 500), 4000);
    // The lift-off and the first coasting updates take several frames to
    // dispatch — pump until the drag hands off, then a 4000-velocity
    // fling is still mid-flight.
    for (var i = 0; i < 40 && grid.scrollDriver == GridScrollDriver.drag; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(grid.scrollDriver, GridScrollDriver.ballistic);
    await tester.pumpAndSettle();
    expect(grid.scrollDriver, GridScrollDriver.idle);
    expect(settled, isNotEmpty);
    expect(scroll.offset, greaterThan(0));
  });

  testWidgets('onStopChanged reports the committed rung in the caller ladder order', (tester) async {
    // The gallery's density enum is ordered descending (16, 5, 3, 1) —
    // the callback must report the index into THIS list, not the sorted
    // ladder the pinch engine uses.
    final committed = <int>[];
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var columns = 5;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => CupertinoGrid(
              itemCount: 300,
              columns: columns,
              columnCounts: const [16, 5, 3, 1],
              onColumnsChanged: (c) => setState(() => columns = c),
              onStopChanged: committed.add,
              itemBuilder: (context, index, targetSize) => _tile('i$index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Pinch in toward denser (5 → 16 columns): two-finger scale < 1.
    final center = tester.getCenter(find.byType(CupertinoGrid));
    final first = await tester.startGesture(center + const Offset(-60, 0), pointer: 7);
    final second = await tester.startGesture(center + const Offset(60, 0), pointer: 8);
    await first.moveTo(center + const Offset(-20, 0));
    await second.moveTo(center + const Offset(20, 0));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(committed, isNotEmpty);
    // 16 columns is index 0 in the caller's [16, 5, 3, 1] ladder.
    expect(committed.last, 0);
    expect(columns, 16);
  });
}

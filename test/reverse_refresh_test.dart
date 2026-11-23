import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

Widget _harness({required Future<void> Function() onRefresh, required ScrollPhysics physics}) {
  return CupertinoApp(
    home: CupertinoReverseRefresh(
      onRefresh: onRefresh,
      child: CustomScrollView(
        reverse: true,
        physics: physics,
        slivers: [
          SliverList.builder(
            itemCount: 40,
            itemBuilder: (context, index) => SizedBox(height: 80, child: Text('item-$index')),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('pull past the trigger at the leading edge fires onRefresh', (tester) async {
    var refreshes = 0;
    await tester.pumpWidget(_harness(onRefresh: () async => refreshes++, physics: const BouncingScrollPhysics()));
    await tester.pumpAndSettle();

    // Reversed axis: leading edge = visual bottom. Dragging up lifts the
    // newest row off the edge — overscroll (pixels below min).
    final gesture = await tester.startGesture(const Offset(400, 400));
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(refreshes, 1);
  });

  testWidgets('pull short of the trigger does not fire', (tester) async {
    var refreshes = 0;
    await tester.pumpWidget(_harness(onRefresh: () async => refreshes++, physics: const BouncingScrollPhysics()));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(400, 400));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(refreshes, 0);
  });

  testWidgets('a second pull while refreshing does not double-fire', (tester) async {
    var refreshes = 0;
    var release = false;
    await tester.pumpWidget(
      _harness(
        onRefresh: () async {
          refreshes++;
          while (!release) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        },
        physics: const BouncingScrollPhysics(),
      ),
    );
    await tester.pumpAndSettle();

    final first = await tester.startGesture(const Offset(400, 400));
    await first.moveBy(const Offset(0, -150));
    await tester.pump();
    await first.up();
    // Bounded pumps, not pumpAndSettle — the indicator animates forever
    // while a refresh is in flight, so nothing ever "settles".
    for (var i = 0; i < 5 && refreshes == 0; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(refreshes, 1);

    // Pull again while the first refresh is still in flight.
    final second = await tester.startGesture(const Offset(400, 400));
    await second.moveBy(const Offset(0, -150));
    await tester.pump();
    await second.up();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(refreshes, 1);

    release = true;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(refreshes, 1);
  });

  testWidgets('FarEdgeClampScrollPhysics clamps drags past the far edge', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CustomScrollView(
          reverse: true,
          physics: const FarEdgeClampScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
            SliverList.builder(
              itemCount: 10,
              itemBuilder: (context, index) => SizedBox(height: 80, child: Text('item-$index')),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final maxExtent = scrollable.position.maxScrollExtent;

    // Fling toward the far edge (drag down = forward under reverse): the
    // ballistic sim must clamp at maxScrollExtent, not elastic past it.
    await tester.fling(find.byType(Scrollable), const Offset(0, 2000), 3000);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, lessThanOrEqualTo(maxExtent));

    // The near edge keeps its bounce: flinging back overscrolls below min.
    await tester.fling(find.byType(Scrollable), const Offset(0, -2000), 3000);
    await tester.pump();
    expect(scrollable.position.pixels, lessThan(scrollable.position.minScrollExtent));
    await tester.pumpAndSettle();
  });
}

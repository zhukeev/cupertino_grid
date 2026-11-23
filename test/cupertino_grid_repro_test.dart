import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Simulates the app's real list: stable string keys, items removed from
/// the FRONT (cloud merge/un-hide shifts every later item's index).
Widget grid({required List<String> items, int columns = 3, ScrollController? controller}) {
  return MaterialApp(
    home: Scaffold(
      body: CupertinoGrid(
        itemCount: items.length,
        columns: columns,
        columnCounts: const [1, 3, 5, 16],
        scrollController: controller,
        itemKey: (index) => items[index],
        itemBuilder: (context, index, size) =>
            ColoredBox(color: Colors.primaries[index % Colors.primaries.length], child: Text(items[index])),
      ),
    ),
  );
}

/// Every rendered tile label must belong to the current item list — a
/// stale element keeping a dropped 'a$i' alive, or two tiles claiming the
/// same label, means the keyed-reuse contract broke without necessarily
/// throwing.
void expectVisibleItemsAreCurrent(WidgetTester tester, List<String> items) {
  final labels = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data!).toList();
  final current = items.toSet();
  for (final label in labels) {
    expect(current.contains(label), isTrue, reason: 'stale item "$label" still rendered');
  }
  expect(labels.toSet(), hasLength(labels.length), reason: 'duplicate labels rendered: $labels');
}

void main() {
  testWidgets('fuzz: itemCount/index shifts + column changes while scrolled', (tester) async {
    final random = math.Random(7);
    final controller = ScrollController();
    var items = [for (var i = 0; i < 400; i++) 'a$i'];
    var columns = 3;
    await tester.pumpWidget(grid(items: items, columns: columns, controller: controller));
    await tester.pumpAndSettle();
    expectVisibleItemsAreCurrent(tester, items);

    for (var step = 0; step < 40; step++) {
      switch (random.nextInt(5)) {
        case 0: // scroll somewhere deep
          controller.jumpTo(random.nextDouble() * controller.position.maxScrollExtent);
        case 1: // drop a slice from the front — every index shifts
          final n = random.nextInt(20) + 1;
          items = items.sublist(math.min(n, items.length - 5));
        case 2: // prepend new items (cloud photos merging in ahead)
          final n = random.nextInt(20) + 1;
          items = [for (var i = 0; i < n; i++) 'new$step-$i', ...items];
        case 3: // append a page (load-more)
          items = [...items, for (var i = 0; i < 60; i++) 'more$step-$i'];
        case 4: // density change
          columns = [1, 3, 5, 16][random.nextInt(4)];
      }
      await tester.pumpWidget(grid(items: items, columns: columns, controller: controller));
      await tester.pump();
      expectVisibleItemsAreCurrent(tester, items);
      expect(controller.offset, lessThanOrEqualTo(controller.position.maxScrollExtent));
    }
    await tester.pumpAndSettle();
    expectVisibleItemsAreCurrent(tester, items);
  });
}

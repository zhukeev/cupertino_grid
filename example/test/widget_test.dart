import 'package:cupertino_grid/cupertino_grid.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cupertino_grid_example/main.dart';

void main() {
  testWidgets('demo grid mounts and paints tiles', (tester) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pump();

    expect(find.byType(CupertinoGrid), findsOneWidget);
    // Numbered placeholder tiles render at the resting density.
    expect(find.byType(DemoTile), findsWidgets);
  });
}

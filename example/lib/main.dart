import 'package:material_ui/material_ui.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

void main() => runApp(const DemoApp());

/// Demo app shell — dark theme around [DemoGrid].
class DemoApp extends StatelessWidget {
  /// Creates the app.
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cupertino_grid demo',
      theme: ThemeData.dark(),
      home: const Scaffold(body: SafeArea(child: DemoGrid())),
    );
  }
}

/// A 400-item grid of deterministic numbered placeholders — pinch with two
/// fingers to morph between 1, 3, 5 and 16 columns, iOS-Photos style.
class DemoGrid extends StatelessWidget {
  /// Creates the demo grid.
  const DemoGrid({super.key});

  static const _itemCount = 400;

  @override
  Widget build(BuildContext context) {
    return CupertinoGrid(
      itemCount: _itemCount,
      reverse: true,
      columnCounts: const [1, 3, 5, 16],
      itemKey: (index) => index,
      itemBuilder: (context, index, targetSize) => DemoTile(index: index),
      sectionLabelFor: (index) {
        // One section per 40 items — labels ride on tiles at dense stops.
        return index % 40 == 0 ? 'Group ${index ~/ 40 + 1}' : null;
      },
    );
  }
}

/// Placeholder photo: a deterministic hue tile with its index drawn on top.
class DemoTile extends StatelessWidget {
  /// Creates a placeholder tile for [index].
  const DemoTile({super.key, required this.index});

  /// The item's index — also drawn on the tile.
  final int index;

  @override
  Widget build(BuildContext context) {
    final hue = (index * 47) % 360;
    return ColoredBox(
      color: HSVColor.fromAHSV(1, hue.toDouble(), 0.6, 0.85).toColor(),
      child: Center(
        child: FittedBox(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Text(
              '$index',
              style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

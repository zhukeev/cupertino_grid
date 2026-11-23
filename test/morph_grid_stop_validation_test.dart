import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

void main() {
  group('MorphGridStop validation', () {
    test('rejects invalid density and geometry inputs', () {
      expect(() => MorphGridStop(0, 390, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, double.nan, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: -1, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: 2, aspect: 0), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: 2, aspect: 1, phase: 3), throwsArgumentError);
    });

    test('rejects an invalid phase when cloning a stop', () {
      final stop = MorphGridStop(3, 390, spacing: 2, aspect: 1);
      expect(() => stop.withPhase(3), throwsArgumentError);
    });

    test('mirrored hole slots resolve to the nearest displayed item', () {
      // columns=5, phase=2, items=12, mirrored:
      //   row 0 displays [_, _, 2, 1, 0]  — head holes at columns 0-1
      //   row 2 displays [11, 10, 9, 8, _] — tail hole at column 4
      const count = 12;
      final stop = MorphGridStop(5, 390, spacing: 2, aspect: 1, phase: 2, mirrorRows: true);
      expect(stop.itemAt(0, count), -1);
      expect(stop.itemAt(14, count), -1);

      double cx(int column) => stop.spacing + column * stop.columnStride + stop.tileWidth / 2;
      double ry(int row) => stop.spacing + row * stop.rowStride + stop.tileHeight / 2;

      // Head holes resolve to the leftmost displayed item (hi - 1 = 2),
      // not the rightmost (lo = 0) parked at the row's far edge.
      expect(stop.indexAt(Offset(cx(0), ry(0)), count, 0), 2);
      expect(stop.indexAt(Offset(cx(1), ry(0)), count, 0), 2);
      // The tail hole resolves to the rightmost displayed item (lo = 8),
      // not the leftmost (hi - 1 = 11) at the row's far edge.
      expect(stop.indexAt(Offset(cx(4), ry(2)), count, 0), 8);
    });
  });
}

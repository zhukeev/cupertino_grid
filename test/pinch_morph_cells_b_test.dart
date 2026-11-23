// Shard B of the `per-cell morph` fuzz — see pinch_morph_fuzz.dart.
// Split across files because `flutter test` parallelizes per file.

import 'package:flutter_test/flutter_test.dart';

import 'pinch_morph_fuzz.dart';

void main() {
  for (final reversed in [false, true]) {
    test('per-cell morph${reversed ? ' (reversed axis)' : ''} [shard b]', () {
      runPerCellMorph(reversed: reversed, seed: 22, trials: 100);
    });
  }
}

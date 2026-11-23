/// iOS-Photos-style pinch-to-zoom grid for Flutter.
///
/// [CupertinoGrid] is a self-contained scrollable grid: pinching with two
/// fingers morphs every cell continuously between the column counts in the
/// density ladder — the photo under the fingers stays under them — and on
/// release the grid springs onto the nearest column count.
///
/// [PinchMorph] is the geometry engine underneath — a pure Dart object that
/// turns pinch state ([PinchMorph.level], [PinchMorph.pin]) into a
/// [MorphFrame] of positioned [MorphTile]s, in case a caller wants the morph
/// without the widget.
library;

export 'src/morph_frame.dart' show MorphFrame, MorphPill, MorphTile;
export 'src/morph_grid_stop.dart' show MorphGridStop;
export 'src/pinch_morph_style.dart' show PinchMorphStyle;
export 'src/pinch_morph.dart' show PinchMorph;
export 'src/cupertino_grid.dart' show CupertinoGrid, OverscaleCommit;
export 'src/far_edge_clamp_physics.dart' show FarEdgeClampScrollPhysics;
export 'src/reverse_refresh.dart' show CupertinoReverseRefresh;
export 'src/tile_morph_effect.dart'
    show TileMorphEffect, TileMorphEffectBuilder, TileMorphFlowImage, TileMorphPaint, TileMorphPaintPair;

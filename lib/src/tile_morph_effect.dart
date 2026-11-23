import 'dart:ui' as ui;

/// Pixel-level transform applied to morph tiles during a pinch.
///
/// [PinchMorph] owns geometry — positions, tile identity, swap timing.
/// A [TileMorphEffect] owns how an emitted tile's *pixels* resolve when the
/// overlay paints decoded [ui.Image]s instead of widget snapshots. Passing
/// `overlayTileEffect: null` (the default) keeps the plain cover-fit draw —
/// the simple blend look — so the morph effect is strictly opt-in.
///
/// Implementations live outside this package and need not implement this
/// interface directly: [TileMorphEffect.callbacks] adapts any paint
/// functions — e.g. `package:image_morph`'s `GpuImageMorphEffect` tear-offs —
/// so neither library depends on the other. A plain crossfade-style
/// implementation can return `null` from [flowImage] and draw both pair
/// endpoints with opacity inside [paintPair].
///
/// Lifecycle: the caller owns the instance — create it, hand it to
/// `CupertinoGrid(overlayTileEffect: ...)` or
/// `CupertinoGrid(overlayTileEffectBuilder: ...)`, and call [dispose] when
/// done. A callback-adapted effect forwards [dispose] to the supplied
/// `onDispose` (defaults to a no-op).
abstract interface class TileMorphEffect {
  /// Adapts plain functions into a [TileMorphEffect] — the bridge for
  /// effects defined in packages that do not depend on `cupertino_grid`:
  ///
  /// ```dart
  /// final gpu = await GpuImageMorphEffect.load();
  /// final effect = TileMorphEffect.callbacks(
  ///   paint: gpu.paint,
  ///   paintPair: gpu.paintPair,
  ///   flowImage: gpu.flowImage,
  ///   onDispose: gpu.dispose,
  /// );
  /// ```
  factory TileMorphEffect.callbacks({
    required TileMorphPaint paint,
    required TileMorphPaintPair paintPair,
    TileMorphFlowImage? flowImage,
    void Function()? onDispose,
  }) = _CallbackTileMorphEffect;

  /// Optional per-pair precomputation, invoked once per swap pair before
  /// the first [paintPair] that needs it.
  ///
  /// Returns auxiliary data as a [ui.Image] consumed by [paintPair]'s
  /// `flow` parameter — e.g. a block-matched displacement field. Return
  /// `null` when the effect needs no precompute (a crossfade) or when
  /// computation failed; pair painting then degrades to whatever fallback
  /// the implementation chooses.
  Future<ui.Image?> flowImage(ui.Image from, ui.Image to);

  /// Paints a lone tile's [image] into [rect].
  ///
  /// [progress] is the morph's interval progress (0..1 within a stop
  /// crossing) — implementations should be neutral at both endpoints.
  /// [focal] is the pinch focal point in tile-local UV (0..1). [opacity]
  /// is the tile's emitted opacity, consumed however the effect chooses
  /// (alpha, dissolve threshold, …).
  void paint(
    ui.Canvas canvas, {
    required ui.Image image,
    required ui.Rect rect,
    required double progress,
    ui.Offset focal,
    double opacity,
  });

  /// Paints a swap pair — a slot where a departing photo ([from]) hands
  /// its rect to an arriving one ([to]) — into [rect].
  ///
  /// [t] is the pair's swap progress (0..1). [flow] is the image returned
  /// by [flowImage] for this pair, or `null` while it is pending / when
  /// the effect does not use one. [progress] and [focal] match [paint].
  void paintPair(
    ui.Canvas canvas, {
    required ui.Image from,
    required ui.Image to,
    required ui.Image? flow,
    required ui.Rect rect,
    required double t,
    required double progress,
    ui.Offset focal,
  });

  /// Releases resources held by the effect (shaders, buffers).
  void dispose();
}

/// Signature matching [TileMorphEffect.paint] — see
/// [TileMorphEffect.callbacks].
typedef TileMorphPaint =
    void Function(
      ui.Canvas canvas, {
      required ui.Image image,
      required ui.Rect rect,
      required double progress,
      ui.Offset focal,
      double opacity,
    });

/// Signature matching [TileMorphEffect.paintPair] — see
/// [TileMorphEffect.callbacks].
typedef TileMorphPaintPair =
    void Function(
      ui.Canvas canvas, {
      required ui.Image from,
      required ui.Image to,
      required ui.Image? flow,
      required ui.Rect rect,
      required double t,
      required double progress,
      ui.Offset focal,
    });

/// Signature matching [TileMorphEffect.flowImage] — see
/// [TileMorphEffect.callbacks]. `null` means the effect needs no
/// per-pair precompute (a crossfade, for example).
typedef TileMorphFlowImage = Future<ui.Image?> Function(ui.Image from, ui.Image to);

/// Resolves a [TileMorphEffect] per morph frame — passed to
/// `CupertinoGrid(overlayTileEffectBuilder: ...)`. Returning `null` keeps
/// the plain cover-fit draw for that frame, which is how a caller toggles
/// morphing off mid-session or swaps implementations.
typedef TileMorphEffectBuilder = TileMorphEffect? Function();

final class _CallbackTileMorphEffect implements TileMorphEffect {
  _CallbackTileMorphEffect({
    required TileMorphPaint paint,
    required TileMorphPaintPair paintPair,
    TileMorphFlowImage? flowImage,
    void Function()? onDispose,
  }) : _paint = paint,
       _paintPair = paintPair,
       _flowImage = flowImage ?? ((_, _) async => null),
       _onDispose = onDispose ?? (() {});

  final TileMorphPaint _paint;
  final TileMorphPaintPair _paintPair;
  final TileMorphFlowImage _flowImage;
  final void Function() _onDispose;

  @override
  Future<ui.Image?> flowImage(ui.Image from, ui.Image to) => _flowImage(from, to);

  @override
  void paint(
    ui.Canvas canvas, {
    required ui.Image image,
    required ui.Rect rect,
    required double progress,
    ui.Offset focal = const ui.Offset(0.5, 0.5),
    double opacity = 1.0,
  }) => _paint(canvas, image: image, rect: rect, progress: progress, focal: focal, opacity: opacity);

  @override
  void paintPair(
    ui.Canvas canvas, {
    required ui.Image from,
    required ui.Image to,
    required ui.Image? flow,
    required ui.Rect rect,
    required double t,
    required double progress,
    ui.Offset focal = const ui.Offset(0.5, 0.5),
  }) => _paintPair(canvas, from: from, to: to, flow: flow, rect: rect, t: t, progress: progress, focal: focal);

  @override
  void dispose() => _onDispose();
}

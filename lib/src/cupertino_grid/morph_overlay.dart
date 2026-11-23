part of '../cupertino_grid.dart';

/// Pill geometry shared by the morph overlay's layout pass.
/// Dark translucent capsule naming a section on dense grids.
final class _SectionPill extends StatelessWidget {
  const _SectionPill({required this.label, required this.extent});

  final String label;

  /// Band height — always `PinchMorphStyle.pillExtent`; the render object
  /// enforces the same value at layout, so geometry and paint agree.
  final double extent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: extent,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        maxLines: 1,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Slot identity of an [_MorphOverlay] child — which frame slot it fills.
final class _OverlayChildData extends ContainerBoxParentData<RenderBox> {
  /// Grid item for tile children, -1 otherwise.
  int tileIndex = -1;

  /// Pill layer (0 = larger-tile stop, 1 = denser) and the section's item
  /// index — pill slots only.
  int pillLayer = -1;
  int pillIndex = -1;

  bool isHeader = false;

  /// Per-frame opacity assigned during layout.
  double opacity = 1;
}

/// Marks an [_MorphOverlay] child as a tile, section pill or the header so
/// the render object can lay it out at its frame slot.
final class _OverlaySlot extends ParentDataWidget<_OverlayChildData> {
  const _OverlaySlot.tile(this.tileIndex, {super.key, required super.child})
    : pillLayer = -1,
      pillIndex = -1,
      isHeader = false;

  const _OverlaySlot.pill(this.pillLayer, this.pillIndex, {super.key, required super.child})
    : tileIndex = -1,
      isHeader = false;

  const _OverlaySlot.header({super.key, required super.child})
    : tileIndex = -1,
      pillLayer = -1,
      pillIndex = -1,
      isHeader = true;

  final int tileIndex;
  final int pillLayer;
  final int pillIndex;
  final bool isHeader;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _OverlayChildData;
    var needsLayout = false;
    if (data.tileIndex != tileIndex) {
      data.tileIndex = tileIndex;
      needsLayout = true;
    }
    if (data.pillLayer != pillLayer) {
      data.pillLayer = pillLayer;
      needsLayout = true;
    }
    if (data.pillIndex != pillIndex) {
      data.pillIndex = pillIndex;
      needsLayout = true;
    }
    if (data.isHeader != isHeader) {
      data.isHeader = isHeader;
      needsLayout = true;
    }
    if (needsLayout) renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _MorphOverlay;
}

/// What the overlay asks the widget layer to mount next — tile indices and
/// `(layer, sectionIndex)` pill slots appearing in the current frame. Tile
/// requests are streak-gated: a slot must stay unpainted for a few layouts
/// before it lands here, so a decode racing the pointer never pays a mount.
typedef _OverlaySlotsNeeded = void Function(Set<int> tileIndices, Set<(int, int)> pillSlots);

/// Whether tiles sharing one cell rect flow-morph into each other through
/// [TileMorphEffect.paintPair]. Co-rect pairs are strangers by
/// construction (same-photo slots take the stable arm), so the bend melts
/// one photo into a different photo — a deliberate stylistic choice, not
/// a physically-real remap. Flip off for plain layered crossfades.
const kOverlayPairMorph = true;

/// The morph overlay as one render object. Per pinch frame it relayouts —
/// the frame math, per-child offsets and opacities live in layout, paint
/// order comes straight from the frame — so no widget subtree rebuilds
/// while the fingers move. Tiles with a decoded [ui.Image] skip child
/// widgets entirely and are painted with [Canvas.drawImageRect].
final class _MorphOverlay extends MultiChildRenderObjectWidget {
  const _MorphOverlay({
    required this.morph,
    required this.sectionStarts,
    required this.background,
    required this.missingTile,
    required this.spacing,
    required this.imageFor,
    required this.imagesInvalidated,
    required this.tileEffect,
    required this.onSlotsNeeded,
    required this.onVisibleItemsChanged,
    required this.style,
    required super.children,
  });

  final PinchMorph morph;
  final Set<int> sectionStarts;
  final Color background;
  final Color missingTile;
  final double spacing;
  final ui.Image? Function(int index, int targetSize)? imageFor;
  final Listenable? imagesInvalidated;

  /// Pixel transform for decoded-image tiles — `null` keeps the plain
  /// cover-fit draw; widget-painted slots are unaffected.
  final TileMorphEffect? tileEffect;
  final _OverlaySlotsNeeded? onSlotsNeeded;

  /// Fires when the index set the emitted frame paints changes — the
  /// priority set an image cache should serve first.
  final void Function(Set<int> indices)? onVisibleItemsChanged;

  /// Morph tuning — pills and the sticky-image cache read it.
  final PinchMorphStyle style;

  @override
  _RenderMorphOverlay createRenderObject(BuildContext context) => _RenderMorphOverlay(
    morph: morph,
    sectionStarts: sectionStarts,
    background: background,
    missingTile: missingTile,
    spacing: spacing,
    imageFor: imageFor,
    imagesInvalidated: imagesInvalidated,
    tileEffect: tileEffect,
    onSlotsNeeded: onSlotsNeeded,
    onVisibleItemsChanged: onVisibleItemsChanged,
    style: style,
  );

  @override
  void updateRenderObject(BuildContext context, covariant _RenderMorphOverlay renderObject) {
    renderObject
      ..morph = morph
      ..sectionStarts = sectionStarts
      ..background = background
      ..missingTile = missingTile
      ..spacing = spacing
      ..imageFor = imageFor
      ..imagesInvalidated = imagesInvalidated
      ..tileEffect = tileEffect
      ..onSlotsNeeded = onSlotsNeeded
      ..onVisibleItemsChanged = onVisibleItemsChanged
      ..style = style;
  }
}

/// One paint op of the current frame — a decoded image, a laid-out child,
/// or a placeholder rect when neither is ready yet, in back-to-front order.
/// When [morphFrom] or [morphTo] is set the op draws the pair morph
/// departing→arriving at [morphT] instead of the plain image.
typedef _OverlayPaintOp = ({
  ui.Image? image,
  RenderBox? child,
  Rect rect,
  double opacity,
  ui.Image? morphFrom,
  ui.Image? morphTo,
  double? morphT,
  String? swapKey,
  Color? debugColor,
  bool onNextScreen,

  /// Destination-lattice content — the arriving stop's item at the slot.
  /// Arriving ops may morph in through the tile effect; departing
  /// coverage and stable copies stay rigid.
  bool arriving,
});

final class _RenderMorphOverlay extends RenderBox with ContainerRenderObjectMixin<RenderBox, _OverlayChildData> {
  _RenderMorphOverlay({
    required PinchMorph morph,
    required PinchMorphStyle style,
    required Set<int> sectionStarts,
    required Color background,
    required Color missingTile,
    required double spacing,
    required ui.Image? Function(int index, int targetSize)? imageFor,
    required Listenable? imagesInvalidated,
    required this.onSlotsNeeded,
    required this.onVisibleItemsChanged,
    TileMorphEffect? tileEffect,
  }) : _morph = morph,
       _style = style,
       _sectionStarts = sectionStarts,
       _background = background,
       _missingTile = missingTile,
       _spacing = spacing,
       _imageFor = imageFor,
       _imagesInvalidated = imagesInvalidated,
       _tileEffect = tileEffect {
    _backgroundPaint.color = background;
    _missingTilePaint.color = missingTile;
  }

  PinchMorph _morph;
  PinchMorphStyle _style;

  /// Morph tuning — pills and the sticky-image cache read it.
  PinchMorphStyle get style => _style;
  set style(PinchMorphStyle value) {
    if (identical(_style, value)) return;
    _style = value;
    // pillExtent/pillGap feed performLayout — a style swap is a relayout,
    // not just a repaint.
    markNeedsLayout();
  }

  PinchMorph get morph => _morph;
  set morph(PinchMorph value) {
    if (identical(value, _morph)) return;
    if (attached) _morph.removeListener(markNeedsLayout);
    _morph = value;
    if (attached) _morph.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  Set<int> _sectionStarts;
  Set<int> get sectionStarts => _sectionStarts;
  set sectionStarts(Set<int> value) {
    if (identical(value, _sectionStarts)) return;
    _sectionStarts = value;
    markNeedsLayout();
  }

  Color _background;
  Color get background => _background;
  set background(Color value) {
    if (value == _background) return;
    _background = value;
    _backgroundPaint.color = value;
    markNeedsPaint();
  }

  Color _missingTile;
  Color get missingTile => _missingTile;
  set missingTile(Color value) {
    if (value == _missingTile) return;
    _missingTile = value;
    _missingTilePaint.color = value;
    markNeedsPaint();
  }

  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  ui.Image? Function(int index, int targetSize)? _imageFor;
  ui.Image? Function(int index, int targetSize)? get imageFor => _imageFor;
  set imageFor(ui.Image? Function(int index, int targetSize)? value) {
    if (identical(value, _imageFor)) return;
    _imageFor = value;
    markNeedsLayout();
  }

  Listenable? _imagesInvalidated;
  Listenable? get imagesInvalidated => _imagesInvalidated;
  set imagesInvalidated(Listenable? value) {
    if (identical(value, _imagesInvalidated)) return;
    if (attached) _imagesInvalidated?.removeListener(markNeedsLayout);
    _imagesInvalidated = value;
    if (attached) _imagesInvalidated?.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  /// Pixel transform for image-painted tiles — `null` keeps the plain
  /// cover-fit draw. Repaint-only: geometry never depends on the effect.
  TileMorphEffect? _tileEffect;
  TileMorphEffect? get tileEffect => _tileEffect;
  set tileEffect(TileMorphEffect? value) {
    if (identical(value, _tileEffect)) return;
    _tileEffect = value;
    markNeedsPaint();
  }

  _OverlaySlotsNeeded? onSlotsNeeded;

  /// Called when the emitted frame's painted index set changes — the
  /// report an image cache uses to prioritize its decode queue.
  void Function(Set<int> indices)? onVisibleItemsChanged;

  final _ops = <_OverlayPaintOp>[];
  final _missingTiles = <int>{};
  final _missingPills = <(int, int)>{};
  final _requestedTiles = <int>{};
  final _requestedPills = <(int, int)>{};

  /// Consecutive layouts an index emitted without a decoded image or a
  /// mounted child. Below [_mountStreak] a miss paints the placeholder
  /// tint and requests no child — a decode that lands before the streak
  /// matures never pays a widget mount. The streak doubles as the
  /// miss's retry budget: while any miss sits below [_missRetryLayouts]
  /// the overlay keeps scheduling one follow-up layout per frame (see
  /// [performLayout]).
  final _missStreaks = <int, int>{};

  /// Layouts an unpainted slot waits before the widget layer mounts a
  /// child for it.
  static const _mountStreak = 3;

  /// Follow-up layouts a still-unpainted slot gets before the overlay
  /// stops re-laying out on its own. A decode lands through
  /// [_imagesInvalidated], but background thumbnail warming fills the
  /// tile cache silently — a held pinch that stops feeding pointer
  /// deltas would strand those slots on the placeholder tint until the
  /// fingers moved. ~45 frames ≈ ¾s covers decode plus short warming
  /// gaps; a permanently absent tile doesn't burn a layout per frame.
  static const _missRetryLayouts = 45;

  /// Last decoded image painted per slot — [imageFor] can lapse under
  /// cache pressure mid-gesture, and repainting the last frame keeps the
  /// slot from flashing the placeholder tint (or remounting a child) for
  /// pixels it already showed. Cloned handles, ~[style.stickyImageBytes] retained.
  final _lastImages = <int, ui.Image>{};
  int _lastImageBytes = 0;

  /// The item epoch the sticky cache was filled under. A resync renumbers
  /// every index, so a stale hit repaints the item that USED to sit at an
  /// index — a one-frame wrong photo — until the real decode lands.
  int _stickyEpoch = -1;

  /// Block-matched A→B displacement fields for paired swap ops, keyed
  /// 'departingIndex>arrivingIndex'. Computed once per pair on an isolate,
  /// then sampled by the pair-morph shader path. Tiny (24×24) textures.
  final _flowFields = <String, ui.Image>{};
  final _flowPending = <String>{};

  /// Indices the last emitted frame paints — the engine's live
  /// [PinchMorph.visibleIndices], maintained inside `frame()`. Sticky
  /// retention protects these: off-screen entries evict before on-screen
  /// ones regardless of arrival order, so a fast scroll or a random-date
  /// jump keeps the screen the user is looking at.
  Set<int> get _visibleIndices => _morph.visibleIndices;

  /// The visible-index set last reported through [onVisibleItemsChanged] —
  /// deduped so the callback only fires when the painted set changes.
  Set<int>? _reportedVisible;

  final _backgroundPaint = Paint();
  final _missingTilePaint = Paint();
  final _imagePaint = Paint();
  RenderBox? _headerChild;
  double _clipTop = 0;
  double _clipBottom = 0;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _morph.addListener(markNeedsLayout);
    _imagesInvalidated?.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _morph.removeListener(markNeedsLayout);
    _imagesInvalidated?.removeListener(markNeedsLayout);
    _dropImageOps();
    _dropLastImages();
    _dropFlowFields();
    super.detach();
  }

  @override
  void dispose() {
    _dropImageOps();
    _dropLastImages();
    _dropFlowFields();
    super.dispose();
  }

  /// Releases the overlay's own image handles. Each op clones the image it
  /// is handed, so [MorphOverlayImageCache]-style evictions can never drop
  /// a handle a recorded paint op still references.
  void _dropImageOps() {
    for (final op in _ops) {
      op.image?.dispose();
      op.morphFrom?.dispose();
      op.morphTo?.dispose();
    }
    _ops.clear();
  }

  /// Keeps a cloned handle of a just-resolved tile image so a later lapse
  /// can repaint it — oldest off-screen entries evict first once past
  /// [style.stickyImageBytes]; a visible image only evicts when every
  /// retained image is on screen.
  void _rememberImage(int index, ui.Image image) {
    final previous = _lastImages.remove(index);
    if (previous != null) {
      _lastImageBytes -= previous.width * previous.height * _bytesPerPixel;
      previous.dispose();
    }
    final clone = image.clone();
    _lastImages[index] = clone;
    _lastImageBytes += clone.width * clone.height * _bytesPerPixel;
    while (_lastImageBytes > style.stickyImageBytes && _lastImages.isNotEmpty) {
      var evictKey = _lastImages.keys.first;
      for (final k in _lastImages.keys) {
        if (!_visibleIndices.contains(k)) {
          evictKey = k;
          break;
        }
      }
      final evicted = _lastImages.remove(evictKey);
      if (evicted == null) break;
      _lastImageBytes -= evicted.width * evicted.height * _bytesPerPixel;
      evicted.dispose();
    }
  }

  void _dropLastImages() {
    for (final image in _lastImages.values) {
      image.dispose();
    }
    _lastImages.clear();
    _lastImageBytes = 0;
  }

  /// Kicks off the A→B field for a just-discovered swap pair — the pair
  /// morphs with it on subsequent frames; until it lands the shader falls
  /// back to a two-texture blend. Cloned handles keep the sources alive
  /// across the async gap — the provider may evict its own copies before
  /// toByteData runs, which would otherwise throw and leave the pair on
  /// the blend fallback for the whole swap.
  void _ensureFlow(String key, ui.Image from, ui.Image to) {
    // Cap in-flight computes so a swap burst queues instead of spawning a
    // fresh isolate per pair at once — skipped pairs retry next frame.
    if (_flowFields.containsKey(key) || _flowPending.length >= 6 || !_flowPending.add(key)) {
      return;
    }
    final fromClone = from.clone();
    final toClone = to.clone();
    unawaited(
      _tileEffect!
          .flowImage(fromClone, toClone)
          .then(
            (flow) {
              fromClone.dispose();
              toClone.dispose();
              _flowPending.remove(key);
              if (flow != null) {
                _flowFields[key] = flow;
                // Relayout (not just repaint): op-build is where queued pairs
                // retry — without it the pairs that lost the concurrency cap
                // never reschedule once the pointer holds still mid-window.
                markNeedsLayout();
              }
            },
            onError: (Object e) {
              debugPrint('flow compute failed: $e');
              fromClone.dispose();
              toClone.dispose();
              _flowPending.remove(key);
            },
          ),
    );
  }

  void _dropFlowFields() {
    for (final field in _flowFields.values) {
      field.dispose();
    }
    _flowFields.clear();
    _flowPending.clear();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _OverlayChildData) {
      child.parentData = _OverlayChildData();
    }
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    _dropImageOps();
    _missingTiles.clear();
    _missingPills.clear();
    _headerChild = null;
    if (_morph.stops.isEmpty || _morph.itemCount == 0) return;

    // An item-list resync remaps every index — sticky entries keyed by
    // index now point at different photos. Drop them rather than repaint
    // a wrong image under any slot that lapses.
    if (_stickyEpoch != _morph.itemEpoch) {
      _dropLastImages();
      _missStreaks.clear();
      _stickyEpoch = _morph.itemEpoch;
    }

    final frame = _morph.frame(_sectionStarts.contains);
    final visible = _morph.visibleIndices;
    if (!setEquals(visible, _reportedVisible)) {
      _reportedVisible = Set.of(visible);
      onVisibleItemsChanged?.call(Set.unmodifiable(visible));
    }
    _clipTop = frame.clipTop;
    _clipBottom = frame.clipBottom;
    final scrollBy = Offset(0, -frame.clipTop);

    // Index mounted children by slot.
    final tiles = <int, RenderBox>{};
    final pills = <(int, int), RenderBox>{};
    RenderBox? header;
    visitChildren((child) {
      final box = child as RenderBox;
      final data = box.parentData! as _OverlayChildData;
      if (data.isHeader) {
        header = box;
      } else if (data.pillLayer >= 0) {
        pills[(data.pillLayer, data.pillIndex)] = box;
      } else {
        tiles[data.tileIndex] = box;
      }
    });

    // Tiles in frame order — that is the paint order (back to front).
    // The emitter stacks swap pairs at one slot: the departing photo first
    // (under layer), the arriving photo last (over layer) — so the second
    // image op at a slot is the arriving one, and its emitted opacity IS
    // the swap ramp in both pinch directions (zoom-out crossfade rises
    // 0→1; zoom-in runs the same ramp as progress unwinds 1→0). Pair them
    // through [TileMorphEffect.paintPair]; [paired] guards the boundary
    // band, which can stack a keyed carrier third at a slot. Pairing keys
    // on the slot offset — the arriving layer may emit on its own centred
    // lattice column rather than the departing tile's band rect.
    final seen = <(int, int), (int, ui.Image)>{};
    final paired = <(int, int)>{};
    final used = <RenderBox>{};
    final tinted = <(int, int)>{};
    final unpainted = <int>{};
    final mountStreak = _imageFor == null ? 1 : _mountStreak;
    for (final tile in frame.tiles) {
      // Degenerate geometry would reach the canvas as NaN — an engine-side
      // abort rather than a catchable Dart error.
      if (!tile.rect.isFinite) continue;
      // Tint only while the zoom is in flight — level sits between stops
      // while pinching and through the settle; on the landed frame it
      // equals settleStop and the heatmap goes away with the morph. One
      // tint per slot — its first VISIBLE op: an invisible keyed carrier
      // paints nothing, and a second op's own ring would mark the cell
      // twice, spreading the heatmap to every slot a swap passes through
      // rather than the band that actually morphs.
      final debugColor =
          _morph.debugPaint &&
              _morph.level != _morph.settleStop &&
              tile.opacity > 0.01 &&
              tinted.add((tile.columnOffset, tile.rowOffset))
          ? _debugRingColor(tile)
          : null;
      var image = _imageFor?.call(tile.index, tile.targetSize);
      if (image != null) {
        _rememberImage(tile.index, image);
      } else {
        // The provider/cache lapsed mid-gesture — repaint the last frame it
        // gave this slot rather than dropping to a placeholder.
        image = _lastImages[tile.index];
      }
      if (image != null) {
        // The op's own clone is made up front and `seen` references that —
        // never the provider's or sticky cache's handle. A later `imageFor`
        // call can evict the provider's copy mid-pass (a provider stream
        // may complete synchronously and run a cache eviction), and
        // `_rememberImage` can dispose a sticky handle this frame still
        // needs — a raw handle in `seen` could be dead before its swap
        // partner clones it.
        final opImage = image.clone();
        ui.Image? morphFrom;
        ui.Image? morphTo;
        double? morphT;
        String? swapKey;
        final slot = (tile.columnOffset, tile.rowOffset);
        final prev = seen[slot];
        if (kOverlayPairMorph &&
            _tileEffect != null &&
            _morph.level != _morph.startStop &&
            prev != null &&
            prev.$1 != tile.index &&
            tile.opacity > 0.01 &&
            paired.add(slot)) {
          // Below the opacity gate the arriving op is a keyed carrier — a
          // ~0 morph would still draw the departing photo opaque through
          // the shader, resurrecting a tile the emitter meant invisible.
          morphFrom = prev.$2.clone();
          morphTo = opImage.clone();
          morphT = tile.opacity;
          swapKey = '${prev.$1}>${tile.index}';
          _ensureFlow(swapKey, morphFrom, morphTo);
        }
        seen[slot] ??= (tile.index, opImage);
        _ops.add((
          image: opImage,
          child: null,
          rect: tile.rect,
          opacity: tile.opacity,
          morphFrom: morphFrom,
          morphTo: morphTo,
          morphT: morphT,
          swapKey: swapKey,
          debugColor: debugColor,
          onNextScreen: tile.onNextScreen,
          arriving: tile.arriving,
        ));
        continue;
      }
      final child = tiles[tile.index];
      if (child == null) {
        unpainted.add(tile.index);
        // With a decoded-image path a miss is usually a decode racing
        // the pointer — mounting a widget for it costs a whole frame
        // while the tint costs a rect, so only a persistent miss asks
        // for a child. Without imageFor the mounted child IS the paint
        // path — mount on the first miss like before.
        if ((_missStreaks[tile.index] = (_missStreaks[tile.index] ?? 0) + 1) >= mountStreak) {
          _missingTiles.add(tile.index);
        }
        // No decoded image and no mounted child yet — paint the placeholder
        // tint so the slot reads as a loading tile, not a backdrop hole.
        _ops.add((
          image: null,
          child: null,
          rect: tile.rect,
          opacity: tile.opacity,
          morphFrom: null,
          morphTo: null,
          morphT: null,
          swapKey: null,
          debugColor: debugColor,
          onNextScreen: tile.onNextScreen,
          arriving: tile.arriving,
        ));
        continue;
      }
      child.layout(BoxConstraints.tight(tile.rect.size), parentUsesSize: true);
      final data = child.parentData! as _OverlayChildData;
      data
        ..offset = tile.rect.topLeft + scrollBy
        ..opacity = tile.opacity.clamp(0.0, 1.0);
      _ops.add((
        image: null,
        child: child,
        rect: tile.rect,
        opacity: data.opacity,
        morphFrom: null,
        morphTo: null,
        morphT: null,
        swapKey: null,
        debugColor: debugColor,
        onNextScreen: tile.onNextScreen,
        arriving: tile.arriving,
      ));
      used.add(child);
    }

    // A streak lives only while its slot stays unpainted — an index that
    // painted (image or child) or left the window starts fresh next time.
    _missStreaks.removeWhere((index, _) => !unpainted.contains(index));

    // While any miss still has retry budget, queue one more layout —
    // content can arrive without notifying [_imagesInvalidated] (a
    // background warm writes the tile cache directly), so a held pinch
    // that stops producing pointer deltas would otherwise strand these
    // slots on the placeholder tint. Bounded per miss by its streak.
    if (unpainted.any((index) => (_missStreaks[index] ?? 0) <= _missRetryLayouts)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) markNeedsLayout();
      });
    }

    // Section pills share the tiles' clip and scroll offset, spaced by the
    // same rule the rest-state pill layer uses.
    final sorted = [...frame.pills]..sort((a, b) => a.top.compareTo(b.top));
    final lastTop = [double.negativeInfinity, double.negativeInfinity];
    for (final pill in sorted) {
      final top = pill.top + style.pillGap;
      if (top < frame.clipTop ||
          top + style.pillExtent > frame.clipBottom ||
          top - lastTop[pill.layer] < style.pillExtent + style.pillGap) {
        continue;
      }
      lastTop[pill.layer] = top;
      final slot = (pill.layer, pill.index);
      final child = pills[slot];
      if (child == null) {
        _missingPills.add(slot);
        continue;
      }
      // Height pinned to style.pillExtent — the dedup/clip math above is
      // computed in the same units, so a custom pill taller than the
      // extent would overlap the band below it.
      child.layout(
        BoxConstraints(maxWidth: size.width, minHeight: style.pillExtent, maxHeight: style.pillExtent),
        parentUsesSize: true,
      );
      final data = child.parentData! as _OverlayChildData;
      data
        ..offset = Offset(_spacing + _pillInset, top) + scrollBy
        ..opacity = pill.opacity.clamp(0.0, 1.0);
      _ops.add((
        image: null,
        child: child,
        rect: Rect.zero,
        opacity: data.opacity,
        morphFrom: null,
        morphTo: null,
        morphT: null,
        swapKey: null,
        debugColor: null,
        onNextScreen: false,
        arriving: false,
      ));
      used.add(child);
    }

    // The header floats above the clip, riding the frame's headerTop.
    if (header != null) {
      header!.layout(BoxConstraints.tightFor(width: size.width), parentUsesSize: true);
      (header!.parentData! as _OverlayChildData).offset = Offset(0, frame.headerTop);
      _headerChild = header;
    }

    // Children not in this frame still need a layout pass — a freshly
    // inserted child that stays dirty trips the semantics flush.
    visitChildren((child) {
      final box = child as RenderBox;
      if (!used.contains(box) && !identical(box, _headerChild)) {
        box.layout(BoxConstraints.tight(Size.zero), parentUsesSize: true);
      }
    });

    // Slots without children: ask for them once per new slot set — the
    // widget mounts them and the next layout picks them up.
    final needTiles = _missingTiles.isNotEmpty && !setEquals(_missingTiles, _requestedTiles);
    final needPills = _missingPills.isNotEmpty && !setEquals(_missingPills, _requestedPills);
    if ((needTiles || needPills) && onSlotsNeeded != null) {
      _requestedTiles
        ..clear()
        ..addAll(_missingTiles);
      _requestedPills
        ..clear()
        ..addAll(_missingPills);
      final tileSet = Set.of(_missingTiles);
      final pillSet = Set.of(_missingPills);
      WidgetsBinding.instance.addPostFrameCallback((_) => onSlotsNeeded?.call(tileSet, pillSet));
    }
  }

  /// This render pushes layers (clip + per-tile opacity), so ancestors must
  /// treat its subtree as composited.
  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Fully opaque backdrop — the resting grid is covered while the morph
    // owns the frame. Drawn before any layer push so it lands in the first
    // recording segment.
    context.canvas.drawRect(offset & size, _backgroundPaint);

    // Tiles and pills under the header band's clip. The clip goes through
    // pushClipRect's layer path — composited children are clipped too, and
    // a canvas-level save/restore would not survive the painter's own
    // layer pushes (they finalize the recording).
    context.pushClipRect(
      needsCompositing,
      offset,
      Rect.fromLTWH(0, _clipTop, size.width, math.max(0.0, _clipBottom - _clipTop)),
      (ctx, off) {
        for (final op in _ops) {
          final dst = op.rect.translate(off.dx, off.dy - _clipTop);
          final image = op.image;
          if (image != null) {
            if (dst.isFinite && !dst.isEmpty) {
              _paintTileImage(ctx.canvas, image, dst, op);
            }
          } else {
            final child = op.child;
            if (child == null) {
              // Requested child hasn't mounted yet — placeholder tint.
              if (dst.isFinite && !dst.isEmpty) {
                ctx.canvas.drawRect(dst, _missingTilePaint..color = _missingTile.withValues(alpha: op.opacity));
              }
            } else if (child.attached) {
              // A child detached mid-frame (slot churn) must not be painted —
              // paintChild on a detached render is undefined behaviour.
              // Position from the op's own rect, not the child's parentData —
              // the helical remap can emit one index at two slots (departing
              // at one, arriving at another), so the same child paints at each
              // rect with each op's own opacity.
              final at = off + op.rect.topLeft - Offset(0, _clipTop);
              if (at.isFinite) {
                if (op.opacity < 0.999) {
                  ctx.pushOpacity(at, (op.opacity * 255).round(), (c, o) => c.paintChild(child, o));
                } else {
                  ctx.paintChild(child, at);
                }
              }
            }
          }
          // Debug heatmap — a translucent tint over the real tile: the focal
          // cell is the hot centre, rings cool outward, and off-next-screen
          // slots get a faint dark veil over the photo they keep.
          final debugColor = op.debugColor;
          if (debugColor != null && dst.isFinite && !dst.isEmpty) {
            ctx.canvas.drawRect(
              dst,
              Paint()..color = debugColor.withValues(alpha: debugColor.a * op.opacity.clamp(0.0, 1.0)),
            );
          }
        }
      },
    );

    final header = _headerChild;
    if (header != null) {
      context.paintChild(header, offset + (header.parentData! as _OverlayChildData).offset);
    }
  }

  /// Debug-paint tint for [tile]'s slot — a translucent heatmap radiating
  /// from the focal cell: hot red centre cooling through orange, yellow,
  /// green and blue per ring outward, and a dark veil on slots whose
  /// destination lands off the next screen (see [PinchMorph.debugPaint]).
  Color _debugRingColor(MorphTile tile) {
    if (!tile.onNextScreen) return const Color(0x99000000);
    const heat = [
      Color(0xCCFF1744), // focal — hot red
      Color(0xCCFF9100), // ring 1 — orange
      Color(0xCCFFEA00), // ring 2 — yellow
      Color(0xCC00E676), // ring 3 — green
      Color(0xCC00E5FF), // ring 4 — cyan
      Color(0xCC2979FF), // ring 5 — blue
      Color(0xCCD500F9), // ring 6+ — purple
    ];
    final ring = math.max(tile.columnOffset.abs(), tile.rowOffset.abs());
    return heat[math.min(ring, heat.length - 1)];
  }

  /// Center-crops [image] into [dst] — the same cover fit the tiles use.
  /// With [tileEffect] the tile goes through the shader: swap pairs
  /// (op.morphFrom/morphTo) morph from→to along the block-matched field,
  /// lone tiles get the focal warp + dissolve. Fallback without the effect
  /// is a plain cover-fit draw. The pair-carrying op is the second image
  /// op at its rect — always the arriving photo — so the morph runs
  /// departing→arriving in both pinch directions.
  void _paintTileImage(Canvas canvas, ui.Image image, Rect dst, _OverlayPaintOp op) {
    final effect = _morph.level != _morph.startStop ? _tileEffect : null;
    if (effect != null) {
      // Interval progress (0..1 within the current stop crossing) and the
      // pinch focal in tile-local UV — the effect clamps focal to 0..1, so
      // pass the raw ratio.
      final pinch = _morph.focalPoint;
      final focal = Offset((pinch.dx - dst.left) / dst.width, (pinch.dy - dst.top) / dst.height);
      final morphFrom = op.morphFrom;
      final morphTo = op.morphTo;
      if (morphFrom != null || morphTo != null) {
        effect.paintPair(
          canvas,
          from: morphFrom ?? image,
          to: morphTo ?? image,
          flow: op.swapKey == null ? null : _flowFields[op.swapKey],
          rect: dst,
          t: (op.morphT ?? op.opacity).clamp(0.0, 1.0),
          progress: _morph.interval.$2,
          focal: focal,
        );
        return;
      }
      // Lone-tile shader use is confined to the destination rectangle and
      // to content that may deform: zoom-in keeps its established look —
      // every unpaired in-rectangle op warps (departing photos inside the
      // morph region bend with it). Zoom-out adds the ARRIVING side: an
      // unpaired arriving photo materialises through the shader instead
      // of an alpha ramp — the effect consumes opacity as a per-pixel
      // dissolve threshold, so it reads as a morph, not a fade. Departing
      // coverage and off-rectangle ops stay on the plain draw: a warp
      // deforms rigid coverage, and off-window arrivals are new
      // territory that slides in undeformed.
      if (op.onNextScreen && (_morph.level < _morph.startStop || op.arriving)) {
        effect.paint(canvas, image: image, rect: dst, progress: _morph.interval.$2, focal: focal, opacity: op.opacity);
        return;
      }
    }
    final srcSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, srcSize, dst.size);
    final src = Alignment.center.inscribe(fitted.source, Offset.zero & srcSize);
    _imagePaint
      ..color = Colors.white.withValues(alpha: op.opacity.clamp(0.0, 1.0))
      ..filterQuality = FilterQuality.low
      ..imageFilter = null;
    canvas.drawImageRect(image, src, dst, _imagePaint);
  }
}

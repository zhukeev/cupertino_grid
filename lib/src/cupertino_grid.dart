import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'morph_frame.dart';
import 'morph_grid_stop.dart';
import 'pinch_morph_style.dart';
import 'pinch_morph.dart';
import 'tile_morph_effect.dart';

part 'cupertino_grid/gesture_handlers.dart';
part 'cupertino_grid/morph_overlay.dart';
part 'cupertino_grid/scroll_anchor.dart';
part 'cupertino_grid/two_finger_recognizer.dart';

/// Breathing room a section pill keeps inside its reference edge — the
/// overlay paints pills at `spacing + _pillInset` from the grid padding
/// and the rest-state layer pins the stuck pill the same distance below
/// the header/top line. Internal chrome constant, deliberately not a
/// [PinchMorphStyle] knob.
const double _pillInset = 6;

/// Bytes per decoded RGBA pixel — the overlay's sticky-image budget is
/// accounted in bytes, so width×height needs this factor.
const int _bytesPerPixel = 4;

int _lowerBound(List<int> sorted, int value) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (sorted[mid] < value) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// What a release past the largest-tile stop hands the host: the pinched
/// item's index (resolved against the current cell list), the stretched
/// cell's painted rect in GLOBAL screen coordinates, and the raw stretch
/// factor. A detail viewer opens its shared-element flight from [rect] —
/// the pose the user's fingers left the photo at — so the open is a
/// continuation of the pinch, not a restart.
final class OverscaleCommit {
  /// Creates the payload.
  const OverscaleCommit({required this.index, required this.rect, required this.overscale, required this.targetSize});

  /// The pinched item, re-resolved through its item/anchor keys — stack
  /// fold/unfold and merges mid-gesture can't hand back a stale index.
  final int index;

  /// Global screen rect the stretched cell was painted at on the release
  /// frame — the flyer's launch rect. For a reduce-motion pinch (no
  /// painted overscale) it is the resting grid cell's rect instead.
  final Rect rect;

  /// The tracked stretch past the largest-tile stop at release.
  final double overscale;

  /// The decode-size hint the overlay painted the cell at — the same
  /// value [overlayItemBuilder] and an `overlayImageFor`-style lookup
  /// received, so the host re-queries the image at the key the paint
  /// actually used. [rect] is stretched past it by [overscale]; sizing
  /// the lookup off the rect misses the cached decode entirely.
  final int targetSize;
}

/// A self-contained photo grid with iOS-Photos-style pinch zoom: pinching
/// morphs the grid continuously between column counts — the photo under the
/// fingers stays under them, cells change size and shape while the pinch is
/// scrubbed, and on release the grid springs onto the nearest column count.
///
/// The widget owns scrolling, the pinch recognizer, the morph overlay and
/// the settle/commit choreography; the caller supplies items through
/// [itemBuilder] and the available densities through [columnCounts].
///
/// ```dart
/// CupertinoGrid(
///   itemCount: photos.length,
///   columnCounts: const [1, 3, 5],
///   itemBuilder: (context, index, targetSize) =>
///       MyThumbnail(photo: photos[index], targetSize: targetSize),
/// )
/// ```
///
/// `targetSize` is the cell's logical width at the current stop — pass it to
/// the thumbnail loader so overlays and the resting grid request the same
/// resolution (no reload flash when a pinch commits).
///
/// The geometry model: one helical slot lattice drawn per frame, nearer-stop
/// scaling outside the reflow window, slot glide + occupant morph inside it,
/// blended-extent vertical clamp, geometric tile-size interpolation. The
/// full contract lives in the package's `AGENTS.md` in the repository.
final class CupertinoGrid extends StatefulWidget {
  /// Creates the grid — see the class docs for the full contract.
  const CupertinoGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.columnCounts = const [1, 3, 5],
    this.columnCountsForWidth,
    this.columns,
    this.initialColumns,
    this.onColumnsChanged,
    this.onOverscaleCommit,
    this.itemKey,
    this.itemAnchorKey,
    this.itemsVersion,
    this.removedItemBuilder,
    this.changeAnimationDuration = const Duration(milliseconds: 180),
    this.overlayItemBuilder,
    this.headerBuilder,
    this.leadingSlivers,
    this.footer,
    this.emptyBuilder,
    this.onRefresh,
    this.scrollDecorator,
    this.onNearEnd,
    this.nearEndExtent = 800,
    this.onWarmRange,
    this.onVisibleAnchorChanged,
    this.overlayBuilder,
    this.overlayImageFor,
    this.overlayImagesListenable,
    this.overlayTileEffect,
    this.overlayTileEffectBuilder,
    this.onVisibleItemsChanged,
    this.sectionLabelFor,
    this.sectionLabelVersion,
    this.sectionLabelBuilder,
    this.minLabelColumns = 7,
    this.holdScrollAnchor = true,
    this.spacing = 2.0,
    this.tileAspect,
    this.background,
    this.centerFocalOnCommit = false,
    this.enablePinch = true,
    this.scrollController,
    this.reverse = false,
    this.mirrorRows = false,
    this.topClearance = 0,
    this.morphCoverageLeading,
    this.physics,
    this.overlayFadeDuration = const Duration(milliseconds: 140),
    this.debugLog,
    this.debugMorphPaint = false,
    this.style = const PinchMorphStyle(),
  }) : assert(
         overlayTileEffect == null || overlayTileEffectBuilder == null,
         'overlayTileEffect and overlayTileEffectBuilder are mutually exclusive',
       );

  /// Number of items in the grid.
  final int itemCount;

  /// Renders one cell. [targetSize] is the cell's logical width — the same
  /// value the resting grid requests after a commit, so thumbnails loaded
  /// during the morph are reused without a reload.
  final Widget Function(BuildContext context, int index, int targetSize) itemBuilder;

  /// Column counts the pinch can travel between. Duplicates are dropped and
  /// the list is sorted internally, fewest columns first.
  final List<int> columnCounts;

  /// Computes [columnCounts] from the actual viewport width when the ladder
  /// depends on it (e.g. more columns on tablets). Takes precedence over
  /// [columnCounts] and is re-evaluated on every layout.
  final List<int> Function(double viewportWidth)? columnCountsForWidth;

  /// Controlled current column count. When null the widget tracks density
  /// internally from [initialColumns]; when set, commits are reported
  /// through [onColumnsChanged] and the parent supplies the new value —
  /// use this when density lives in external state (a settings cubit).
  final int? columns;

  /// Column count the grid starts at in uncontrolled mode; defaults to the
  /// middle of the ladder.
  final int? initialColumns;

  /// Called after a pinch settles onto a different column count.
  final ValueChanged<int>? onColumnsChanged;

  /// Called when a pinch releases while cells are stretched past the
  /// largest-tile stop by more than
  /// [PinchMorphStyle.overscaleCommitThreshold] — the "keep zooming at the
  /// last zoom" gesture iOS Photos uses to open the detail viewer. The
  /// [OverscaleCommit] payload carries the pinched item's resolved index,
  /// the stretched cell's painted screen rect (a shared-element flight
  /// launches straight from it), and the release stretch. The grid still
  /// settles back to the largest stop underneath. When null, overscaling
  /// stays a pure rubber-band.
  final ValueChanged<OverscaleCommit>? onOverscaleCommit;

  /// Stable identity for the item at [index] (e.g. its id). Used for grid
  /// and overlay tile keys so morph tiles never remount across a stop
  /// crossing. Defaults to the index itself — supply a real key when items
  /// can be inserted or removed.
  final Object? Function(int index)? itemKey;

  /// Group identity for an item that survives cell-list reshapes — stack
  /// fold/unfold, merges, reorders. The commit re-resolves the pinched
  /// item's index through this key so the settled grid keeps it under the
  /// finger: members of a collapsible group should return the group's key,
  /// so a member pinched just before its group collapses anchors to the
  /// group's surviving header cell. Defaults to [itemKey].
  final Object? Function(int index)? itemAnchorKey;

  /// Invalidation token for the key→index map and the insert/remove diff —
  /// pass the items list instance so a reordered or re-merged list resyncs
  /// even when [itemCount] is unchanged. Without it the grid can only tell
  /// items apart by count and position.
  final Object? itemsVersion;

  /// Renders a cell animating out after its item was removed; defaults to a
  /// blank fading cell (the item is usually gone from the list already).
  final Widget Function(BuildContext context, int index, Animation<double> animation)? removedItemBuilder;

  /// Duration of insert/remove cell animations. Pure page appends and
  /// trailing evictions are always instant — animating a whole page is jank.
  final Duration changeAnimationDuration;

  /// Renders overlay cells during the morph instead of [itemBuilder] —
  /// useful when resting tiles carry decorations that should not crossfade
  /// (file-name labels, hero tags). When null, [itemBuilder] is reused with
  /// heroes suppressed via [HeroMode].
  final Widget Function(BuildContext context, int index, int targetSize)? overlayItemBuilder;

  /// Content above the grid (e.g. a library header). Rendered as a
  /// `SliverToBoxAdapter` and replicated inside the morph overlay so it
  /// scrolls and clips exactly like the real header during a pinch.
  final WidgetBuilder? headerBuilder;

  /// Slivers inserted before the header sliver (e.g. a custom refresh
  /// sliver). Their extent counts towards the measured grid origin.
  final List<Widget> Function(BuildContext context)? leadingSlivers;

  /// Trailing sliver content below the grid (e.g. a load-more spinner). Its
  /// extent is measured from the scroll metrics, so the morph's bottom-edge
  /// clamp accounts for it automatically.
  final Widget? footer;

  /// Shown instead of the grid when [itemCount] is zero.
  final WidgetBuilder? emptyBuilder;

  /// Wraps the scroll view in a [RefreshIndicator] when set. Ignored when
  /// [scrollDecorator] is provided.
  final Future<void> Function()? onRefresh;

  /// Wraps the scroll view in a custom decorator (e.g. a platform-styled
  /// refresh indicator). Receives the built scroll view and returns its
  /// decorated replacement.
  final Widget Function(BuildContext context, Widget scrollView)? scrollDecorator;

  /// Called whenever the scroll offset comes within [nearEndExtent] of the
  /// bottom — hook for pagination.
  final VoidCallback? onNearEnd;

  /// Distance in pixels above the bottom at which [onNearEnd] fires.
  final double nearEndExtent;

  /// Thumbnail warming. During pinch start/settle the widget reports the
  /// visible item range at each reachable stop's own tile size — preload
  /// those thumbnails so morph frames and the committed grid never flash.
  final void Function(int startIndex, int endIndex, int tileSize, double devicePixelRatio)? onWarmRange;

  /// Fires when the topmost fully scrolled row's anchor item changes —
  /// [direction] is +1 scrolling down, −1 up; [tileSize] is the current
  /// cell width for resolution-aware prefetch.
  final void Function(int anchorIndex, int direction, int tileSize)? onVisibleAnchorChanged;

  /// Extra layer between the resting grid and the morph overlay (e.g. a
  /// timeline scrubber). The returned widget is placed as a direct [Stack]
  /// child — return a [Positioned] for free placement. Receives the current
  /// stop, the measured grid origin and the scroll controller, plus whether
  /// a morph is active — overlays that only make sense at rest return a
  /// shrink box then.
  final Widget? Function(
    BuildContext context, {
    required MorphGridStop stop,
    required double gridOrigin,
    required ScrollController scrollController,
    required bool morphActive,
  })?
  overlayBuilder;

  /// Decoded-image fast path for the morph overlay. When this returns a
  /// [ui.Image] for [index] at [targetSize], the tile paints directly on
  /// the overlay's canvas — no child widget is mounted for it. Indices
  /// returning null fall back to [overlayItemBuilder]/[itemBuilder]
  /// children, so thumbnails that aren't decoded yet still show.
  ///
  /// Pair with [overlayImagesListenable] so async decodes re-resolve.
  final ui.Image? Function(int index, int targetSize)? overlayImageFor;

  /// Notifies the overlay that [overlayImageFor] may resolve more tiles
  /// (e.g. a decode cache filled). Only repaints — geometry is unchanged.
  final Listenable? overlayImagesListenable;

  /// Optional pixel-level transform for morph tiles — when set, tiles that
  /// resolve through [overlayImageFor] are painted through the
  /// [TileMorphEffect] instead of a plain [Canvas.drawImageRect].
  /// Widget-painted tiles (no decoded image) are unaffected, and `null`
  /// keeps the plain cover-fit draw (the simple blend look). See
  /// `package:image_morph` for a runtime-shader implementation; any
  /// [TileMorphEffect] — crossfade, warp, future styles — plugs in here.
  /// Mutually exclusive with [overlayTileEffectBuilder].
  final TileMorphEffect? overlayTileEffect;

  /// Resolves the [TileMorphEffect] for each morph frame — evaluated in
  /// the build that paints the overlay, so a caller can toggle morphing
  /// off (return `null` → plain cover-fit draw) or swap implementations
  /// mid-session without remounting the grid. Mutually exclusive with
  /// [overlayTileEffect].
  final TileMorphEffectBuilder? overlayTileEffectBuilder;

  /// Called when the set of item indices the morph frame paints changes —
  /// the visible lattice plus margin. Feed it to an image cache's decode
  /// priority: what the user is looking at should decode (and evict)
  /// first, on fast scrolls and random-date jumps alike.
  final void Function(Set<int> indices)? onVisibleItemsChanged;

  /// Section labels riding on the grid (month pills in the photo library).
  /// Returns the label when [index] starts a new section, null otherwise —
  /// it doubles as the "is section start" predicate the morph uses.
  final String? Function(int index)? sectionLabelFor;

  /// Invalidation token for the memoized section-start scan — pass the
  /// items list so a replaced list rescans even at the same [itemCount].
  final Object? sectionLabelVersion;

  /// Custom pill rendering for [sectionLabelFor] labels; defaults to a dark
  /// translucent capsule.
  final Widget Function(BuildContext context, String label)? sectionLabelBuilder;

  /// Section labels are only drawn on stops with at least this many
  /// columns — sparse stops leave pills out, matching the Photos app.
  final int minLabelColumns;

  /// Whether a diff may correct the scroll offset to keep the leading
  /// visible row fixed. Set false for a frame where the parent positions
  /// the viewport itself (a scrubber seek landing) — holding the parked
  /// anchor there would fight the landing offset in the same layout pass.
  final bool holdScrollAnchor;

  /// Constant on-screen gap between cells, at rest and mid-morph.
  final double spacing;

  /// Cell height/width for a given column count — defaults to 4/3 portrait
  /// cells at one column (full-bleed stop) and squares otherwise.
  final double Function(int columns)? tileAspect;

  /// Paint behind morph tiles — the opaque backdrop that keeps background
  /// from showing through during crossfades. Defaults to the theme surface.
  final Color? background;

  /// Landing layout semantics. False (default): every density stays
  /// index-absolute — positions never depend on which photo was pinched
  /// and a round-trip restores the exact arrangement. True (iOS Photos):
  /// the pinch commits a column phase that keeps the pinched photo's
  /// screen column through the re-chunk — a leading-edge photo lands at
  /// the leading column, a trailing-edge at the trailing, interior
  /// focals centre (clamped at the list edges). Layouts become
  /// focal-dependent in both directions and the phase persists until the
  /// next pinch re-phases from its own focal.
  final bool centerFocalOnCommit;

  /// Master switch for the pinch recognizer (a settings toggle in apps).
  final bool enablePinch;

  /// External scroll controller; the widget owns one when null.
  final ScrollController? scrollController;

  /// Bottom-anchored layout (iOS Photos order): item 0 renders at the
  /// bottom, the scroll offset grows upward, and [onNearEnd] fires toward
  /// the OLDER end. Leading slivers land at the bottom, [footer] at the
  /// top. All pinch/sticky geometry mirrors automatically.
  final bool reverse;

  /// Reverses each row's item run inside its slot span so indices descend
  /// left-to-right — the reading order a bottom-anchored (reversed-axis)
  /// gallery uses. The flip lives in the slot↔item mapping
  /// ([MorphGridStop.mirrorRows]): row bases shift with the committed
  /// phase, where a chunked permutation of the item list would split
  /// reversed runs mid-row once the phase is nonzero.
  final bool mirrorRows;

  /// Extra inset below the safe-area top where sticky section pills pin —
  /// for grids scrolled under a floating overlay bar.
  final double topClearance;

  /// Leading-edge inset the morph's coverage floor eases to while the
  /// pinch travels — replaces the parked leading-sliver clip so tiles
  /// slide under chrome the resting grid reserves (e.g. a floating tab
  /// bar on a reversed axis). Null keeps the parked clip: the leading
  /// sliver's margin stays bare through the gesture.
  final double? morphCoverageLeading;

  /// Overrides the scroll physics — e.g. a one-edge clamp once a grid's
  /// data source is exhausted so the elastic pull stops reading as "more
  /// to load". Defaults to [AlwaysScrollableScrollPhysics].
  final ScrollPhysics? physics;

  /// How long the morph overlay takes to fade out after a commit lands.
  final Duration overlayFadeDuration;

  /// Optional debug trace sink — called with internal anchor/commit
  /// diagnostics. `null` (default) disables tracing; wire it to your app's
  /// logger when debugging scroll anchoring.
  final ValueChanged<String>? debugLog;

  /// Debug-only morph overlay tint — while a zoom is in flight, rings the
  /// focal cell hottest, successive rings cooler, and veils slots that land
  /// off the destination viewport (see [PinchMorph.debugPaint]).
  final bool debugMorphPaint;

  /// Tuning knobs for reflow, settle, flick and edge-squeeze feel — see
  /// [PinchMorphStyle]. Defaults match iOS Photos reference footage.
  final PinchMorphStyle style;

  @override
  State<CupertinoGrid> createState() => _CupertinoGridState();
}

final class _CupertinoGridState extends State<CupertinoGrid> with TickerProviderStateMixin {
  late final ScrollController _ownedScrollController;
  late final AnimationController _settle;

  /// Hands the overlay off to the real grid after commit: a short hold (so
  /// its tiles can pick up their thumbnails) then a fade.
  late final AnimationController _overlayFade;
  late final CurvedAnimation _overlayFadeCurve;
  late final Animation<double> _overlayOpacity;

  late final PinchMorph _morph = PinchMorph(style: widget.style)..debugPaint = widget.debugMorphPaint;
  final GlobalKey _gridSliverKey = GlobalKey();
  final GlobalKey _headerSliverKey = GlobalKey();
  final GlobalKey _footerSliverKey = GlobalKey();

  ScrollController get _scrollController => widget.scrollController ?? _ownedScrollController;

  bool _morphActive = false;

  /// Whether the current two-finger gesture owns the morph.
  bool _pinching = false;

  /// `MediaQuery.disableAnimations` sampled at pinch start: the gesture
  /// still changes density, but the continuous morph, edge squeeze and
  /// settle spring are skipped — the release commits instantly. Resolved
  /// once per gesture so a mid-pinch settings flip can't split the
  /// choreography.
  bool _reduceMotion = false;

  /// Epoch invalidating scheduled morph callbacks — a pinch that lands
  /// mid-settle or mid-fade finalizes the pending commit instead of
  /// waiting it out, and any callback already queued for the interrupted
  /// morph (the settle's completion future, the commit's post-frame jump,
  /// the fade's tail) must no-op rather than clobber the new morph.
  int _morphEpoch = 0;
  double _pinchBaseLogTile = 0;

  /// Smoothed morph-level velocity in stops/sec (+ = towards denser) —
  /// feeds the release commit, see [_flickVelocity].
  double _levelVelocity = 0;
  double _lastUpdateLevel = 0;
  int _lastUpdateStamp = 0;
  int _lastUpdateWall = 0;

  /// Raw overscale sampled on the last update, before the refractory and
  /// reduce-motion masks hold the displayed value at 1 — the release reads
  /// it for the "keep zooming" commit so gesture intent isn't lost.
  double _rawOverscale = 1;
  double _settleFromLevel = 0;
  double _settleFromLogOverscale = 0;
  int _settleTarget = 0;

  /// Pin value the settle glide starts from — normally 1, but the
  /// stall-guard relaunch captures the frozen mid-glide value so the
  /// replayed travel doesn't snap pin back to its release state.
  double _settleFromPin = 1;

  /// Wall-clock stamp of the last settle tick — the spring is clock-driven,
  /// so a UI-thread stall surfaces as one giant value step; the tick
  /// handler measures gaps against this to restart instead of snapping.
  DateTime? _settleTickWall;

  /// True under a test binding — pumps advance frame time by arbitrary
  /// amounts in a single wall step, so a wall-gap guard can't distinguish
  /// a real dropped-frame stall from a coarse pump. Latched at settle
  /// launch.
  bool _settleFakeTime = false;

  /// Progress the last settle tick applied — a stall surfaces as one tick
  /// carrying a huge jump; a legitimately-ending spring arrives in small
  /// final steps. Reset at launch and on each relaunch.
  double _lastSettleProgress = 0;

  /// Relaunches this settle has taken — sustained jank would otherwise
  /// re-anchor the spring forever; past the cap the stall degrades to the
  /// old one-frame snap rather than never landing.
  int _settleRelaunches = 0;

  /// Densest-stop bounce — the morph floor can't shrink tiles further, so a
  /// pinch pushing past it squeezes the whole scroll view around the focal
  /// point (Photos' `zoomBounceScale`), and release springs it back. The
  /// largest-tile end needs no transform: the morph overscale already
  /// stretches tiles.
  late final AnimationController _edgeSqueeze;

  /// Real-space focal point the squeeze scales around.
  Offset _edgeFocal = Offset.zero;

  /// `zoomBounceRefractoryPeriod`: after a bounce rebounds, the same edge
  /// stays firm for a beat so rapid re-pinches don't loop the spring.
  /// [_refractoryEdge] is −1 for the largest-tile end, +1 for the densest.
  DateTime _refractoryUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _refractoryEdge = 0;

  double _lastValidScrollOffset = 0.0;

  /// Scroll-content y where the grid sliver starts (header above it), read
  /// from the sliver's own layout.
  double _gridOrigin = 0.0;

  /// Scroll-content y of the header's top edge.
  double _headerOrigin = 0.0;
  double _viewportWidth = 390;
  double _viewportHeight = 800;

  /// Internal column count for uncontrolled mode — [CupertinoGrid.columns]
  /// wins when the parent controls density.
  late int _internalColumns;
  int get _effectiveColumns => widget.columns ?? _internalColumns;

  /// Leading empty slots in the grid — the phase the last pinch commit
  /// landed on so the zoomed photo keeps its screen column through the
  /// re-chunk (edges hold their edge, interior focals centre, clamped to
  /// the list edges). 0 = index-absolute. The grid's child space is slots:
  /// item i renders at slot i + _phase.
  int _phase = 0;

  /// A landing phase held for columns the grid hasn't committed yet —
  /// (columns, phase). A controlled parent adopts the settle density a
  /// rebuild after [_applyPhase] runs; the stamp would exceed the old
  /// grid's column count in the interim, so it waits here for
  /// [didUpdateWidget] to land the matching columns.
  (int, int)? _pendingPhase;

  int _lastAnchorIndex = -1;
  int _lastDirection = 1;

  /// Indices where a new section begins, memoized against the item count
  /// and [CupertinoGrid.sectionLabelVersion] so morph frames don't rescan
  /// the whole list.
  Set<int> _sectionStarts = const {};
  int _sectionSourceCount = -1;
  Object? _sectionSourceVersion;

  /// Animated-grid state for insert/remove — item mutations go through
  /// [SliverAnimatedGridState.insertItem]/[removeItem] so the framework's
  /// own bookkeeping reindexes children atomically. A raw `childCount`
  /// jump under a keyed child list is what corrupts the render order.
  final GlobalKey<SliverAnimatedGridState> _gridKey = GlobalKey<SliverAnimatedGridState>();

  /// Item keys the grid last displayed — the diff baseline.
  List<Object?> _syncedKeys = const [];
  int _syncedCount = -1;
  Object? _syncedVersion;

  /// O(1) key→index resolution for `findChildIndexCallback`, rebuilt with
  /// each sync so keyed children relocate instead of churning.
  Map<Object?, int> _indexByKey = const {};

  /// Anchor identity of the pinched item, captured at pinch start. The
  /// commit can reshape the item list (stack fold/unfold, merge) — the
  /// focal index is re-resolved through this key before the final jump.
  Object? _focalAnchorKey;

  /// Item identity of the pinched cell, captured at pinch start. The
  /// commit resolves it first — the group anchor is only the fallback for
  /// when a reshape removed the item itself (a member folding away still
  /// keeps the pinch on its stack's surviving header).
  Object? _focalItemKey;

  /// Item indices the morph overlay keeps child widgets mounted for —
  /// seeded from the first frame of a pinch, grown through
  /// [_RenderMorphOverlay]'s missing-slot callback. Tiles covered by
  /// [CupertinoGrid.overlayImageFor] never need a slot.
  final Set<int> _overlayTiles = {};

  /// Last frame's tile size per index — overlay tile widgets request
  /// thumbnails at their own layer's size, not the largest stop's, so a
  /// zoom-out frame doesn't decode hundreds of oversized thumbnails.
  final Map<int, int> _overlayTileSizes = {};

  /// `(layer, sectionStartIndex)` pill slots mounted for the overlay.
  final Set<(int, int)> _overlayPills = {};

  /// Logical width overlay tile children request thumbnails at — the
  /// largest stop's width, so one decode covers the whole gesture.
  int _overlayTileSize = 0;

  @override
  void initState() {
    super.initState();
    _internalColumns = _initialColumns();
    _ownedScrollController = ScrollController()..addListener(_updateScrollOffset);
    widget.scrollController?.addListener(_updateScrollOffset);
    _settle = AnimationController.unbounded(vsync: this)..addListener(_onSettleTick);
    _edgeSqueeze = AnimationController.unbounded(vsync: this, value: 1);
    _overlayFade = AnimationController(vsync: this, duration: widget.overlayFadeDuration);
    _overlayFadeCurve = CurvedAnimation(
      parent: _overlayFade,
      curve: const Interval(0.4, 1, curve: Curves.easeOut),
    );
    _overlayOpacity = Tween<double>(begin: 1, end: 0).animate(_overlayFadeCurve);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureGridOrigin();
      _fireAnchor(direction: 1);
    });
  }

  @override
  void didUpdateWidget(covariant CupertinoGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_updateScrollOffset);
      widget.scrollController?.addListener(_updateScrollOffset);
    }
    // Every knob is read lazily (engine set/frame, gesture commit,
    // overlay paint), so the swap is safe even mid-settle — the next
    // frame computes on the new constants; in-flight SpringSimulations
    // finish on the spring they started with.
    if (oldWidget.style != widget.style) _morph.style = widget.style;
    if (oldWidget.debugMorphPaint != widget.debugMorphPaint) {
      _morph.debugPaint = widget.debugMorphPaint;
    }
    if (widget.columns == null && !_columnsStillValid()) {
      _internalColumns = _initialColumns();
      _applyPhase(0);
    }
    // A column change driven from outside the morph drops the phase —
    // it only means "centre the zoomed photo" within a pinch commit. A
    // change matching a held landing stamp applies that stamp instead:
    // the morph's own commit arriving through the controlled parent.
    if (oldWidget.columns != widget.columns) {
      final pending = _pendingPhase;
      if (pending != null && pending.$1 == widget.columns) {
        _applyPhase(pending.$2);
      } else if (!_morphActive) {
        _applyPhase(0);
      }
    }
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fireAnchor(direction: _lastDirection);
      });
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _edgeSqueeze.dispose();
    _overlayFadeCurve.dispose();
    _overlayFade.dispose();
    _morph.dispose();
    widget.scrollController?.removeListener(_updateScrollOffset);
    _ownedScrollController.removeListener(_updateScrollOffset);
    _ownedScrollController.dispose();
    super.dispose();
  }

  List<int> _effectiveCounts() => widget.columnCountsForWidth?.call(_viewportWidth) ?? widget.columnCounts;

  int _initialColumns() {
    final counts = [..._effectiveCounts()]..sort();
    if (counts.isEmpty) return 3;
    final initial = widget.initialColumns;
    if (initial != null && counts.contains(initial)) return initial;
    return counts[counts.length ~/ 2];
  }

  bool _columnsStillValid() => _effectiveCounts().contains(_internalColumns);

  double _aspectFor(int columns) => widget.tileAspect?.call(columns) ?? (columns == 1 ? 4 / 3 : 1.0);

  double get _currentScrollOffset {
    if (_scrollController.hasClients && _scrollController.position.hasContentDimensions) {
      _lastValidScrollOffset = _scrollController.offset;
    }
    return _lastValidScrollOffset;
  }

  // The clamp keeps the constructor's phase < columns invariant through
  // the one window _phase can exceed it: an outside column change landing
  // mid-morph while the stamped landing phase still waits to commit.
  MorphGridStop get _currentStop => MorphGridStop(
    _effectiveColumns,
    _viewportWidth,
    spacing: widget.spacing,
    aspect: _aspectFor(_effectiveColumns),
    showsLabels: _effectiveColumns >= widget.minLabelColumns && widget.sectionLabelFor != null,
    phase: _phase.clamp(0, _effectiveColumns - 1),
    mirrorRows: widget.mirrorRows,
  );

  // ---- Layout helpers -------------------------------------------------------

  Object? _keyOf(int index) => widget.itemKey?.call(index) ?? index;

  /// Key used to re-resolve an item's index after the list reshapes — the
  /// anchor key when the caller supplies one, the item key otherwise.
  Object? _anchorKeyOf(int index) => widget.itemAnchorKey?.call(index) ?? _keyOf(index);

  Set<int> _sectionStartSet() {
    final callback = widget.sectionLabelFor;
    if (callback == null) return const {};
    if (_sectionSourceCount != widget.itemCount || !identical(_sectionSourceVersion, widget.sectionLabelVersion)) {
      _sectionSourceCount = widget.itemCount;
      _sectionSourceVersion = widget.sectionLabelVersion;
      _sectionStarts = {
        for (var i = 0; i < widget.itemCount; i++)
          if (callback(i) != null) i,
      };
    }
    return _sectionStarts;
  }

  // ---- Pinch zoom -----------------------------------------------------------

  /// Every distinct column count the ladder offers at this width, fewest
  /// columns first. The current count claims its slot so a no-op pinch
  /// commits back to it.
  List<MorphGridStop> _buildLadder() {
    final current = _currentStop;
    final byColumns = <int, MorphGridStop>{current.columns: current};
    for (final columns in _effectiveCounts()) {
      byColumns.putIfAbsent(
        columns,
        () => MorphGridStop(
          columns,
          _viewportWidth,
          spacing: widget.spacing,
          aspect: _aspectFor(columns),
          showsLabels: columns >= widget.minLabelColumns && widget.sectionLabelFor != null,
          mirrorRows: widget.mirrorRows,
        ),
      );
    }
    return byColumns.values.toList()..sort((a, b) => a.columns.compareTo(b.columns));
  }

  /// Runs [fn] inside [setState] — the gesture/anchor part files call this
  /// since [State.setState] is `@protected` and can only be invoked from a
  /// real instance member of the class.
  void _rebuild(VoidCallback fn) => setState(fn);

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final itemCount = widget.itemCount;
    _syncGrid();
    final surface = widget.background ?? Theme.of(context).colorScheme.surface;
    final safeTop = MediaQuery.paddingOf(context).top;

    // The header above the grid can change height; keep the origin the
    // section pills and pinch geometry use in sync with it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_morphActive && _measureGridOrigin()) setState(() {});
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth);
        final height = math.max(1.0, constraints.maxHeight);
        final resized = width != _viewportWidth || height != _viewportHeight;
        _viewportWidth = width;
        _viewportHeight = height;
        if (resized) _reframeMorph();
        final stop = _currentStop;
        final morphActive = _morphActive;

        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: widget.enablePinch
              ? <Type, GestureRecognizerFactory>{
                  _TwoFingerScaleGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<_TwoFingerScaleGestureRecognizer>(
                        () => _TwoFingerScaleGestureRecognizer(),
                        (recognizer) {
                          recognizer
                            ..onStart = _onScaleStart
                            ..onUpdate = _onScaleUpdate
                            ..onEnd = _onScaleEnd;
                        },
                      ),
                }
              : const {},
          child: Stack(
            children: [
              // Non-positioned sentinel: keeps the stack at full size even
              // when a builder returns a non-positioned child (e.g.
              // SizedBox.shrink), which would otherwise collapse the whole
              // stack to that child's size.
              const SizedBox.expand(),

              // Real grid — always mounted, never mutated during a gesture.
              // The densest-stop bounce rides on a composited transform:
              // squeeze around the pinch focal point, spring back on
              // release. No relayout, no thumbnail fetches.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _edgeSqueeze,
                  builder: (context, child) => Transform.scale(
                    scale: _edgeSqueeze.value,
                    alignment: Alignment(
                      (_edgeFocal.dx / _viewportWidth * 2 - 1).clamp(-1.0, 1.0),
                      (_edgeFocal.dy / _viewportHeight * 2 - 1).clamp(-1.0, 1.0),
                    ),
                    child: child,
                  ),
                  child: _buildScrollView(stop, morphActive),
                ),
              ),

              if (!morphActive && stop.showsLabels && itemCount > 0)
                Positioned.fill(child: _buildSectionLabels(stop, safeTop)),

              // Free-positioned layer — the builder returns a Stack child
              // (Positioned or otherwise), not a fill-constrained widget.
              if (widget.overlayBuilder != null)
                widget.overlayBuilder!(
                      context,
                      stop: stop,
                      gridOrigin: _gridOrigin,
                      scrollController: _scrollController,
                      morphActive: morphActive,
                    ) ??
                    const SizedBox.shrink(),

              // Pinch overlay — the render object listens to the morph and
              // relayouts per frame, so nothing above rebuilds.
              if (morphActive && itemCount > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: FadeTransition(
                      opacity: _overlayOpacity,
                      // Overlay tiles must never join a hero flight — the
                      // resting grid's tiles with the same tags are mounted
                      // beneath them.
                      child: HeroMode(
                        enabled: false,
                        child: _buildMorphOverlay(surface, widget.headerBuilder?.call(context)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScrollView(MorphGridStop stop, bool morphActive) {
    Widget scrollView = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        _handleScrollNotification(notification);
        return false;
      },
      child: CustomScrollView(
        controller: _scrollController,
        reverse: widget.reverse,
        physics: morphActive
            ? const NeverScrollableScrollPhysics()
            : (widget.physics ?? const AlwaysScrollableScrollPhysics()),
        scrollCacheExtent: const ScrollCacheExtent.viewport(1.0),
        slivers: [
          ...?widget.leadingSlivers?.call(context),
          if (widget.headerBuilder != null)
            SliverToBoxAdapter(
              key: _headerSliverKey,
              child: Builder(builder: widget.headerBuilder!),
            ),
          SliverPadding(
            key: _gridSliverKey,
            padding: EdgeInsets.all(widget.spacing),
            sliver: SliverAnimatedGrid(
              key: _gridKey,
              initialItemCount: widget.itemCount,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: stop.columns,
                mainAxisSpacing: widget.spacing,
                crossAxisSpacing: widget.spacing,
                childAspectRatio: stop.childAspectRatio,
              ),
              // The grid's child space is slots: item i sits at
              // stop.slotOf(i) (i + _phase, mirrored within its row under
              // mirrorRows); slots the mapping returns no item for are the
              // layout's holes and render empty.
              findChildIndexCallback: (Key key) {
                final item = key is ValueKey<Object?> ? _indexByKey[key.value] : null;
                return item == null ? null : stop.slotOf(item, widget.itemCount);
              },
              itemBuilder: (context, index, animation) {
                final item = stop.itemAt(index, widget.itemCount);
                if (item < 0 || item >= widget.itemCount) {
                  return const SizedBox.shrink();
                }
                return FadeTransition(
                  key: ValueKey<Object?>(_keyOf(item)),
                  opacity: animation,
                  child: ScaleTransition(
                    scale: animation,
                    child: widget.itemBuilder(context, item, stop.tileWidth.ceil()),
                  ),
                );
              },
            ),
          ),
          if (widget.footer != null)
            SliverToBoxAdapter(
              child: KeyedSubtree(key: _footerSliverKey, child: widget.footer!),
            ),
          if (widget.itemCount == 0 && widget.emptyBuilder != null)
            SliverFillRemaining(hasScrollBody: false, child: Builder(builder: widget.emptyBuilder!)),
        ],
      ),
    );
    final decorator = widget.scrollDecorator;
    if (decorator != null) return decorator(context, scrollView);
    final onRefresh = widget.onRefresh;
    if (onRefresh != null) {
      scrollView = RefreshIndicator(onRefresh: onRefresh, child: scrollView);
    }
    return scrollView;
  }

  /// The morph frame as a render object: [_RenderMorphOverlay] owns layout
  /// and paint, so a morph frame never rebuilds the widget tree — children
  /// are only mounted for slots that actually appear.
  Widget _buildMorphOverlay(Color background, Widget? header) {
    final morph = _morph;
    if (morph.stops.isEmpty || widget.itemCount == 0) {
      return const SizedBox.shrink();
    }
    final tileBuilder = widget.overlayItemBuilder ?? (context, index, size) => widget.itemBuilder(context, index, size);

    Widget pill(int index) {
      final label = widget.sectionLabelFor?.call(index);
      return label == null ? const SizedBox.shrink() : _sectionPill(label);
    }

    // Excluded from semantics — the tiles are transient visual duplicates of
    // the resting grid (which keeps a11y coverage under the overlay). The
    // hiding matters structurally too: slots mount mid-gesture via
    // onSlotsNeeded while pointer moves keep marking the overlay needsLayout,
    // so a flush can drop the overlay before it adopts its new children into
    // the semantics tree — framework-visible as a persistent dirty parentData.
    return ExcludeSemantics(
      child: _MorphOverlay(
        morph: morph,
        sectionStarts: _sectionStartSet(),
        background: background,
        missingTile: Theme.of(context).colorScheme.surfaceContainerHigh,
        spacing: widget.spacing,
        imageFor: widget.overlayImageFor,
        imagesInvalidated: widget.overlayImagesListenable,
        tileEffect: widget.overlayTileEffectBuilder?.call() ?? widget.overlayTileEffect,
        onSlotsNeeded: _onOverlaySlotsNeeded,
        onVisibleItemsChanged: widget.onVisibleItemsChanged,
        style: widget.style,
        children: [
          if (header != null) _OverlaySlot.header(key: const ValueKey('header'), child: header),
          for (final index in _overlayTiles)
            _OverlaySlot.tile(
              index,
              // Keyed by item identity, not the index slot: a mid-gesture
              // list reshape remaps indices, and an index-keyed tile would
              // reuse its element for a different item — the tile's image
              // widget then holds the previous photo (gaplessPlayback)
              // until the new provider resolves.
              key: ValueKey('tile|${index < widget.itemCount ? _keyOf(index) : index}'),
              child: tileBuilder(context, index, _overlayTileSizes[index] ?? _overlayTileSize),
            ),
          for (final (layer, index) in _overlayPills)
            _OverlaySlot.pill(layer, index, key: ValueKey('pill|$layer|$index'), child: pill(index)),
        ],
      ),
    );
  }

  Widget _sectionPill(String label) =>
      widget.sectionLabelBuilder?.call(context, label) ?? _SectionPill(label: label, extent: widget.style.pillExtent);

  /// Section pills for dense stops at rest. The current label sticks below
  /// the header (or the status bar once the header scrolls away) and is
  /// pushed up by the next section's pill as it arrives.
  Widget _buildSectionLabels(MorphGridStop stop, double safeTop) {
    final sectionLabelFor = widget.sectionLabelFor;
    if (sectionLabelFor == null) return const SizedBox.shrink();
    final starts = _sectionStartSet().toList()..sort();

    Widget pill(int start, double top) => Positioned(
      key: ValueKey<int>(starts[start]),
      left: widget.spacing + _pillInset,
      top: top,
      // Height pinned to pillExtent — the sticky/dedup math above assumes
      // pills occupy exactly that band, so a taller custom label would
      // overlap its neighbour instead of pushing it.
      child: SizedBox(height: widget.style.pillExtent, child: _sectionPill(sectionLabelFor(starts[start])!)),
    );

    return IgnorePointer(
      child: ListenableBuilder(
        listenable: _scrollController,
        builder: (context, _) {
          final scroll = _currentScrollOffset;
          final origin = _gridOrigin;

          // Reversed layout: the grid's top edge is its scroll-space END
          // (screenY = height + scroll − scrollY), pills still stick to the
          // top edge and the incoming section pushes the stuck one down.
          if (widget.reverse) {
            final gridTopOnScreen = _viewportHeight + scroll - stop.rowTop(stop.rowCount(widget.itemCount), origin);
            final stickyTop = math.max(safeTop + widget.topClearance, gridTopOnScreen) + _pillInset;
            double naturalTop(int start) =>
                _viewportHeight + scroll - stop.rowTop(stop.rowOf(starts[start]) + 1, origin) + widget.style.pillGap;
            final stuckRow = stop.rowAtY(scroll + _viewportHeight - stickyTop, origin);
            final next = stuckRow < 0 ? 0 : _lowerBound(starts, (stuckRow + 1) * stop.columns - stop.phase);

            final labels = <Widget>[];
            if (next > 0) {
              var top = stickyTop;
              if (next < starts.length) {
                top = math.max(top, naturalTop(next) + widget.style.pillExtent + widget.style.pillGap);
              }
              labels.add(pill(next - 1, top));
            }
            var lastTop = double.infinity;
            for (var i = next; i < starts.length; i++) {
              final top = naturalTop(i);
              if (top < -widget.style.pillExtent) break;
              if (lastTop - top < widget.style.pillExtent + widget.style.pillGap) {
                continue;
              }
              labels.add(pill(i, top));
              lastTop = top;
            }
            return Stack(children: labels);
          }

          final stickyTop = math.max(safeTop + widget.topClearance, origin - scroll) + _pillInset;
          double naturalTop(int start) =>
              stop.rowTop(stop.rowOf(starts[start]), origin) - scroll + widget.style.pillGap;

          // Starts at or above the sticky line are "passed"; the last of
          // them is the current section.
          final stuckRow = stop.rowAtY(scroll + stickyTop - widget.style.pillGap, origin);
          final next = stuckRow < 0 ? 0 : _lowerBound(starts, (stuckRow + 1) * stop.columns - stop.phase);

          final labels = <Widget>[];
          var lastTop = double.negativeInfinity;
          if (next > 0) {
            var top = stickyTop;
            if (next < starts.length) {
              top = math.min(top, naturalTop(next) - widget.style.pillExtent - widget.style.pillGap);
            }
            labels.add(pill(next - 1, top));
            lastTop = top;
          }
          for (var i = next; i < starts.length; i++) {
            final top = naturalTop(i);
            if (top > _viewportHeight) break;
            if (top - lastTop < widget.style.pillExtent + widget.style.pillGap) {
              continue;
            }
            labels.add(pill(i, top));
            lastTop = top;
          }
          return Stack(children: labels);
        },
      ),
    );
  }
}

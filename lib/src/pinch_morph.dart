import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size, lerpDouble;

import 'package:flutter/foundation.dart';

import 'morph_frame.dart';
import 'morph_grid_stop.dart';
import 'pinch_morph_style.dart';

part 'pinch_morph/focal_top.dart';
part 'pinch_morph/settle_glide.dart';
part 'pinch_morph/tile_emitter.dart';

/// Bisection steps for the coverage-crossing handoff search — the blended
/// extent mixes exp/log/smoothstep terms, so there is no closed form and
/// a fixed-depth bisection is the robust answer. 16 steps resolves the
/// crossing to ~1e-5 of an interval, far under a pixel.
const int _coverageBisectionSteps = 16;

/// Live pinch state and the per-cell morph formula.
///
/// [level] is a continuous position on the density ladder (0 = fewest
/// columns); [overscale] is the rubber-band stretch past the largest-tile
/// stop — the densest stop is a hard floor. A frame is ONE slot lattice:
/// between the larger-tile stop and the denser stop at progress t, every
/// cell has the width w = wa^(1-t)·wb^t, an aspect morphing between the
/// two stops' aspects, and a constant on-screen gap; the lattice is
/// placed so the photo under the fingers stays under them. Row wrapping
/// is helical — slot offset (row dr, column dc) holds item
/// R·columns + j for any j — so a lattice shifted sideways never exposes
/// an empty column.
///
/// The reflow is a window, not the journey: outside [style.reflowWindow]
/// around t = 0.5 the nearer stop's layout simply scales (each slot keeps
/// its photo, so nothing fades); inside it the whole lattice slides from
/// the larger stop's placement to the denser stop's while each slot's
/// photo crossfades to the denser stop's — iOS's brief shuffle instead of
/// a morph-long dissolve.
///
/// The behavioural contract (landing map, span centring, gating, and
/// which tests guard each rule) lives in `packages/cupertino_grid/
/// AGENTS.md` — keep it and the tests in sync when a rule changes.
final class PinchMorph extends ChangeNotifier {
  /// Creates the engine; [style] retunes reflow/crossfade/coverage feel.
  PinchMorph({this.style = const PinchMorphStyle()});

  /// Tunable feel — see [PinchMorphStyle] for what each knob moves.
  ///
  /// Mutable so a hosting widget can hot-swap config: every knob is read
  /// lazily at the point of use, so replacing this mid-gesture or
  /// mid-settle applies cleanly to subsequent frames — morph state
  /// ([level], pin, stops) never holds values derived from the old style.
  PinchMorphStyle style;

  /// Density ladder — ordered fewest columns first.
  List<MorphGridStop> stops = const [];

  /// Each stop's scroll offset where the focal photo sits at its resting
  /// anchor — the settle target of [commit] / the release glide.
  List<double> restScrolls = const [];

  /// Ladder index the pinch started at — reflow windows and crossfades are
  /// measured against it.
  int startStop = 0;

  /// Ladder index the release is easing toward.
  int settleStop = 0;

  /// Item under the fingers — the lattice slot the morph keeps pinned.
  int focalIndex = 0;

  /// Live item count — lattices emit only slots holding a real item.
  int itemCount = 0;

  /// Bumped by the host every time the item list resyncs — inserts,
  /// removals, reorders — so consumers keyed by index (the overlay's
  /// sticky image cache) drop entries whose index silently remapped.
  int itemEpoch = 0;

  /// Pinch point relative to the focal cell, in cell units — the touch
  /// position inside the cell. Both axes ride it: vertically it pins the
  /// touch point to the finger, horizontally it places the pinch point
  /// inside each lattice's rest rect (see [anchor]). Unclamped, so a
  /// pinch that lands on a gap or the header still starts without a jump.
  Offset focalFraction = Offset.zero;

  /// Screen point the focal cell is pinned to — where the fingers came
  /// down (the live finger midpoint).
  Offset focalPoint = Offset.zero;

  /// Scroll-space y where the grid sliver starts.
  double origin = 0;

  /// Scroll-space y where the section header band starts.
  double headerOrigin = 0;

  /// Scroll offset at pinch start — the overlay's parked anchor.
  double startScroll = 0;

  /// Scroll offset below which content runs out at the leading edge
  /// (minScrollExtent) — the lower clamp of [restScrolls].
  double minScroll = 0;

  /// Scroll offset above which content runs out at the trailing edge
  /// (maxScrollExtent + a bounce margin).
  double trailing = 0;

  /// Leading-edge inset the coverage floor eases to as the level leaves
  /// the start stop — null keeps the parked clip (leading slivers stay
  /// uncovered, the rest layout's margin). When the leading slivers
  /// reserve floating chrome (a bar the grid clears only at rest), set
  /// this to the inset tiles should still cover mid-gesture so the band
  /// never shows a void while pinching.
  double? coverageLeading;

  /// Viewport extent the frame fills.
  Size viewport = Size.zero;

  /// Debug paint: when on, the overlay lays a translucent heatmap tint over
  /// each tile while a zoom is in flight — the focal cell hot, each
  /// successive ring of slots a cooler colour, and slots whose destination
  /// lands off the next zoom's rest viewport veiled dark. The coloured
  /// region is the window the photo swap actually reaches; the tint drops
  /// as soon as the level lands on a stop. A plain field — the flag is read
  /// per emitted frame, so toggling never notifies (a listener marking the
  /// grid dirty mid-build would throw).
  bool debugPaint = false;

  /// Per-frame internals for live morph debugging — read back over the VM
  /// service while a real pinch runs on-device. Off by default so frame()
  /// pays nothing in production; flip [debugTraceEnabled] to collect.
  static bool debugTraceEnabled = false;

  /// Collected frame lines — see [debugTraceEnabled].
  static final List<String> debugTrace = [];

  /// Reversed scroll axis (bottom-anchored grid, iOS-Photos order). All
  /// geometry below stays in scroll space; only screen↔scroll conversions
  /// flip: screenY = viewport.height + scroll − scrollY.
  bool reversed = false;

  /// Continuous position on the density ladder: `1.7` is 70% of the way
  /// from `stops[1]` to `stops[2]`. Negative values rubber-band past the
  /// largest-tile stop.
  double level = 0;

  /// Rubber-band stretch past the largest-tile stop (1 = none).
  double overscale = 1;

  /// 1 while the fingers are down; the release spring takes it to 0, gliding
  /// the lattice onto the settled stop's rest layout.
  double pin = 1;

  /// The focal cell's on-screen rect at pinch start — the clipping it may
  /// keep while the fingers are down (see `frame()`).
  Rect _pinchStartFocalRect = Rect.zero;

  /// Release-glide state: when coverage moved the parked lattice, the
  /// settle glides from the parked top to the rest position instead of
  /// re-deriving through the clamp — the blend's targets keep sweeping
  /// through the screen-height crossing as the level eases, which
  /// re-injects a down-then-up dip on release.
  final _SettleGlide _settleGlide = _SettleGlide();

  /// Starts a pinch: stamps the geometry every frame derives from.
  ///
  /// [focalFraction] is the pinch point inside the focal cell (cell units,
  /// may exceed `[0,1]`); [focalPoint] is the screen-space touch point.
  /// Vertically the cell's touch point tracks the finger; horizontally the
  /// lattice stays column-true (see [anchor]) — a fixed-column grid cannot
  /// hold both the focal cell under an arbitrary finger x and its landing
  /// columns at the same time. [restScrolls]-equivalent targets are
  /// derived here so the settle aim is fixed before the fingers move.
  void begin({
    required List<MorphGridStop> stops,
    required int startStop,
    required int focalIndex,
    required Offset focalFraction,
    required Offset focalPoint,
    required double startScroll,
    required double minScroll,
    required double trailing,
    required int itemCount,
    required double origin,
    required double headerOrigin,
    required Size viewport,
    double? coverageLeading,
    bool reversed = false,
    int phase = 0,
    bool centerFocal = false,
  }) {
    // Boundary validation — callers through [CupertinoGrid] satisfy these
    // invariants already; a degenerate input failing here beats emitting
    // NaN geometry at frame time. (Asserts only — release builds pay
    // nothing and the math tolerates the same edge cases it always has.)
    assert(stops.isNotEmpty, 'stops must not be empty');
    assert(
      startStop >= 0 && startStop < stops.length,
      'startStop $startStop is out of range for ${stops.length} stops',
    );
    assert(_strictlyIncreasingColumns(stops), 'stops must be ordered fewest columns first with distinct counts');
    assert(itemCount > 0, 'itemCount must be positive, got $itemCount');
    assert(focalIndex >= 0 && focalIndex < itemCount, 'focalIndex $focalIndex is out of range for $itemCount items');
    assert(focalFraction.dx.isFinite && focalFraction.dy.isFinite, 'focalFraction must be finite, got $focalFraction');
    assert(focalPoint.dx.isFinite && focalPoint.dy.isFinite, 'focalPoint must be finite, got $focalPoint');
    assert(
      startScroll.isFinite && minScroll.isFinite && trailing.isFinite && origin.isFinite && headerOrigin.isFinite,
      'scroll metrics must be finite, got startScroll=$startScroll, minScroll=$minScroll, '
      'trailing=$trailing, origin=$origin, headerOrigin=$headerOrigin',
    );
    assert(
      viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0,
      'viewport must be positive and finite, got $viewport',
    );
    assert(phase >= 0 && phase < stops[startStop].columns, 'phase must be in 0..startStop columns-1, got $phase');
    // iOS Photos re-chunks the ribbon around the pinch in BOTH directions:
    // with [centerFocal] every landing stop stamps the column phase that
    // keeps the pinched photo's screen position — it lands on the column
    // nearest to where it started, so the middle stays middle, an edge
    // photo keeps its edge, and a column beside middle lands on the
    // nearer side rather than jumping to the centre (clamped by the list
    // edges). Index-absolute ([centerFocal] off) never depends on which
    // photo was pinched, so positions always restore on a round-trip.
    final start = stops[startStop].withPhase(phase);
    this.stops = [
      for (var k = 0; k < stops.length; k++)
        stops[k].withPhase(
          k == startStop ? phase : (centerFocal ? _landingPhase(start, stops[k], focalIndex, itemCount) : 0),
        ),
    ];
    _centerFocal = centerFocal;
    _focalStartColumns = start.columns;
    _focalStartColumn = centerFocal ? start.columnOf(focalIndex, itemCount) : 0;
    this.startStop = startStop;
    settleStop = startStop;
    this.focalIndex = focalIndex;
    this.reversed = reversed;
    // Under a reversed axis the whole morph runs in MIRRORED screen space
    // (y' = viewport.height − y): pinch point and in-cell fraction flip
    // here, every formula below is the normal-direction one, and tile
    // rects flip back when frame() emits them.
    this.focalFraction = Offset(focalFraction.dx, reversed ? 1 - focalFraction.dy : focalFraction.dy);
    this.focalPoint = reversed ? Offset(focalPoint.dx, viewport.height - focalPoint.dy) : focalPoint;
    this.startScroll = startScroll;
    this.minScroll = minScroll;
    this.trailing = trailing;
    this.coverageLeading = coverageLeading;
    this.itemCount = itemCount;
    this.origin = origin;
    this.headerOrigin = headerOrigin;
    this.viewport = viewport;
    level = startStop.toDouble();
    overscale = 1;
    pin = 1;
    _gestureLevel = level;
    _settleGlide.reset();
    _pinchStartFocalRect = this.stops[startStop].tileRect(focalIndex, origin, itemCount).translate(0, -startScroll);
    restScrolls = _restScrollsFor();
  }

  /// Scroll offset each stop would rest at: the live offset for the start
  /// stop (frame one is the real grid, even mid-bounce), and for every
  /// other stop the scroll that puts the focal cell's centre where the
  /// pinch stamped it — with focalPoint/focalFraction mirrored on reversed
  /// axes this is just the normal-direction formula. The mirrored FIELDS
  /// must be used here: bare begin() parameters would still be unmirrored,
  /// which on a reversed axis targets a scroll offset mirrored about the
  /// viewport and snaps by ~2×(focal − screen center) on commit.
  List<double> _restScrollsFor() => [
    for (var k = 0; k < stops.length; k++) k == startStop ? startScroll : restScrollFor(k),
  ];

  /// Scroll offset that rests [stopIndex]'s grid with the pinched item's
  /// pinch point where the gesture stamped it — the single derivation
  /// every [restScrolls] write shares (begin, commit, mid-settle
  /// retarget). [itemIndex] and [itemCount] default to the stamped pair;
  /// pass the CURRENT values when the cell list reshaped mid-morph (stack
  /// fold/unfold, a merge inserting cells) so the write re-aims at the
  /// item's new slot.
  ///
  /// The [minScroll] clamp is load-bearing: an edge focal's anchor
  /// formula can sit out of range, and an unclamped write shifts the rest
  /// target after the overlay already emitted the clamped frame — the
  /// lattice snaps to the out-of-range scroll, then back when the real
  /// grid parks inside extents (the release wobble).
  double restScrollFor(int stopIndex, {int? itemIndex, int? itemCount}) {
    final index = itemIndex ?? focalIndex;
    final count = itemCount ?? this.itemCount;
    final stop = stops[stopIndex];
    final maxScroll = math.max(minScroll, stop.rowTop(stop.rowCount(count), origin) + trailing - viewport.height);
    return (stop.tileTop(index, origin) + focalFraction.dy * stop.tileHeight - focalPoint.dy)
        .clamp(minScroll, maxScroll)
        .toDouble();
  }

  /// Re-stamps viewport-derived geometry mid-morph — a resize or rotation
  /// while the fingers are down or the settle is in flight — keeping the
  /// gesture state ([level], [pin], focal identity) intact. [stops] is
  /// the freshly measured ladder (tile widths move with viewport width);
  /// per-stop phases preserve by column count and ladder indices remap by
  /// column count, so a ladder that itself changed still lands coherently.
  void reframe({
    required Size viewport,
    required List<MorphGridStop> stops,
    required double minScroll,
    required double trailing,
    double? coverageLeading,
  }) {
    assert(stops.isNotEmpty, 'stops must not be empty');
    assert(_strictlyIncreasingColumns(stops), 'stops must be ordered fewest columns first with distinct counts');
    assert(
      viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0,
      'viewport must be positive and finite, got $viewport',
    );
    assert(minScroll.isFinite && trailing.isFinite, 'scroll bounds must be finite, got $minScroll/$trailing');
    if (this.stops.isEmpty) {
      // No pinch begun — keep the extent current so a later begin is clean.
      this.viewport = viewport;
      return;
    }
    final oldStops = this.stops;
    final (lower, progress) = interval;
    final oldHeight = this.viewport.height;
    this.viewport = viewport;
    this.minScroll = minScroll;
    this.trailing = trailing;
    this.coverageLeading = coverageLeading ?? this.coverageLeading;
    if (reversed) {
      // The stored focal point is already mirrored about the old height
      // (y' = oldH − y) — re-mirror it: y'' = y' + newH − oldH.
      focalPoint = Offset(focalPoint.dx, focalPoint.dy + viewport.height - oldHeight);
    }
    final phases = {for (final s in oldStops) s.columns: s.phase};
    int indexOfColumns(int columns) {
      var best = 0;
      for (var k = 0; k < stops.length; k++) {
        if (stops[k].columns == columns) return k;
        if ((stops[k].columns - columns).abs() < (stops[best].columns - columns).abs()) {
          best = k;
        }
      }
      return best;
    }

    this.stops = [for (final s in stops) s.withPhase(phases[s.columns] ?? 0)];
    startStop = indexOfColumns(oldStops[startStop].columns);
    settleStop = indexOfColumns(oldStops[settleStop].columns);
    level = (indexOfColumns(oldStops[lower].columns) + progress).clamp(0, this.stops.length - 1).toDouble();
    _gestureLevel = level;
    _pinchStartFocalRect = this.stops[startStop].tileRect(focalIndex, origin, itemCount).translate(0, -startScroll);
    restScrolls = _restScrollsFor();
    _settleGlide.reset();
    notifyListeners();
  }

  /// The column phase a commit lands on: leading empty slots that put the
  /// focal photo on the landing column nearest its start column — a middle
  /// photo stays middle, a leading-edge photo keeps the leading column, a
  /// trailing-edge photo the trailing — clamped toward the item's absolute
  /// column only when it is too near the list's start or end to fill the
  /// flanking columns.
  static int _landingPhase(MorphGridStop start, MorphGridStop stop, int focalIndex, int itemCount) {
    // columnOf reports the DISPLAYED column (under mirrorRows the row's
    // flipped slot is where the photo shows), so the same edge/interior
    // rule reads the visual layout on either axis.
    return _phaseForTarget(
      stop,
      _landingTarget(start.columnOf(focalIndex, itemCount), start.columns, stop.columns),
      focalIndex,
      itemCount,
    );
  }

  /// The displayed column a landing phase preserves: the landing column
  /// whose centre is nearest to where the photo's column centre started —
  /// the middle column stays middle, an edge column keeps its edge, and a
  /// column beside middle lands on the nearer side instead of travelling
  /// to the centre.
  static int _landingTarget(int startColumn, int startColumns, int columns) {
    final target = ((startColumn + 0.5) * columns / startColumns - 0.5).round();
    return target.clamp(0, columns - 1);
  }

  /// Leading empty slots that put [focalIndex]'s slot on [target] —
  /// clamped toward the item's absolute column when it sits too near the
  /// list's start or end to fill the flanking columns.
  static int _phaseForTarget(MorphGridStop stop, int target, int focalIndex, int itemCount) {
    final columns = stop.columns;
    if (stop.mirrorRows) {
      // A mirrored row flips its items inside the row's OCCUPIED slot
      // range, which itself moves with the phase — the displayed column is
      // self-referential in phase, so no closed form exists. Scan the
      // candidates and keep the phase landing the focal on the reachable
      // column nearest the target.
      var best = 0;
      var bestDistance = columns;
      for (var p = 0; p < columns; p++) {
        final distance = (stop.withPhase(p).columnOf(focalIndex, itemCount) - target).abs();
        if (distance < bestDistance) {
          best = p;
          bestDistance = distance;
        }
      }
      return best;
    }
    // Focal can't sit right of its own index (not enough items before it)
    // nor left of the tail's fill (not enough items after it).
    final hi = math.min(columns - 1, focalIndex);
    final lo = math.min(math.max(0, columns - 1 - (itemCount - 1 - focalIndex)), hi);
    final column = target.clamp(lo, hi);
    return ((column - focalIndex % columns) % columns + columns) % columns;
  }

  /// The ladder invariant [begin] asserts — distinct counts, fewest first
  /// (equal counts would divide by zero inside [levelForLogTile]).
  static bool _strictlyIncreasingColumns(List<MorphGridStop> stops) {
    for (var k = 1; k < stops.length; k++) {
      if (stops[k].columns <= stops[k - 1].columns) return false;
    }
    return true;
  }

  /// Re-stamps the settle stop's landing phase for [resolvedIndex] — the
  /// pinched item re-found at a new index after the cell list reshaped
  /// mid-settle (stack fold/unfold, a merge inserting cells before it).
  /// The visual position the pinch captured at [begin] — the landing
  /// column nearest the photo's start column — stays; only the index
  /// under it moved. No-op on the start stop: its phase is the real
  /// grid's, not a landing target.
  void rephaseLanding(int resolvedIndex) {
    if (!_centerFocal || settleStop == startStop || stops.isEmpty) return;
    final stop = stops[settleStop];
    stops[settleStop] = stop.withPhase(
      _phaseForTarget(
        stop,
        _landingTarget(_focalStartColumn, _focalStartColumns, stop.columns),
        resolvedIndex,
        itemCount,
      ),
    );
  }

  /// The displayed column the pinched item held at pinch start and the
  /// start stop's column count — the edge/interior intent [rephaseLanding]
  /// preserves when the item's index moves under a mid-settle reshape.
  /// [_centerFocal] remembers whether the landing phases were stamped at
  /// all (index-absolute morphs keep phase 0 — nothing to re-stamp).
  int _focalStartColumn = 0;
  int _focalStartColumns = 1;
  bool _centerFocal = false;

  /// The low-passed level the gesture path converges on — reset by [begin]
  /// and [reframe] so each pinch's filter starts where that pinch did.
  double _gestureLevel = 0;

  /// Drives [level] through the gesture low-pass — see
  /// [PinchMorphStyle.levelSmoothing]. [dtSeconds] is the event-clock gap
  /// since the previous sample; `null` (the first sample of a pinch, or an
  /// event source without clocks) snaps straight to the raw level. The
  /// settle writes [set] directly — its spring already eases.
  void trackLevel(double rawLevel, {double? dtSeconds}) {
    final k = dtSeconds == null || style.levelSmoothing <= 0 ? 1.0 : 1 - math.exp(-dtSeconds / style.levelSmoothing);
    _gestureLevel += (rawLevel - _gestureLevel) * k;
    set(level: _gestureLevel);
  }

  /// Updates the live pinch state — called by the widget on every gesture
  /// update and settle tick. Any combination may be set; `null` holds the
  /// current value.
  void set({double? level, double? overscale, double? pin}) {
    assert(
      level == null || (level.isFinite && level >= 0),
      'level must be a finite, non-negative ladder position, got $level',
    );
    assert(
      overscale == null || (overscale.isFinite && overscale > 0),
      'overscale must be positive and finite, got $overscale',
    );
    assert(
      pin == null || (pin.isFinite && pin >= 0),
      'pin is a settle-blend factor [0, 1] — must be finite and non-negative, got $pin',
    );
    if (level == this.level && overscale == this.overscale && pin == this.pin) {
      return;
    }
    this.level = level ?? this.level;
    this.overscale = overscale ?? this.overscale;
    this.pin = pin ?? this.pin;
    notifyListeners();
  }

  /// Item indices the last emitted frame paints — the visible lattice plus
  /// its margin. Mutated in place inside [frame]; an image cache can keep
  /// the reference and always read the live set (the priority set: what the
  /// user is looking at decodes first).
  Set<int> get visibleIndices => Set.unmodifiable(_visibleIndices);
  final _visibleIndices = <int>{};

  /// Lower stop of the current interval and the progress towards the next;
  /// progress is 0 when resting on a stop.
  (int, double) get interval {
    final lower = math.min(level.floor(), stops.length - 1);
    final progress = level - lower;
    return (lower, progress < 1e-6 || lower == stops.length - 1 ? 0.0 : progress);
  }

  /// Natural log of a stop's tile width — the interpolation axis the pinch
  /// scale maps onto.
  double logTileWidth(int stop) => math.log(stops[stop].tileWidth);

  /// Log tile width at a fractional [level] — tile size interpolates
  /// geometrically between stops, so equal pinch ratios feel equal.
  double logTileWidthAt(double level) {
    if (stops.length == 1) return logTileWidth(0);
    final lower = level.floor().clamp(0, stops.length - 2);
    return logTileWidth(lower) + (logTileWidth(lower + 1) - logTileWidth(lower)) * (level - lower);
  }

  /// Inverse of [logTileWidthAt]: maps a pinched tile width to
  /// (level, overscale). Past the largest-tile stop it rubber-bands; past
  /// the densest it clamps.
  (double, double) levelForLogTile(double logTileWidth) {
    final last = stops.length - 1;
    final first = this.logTileWidth(0);
    if (logTileWidth >= first) {
      return (0.0, math.exp((logTileWidth - first) * style.rubberBand));
    }
    if (logTileWidth <= this.logTileWidth(last)) return (last.toDouble(), 1.0);
    for (var k = 0; k < last; k++) {
      final high = this.logTileWidth(k);
      final low = this.logTileWidth(k + 1);
      if (logTileWidth >= low) {
        return (k + (high - logTileWidth) / (high - low), 1.0);
      }
    }
    return (last.toDouble(), 1.0);
  }

  /// Quintic smootherstep (6x⁵−15x⁴+10x³), clamped to [0, 1].
  ///
  /// Unlike cubic smoothstep, its first AND second derivatives are zero at
  /// both ends. Reflow and coverage therefore enter/leave their windows
  /// without a visible acceleration kick, while retaining monotonic motion
  /// and the same exact endpoints.
  static double _smoothstep(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * t * (t * (t * 6 - 15) + 10);
  }

  /// Smoothstep over a window of [width] centred on the interval's
  /// midpoint: 0 at/below `0.5 − width/2`, 1 at/above `0.5 + width/2`.
  static double _midpointRamp(double progress, double width) => _smoothstep((progress - 0.5) / width + 0.5);

  /// The reflow window for a transition between [a] and [b], scaled to the
  /// interval's density jump: [PinchMorphStyle.reflowWindow] calibrates
  /// the ladder's average log-width step, so a bigger jump redistributes
  /// over more of the gesture and a narrow one snaps sooner. Floored at
  /// half the style value so a small step still reads, capped so a huge
  /// one can't swallow the whole traverse.
  double _reflowWindowFor(MorphGridStop a, MorphGridStop b) {
    if (stops.length < 2) return style.reflowWindow;
    final typical = (logTileWidth(stops.length - 1) - logTileWidth(0)).abs() / (stops.length - 1);
    final step = (math.log(a.tileWidth) - math.log(b.tileWidth)).abs();
    if (typical < 1e-9 || step < 1e-9) return style.reflowWindow;
    return (style.reflowWindow * step / typical).clamp(style.reflowWindow * 0.5, 0.9);
  }

  /// Scroll offset the header (and the band edge below it) follows: where it
  /// was at pinch start, easing to the settled stop's rest scroll.
  double get headerScroll => lerpDouble(restScrolls[settleStop], startScroll, pin)!;

  /// The focal cell's pinch point on screen: under the fingers while they
  /// are down, gliding to the settled stop's rest position on release.
  ///
  /// Horizontally the emitted lattice is column-true and span-centred,
  /// never finger-anchored: each stop's lattice keeps its own column span
  /// centred on the screen, so the band's left and right margins converge
  /// identically at every level — a centre landing's geometry for every
  /// focal — while the pinched photo glides inside the band to its
  /// landing column. Anchoring the band on the landing column instead
  /// piles the un-zoomed slack onto the far screen edge.
  ///
  /// Diagnostic surface: frame() derives the same vertical value inside
  /// its focal-top pipeline rather than paying for [_anchorDx]'s interval
  /// re-derivation every emitted frame.
  Offset get anchor {
    final live = Offset(_anchorDx, focalPoint.dy);
    if (pin >= 1) return live;
    final rect = stops[settleStop].tileRect(focalIndex, origin, itemCount);
    final rest = Offset(
      rect.left + _focalPivotFrac * rect.width,
      rect.top + focalFraction.dy * rect.height - restScrolls[settleStop],
    );
    return Offset.lerp(rest, live, pin)!;
  }

  /// The focal cell's live tracked point: its emitted band position plus
  /// [_focalPivotFrac]·cellWidth — the held bezel edge for a bezel cell,
  /// the centre otherwise. The anchor must not care where on the cell
  /// the fingers landed (the off-centre-pinch invariant). Only [anchor]
  /// reads it.
  double get _anchorDx {
    final (lowerStop, progress) = interval;
    final larger = stops[lowerStop];
    final denser = progress == 0 ? larger : stops[lowerStop + 1];
    final cellWidth = progress == 0
        ? larger.tileWidth * overscale
        : math.exp(lerpDouble(math.log(larger.tileWidth), math.log(denser.tileWidth), progress)!);
    return _emittedFocalLeftX(cellWidth) + _focalPivotFrac * cellWidth;
  }

  /// Which screen edges the focal cell rests on at pinch start: (left
  /// bezel, right bezel). Both true only on the single-column stop,
  /// whose one cell spans the screen edge to edge.
  (bool, bool) get _focalBezels {
    final start = _pinchStartFocalRect;
    final spacing = stops[startStop].spacing;
    return (start.left <= spacing + 0.5, start.right >= viewport.width - spacing - 0.5);
  }

  /// The tracked point inside the focal cell: the bezel-side edge for a
  /// cell resting on ONE bezel (1 → right edge, 0 → left), its centre
  /// otherwise. A bezel focal pins the edge it sits on, not the cell
  /// centre: a centre pivot would let the photo's watched bezel edge
  /// leave the screen edge as the cell shrinks mid-gesture and ride
  /// back at the end — an out-and-back the inboard edge never feels.
  /// A cell spanning BOTH bezels (the single-column stop) has no edge
  /// to hug — pinning one side would park the photo at that bezel while
  /// its landing column sits mid-screen; it centre-scales like an
  /// interior cell and converges on its rest column as it shrinks.
  double get _focalPivotFrac {
    final (leftBezel, rightBezel) = _focalBezels;
    if (leftBezel != rightBezel) return leftBezel ? 0 : 1;
    return 0.5;
  }

  /// The focal cell's emitted left edge while the fingers are down —
  /// two anchors by where the pinched cell sits:
  ///
  /// * A cell resting on a bezel pins that screen edge (`start.left`,
  ///   resp. `start.right − cellW`): the photo under the finger hugs
  ///   the bezel through the gesture, exactly like the pinned
  ///   reference. Scaling it about the viewport centre instead pulled
  ///   the edge photo off its bezel mid-gesture — the broken edge
  ///   anchor.
  /// * An interior cell rides the shared scale about the viewport's
  ///   horizontal centre (the parked left lerped about `W/2` by the
  ///   cell's scale): the whole band is one rigid lattice scaled about
  ///   the screen's middle, so a pinch on a side cell produces exactly
  ///   the motion a pinch on the centre image does — column edges stay
  ///   equally clipped on both bezels at every level. Pivoting on the
  ///   focal's own pinch-start position instead left an off-centre
  ///   focal's band off balance — one bezel ate a clipped column while
  ///   the other kept nearly a full one.
  double _liveFocalLeftX(double cellWidth) {
    final start = _pinchStartFocalRect;
    final (leftBezel, rightBezel) = _focalBezels;
    if (leftBezel != rightBezel) return leftBezel ? start.left : start.right - cellWidth;
    return lerpDouble(viewport.width / 2, start.left, cellWidth / start.width)!;
  }

  /// The band's emitted anchor: the live tracked point while the
  /// fingers are down ([pin] → 1). On release that POINT glides in a
  /// straight line to its rest position (`rest.left + p·rest.width`)
  /// as [pin] → 0 — the parked start grid and the committed grid are
  /// both exact, and the settle path doesn't curve with the cell size.
  double _emittedFocalLeftX(double cellWidth) {
    final live = _liveFocalLeftX(cellWidth);
    if (pin >= 1) return live;
    final rest = stops[settleStop].tileRect(focalIndex, origin, itemCount);
    final p = _focalPivotFrac;
    final livePoint = live + p * cellWidth;
    final restPoint = rest.left + p * rest.width;
    return lerpDouble(restPoint, livePoint, pin)! - p * cellWidth;
  }

  /// Everything one morph frame paints: every tile and section pill, back
  /// to front, plus the band bounds.
  ///
  /// `clipTop`/`clipBottom` bound the band tiles may paint in — under
  /// [reversed] the header hugs the bottom edge, so the clip runs
  /// 0..clipBottom there instead of clipTop..height.
  MorphFrame frame(bool Function(int index) isSectionStart) {
    assert(stops.isNotEmpty, 'call begin() before frame()');
    final (lowerStop, progress) = interval;
    final larger = stops[lowerStop];
    final denser = progress == 0 ? larger : stops[lowerStop + 1];
    final spacing = larger.spacing;

    // The reflow window: slots slide between the two stops' placements and
    // their contents crossfade only inside it. Outside it `reflow` clamps
    // to 0 or 1 and the nearer stop's layout simply scales — the frame
    // stays crisp for most of the gesture. The window adapts to this
    // interval's density jump.
    final reflowWindow = _reflowWindowFor(larger, denser);
    final reflow = _midpointRamp(progress, reflowWindow);
    final cellWidth = progress == 0
        ? larger.tileWidth * overscale
        : math.exp(lerpDouble(math.log(larger.tileWidth), math.log(denser.tileWidth), progress)!);
    final cellHeight = cellWidth * lerpDouble(larger.aspect, denser.aspect, reflow)!;
    final strideX = cellWidth + spacing;
    final strideY = cellHeight + spacing;

    // The lattices anchor vertically on ONE scalar — the focal cell's
    // resolved top — and horizontally on each stop's centred column span.
    final focalRowLarger = larger.rowOf(focalIndex);
    final focalColumnLarger = larger.columnOf(focalIndex, itemCount);
    final focalRowDenser = denser.rowOf(focalIndex);
    final focalColumnDenser = denser.columnOf(focalIndex, itemCount);
    final clipTop = math.max(0.0, origin - headerScroll);
    // The leading-edge coverage floor eases from the parked clip to
    // [coverageLeading] as the level leaves the start stop — a leading
    // sliver that only exists at rest (floating chrome) gets covered by
    // tiles mid-gesture with no first-frame jump.
    final coverageClipTop = coverageLeading == null
        ? clipTop
        : lerpDouble(clipTop, coverageLeading!, _smoothstep((level - startStop).abs() / style.coverageBlendSpan))!;
    final bandBottom = viewport.height - trailing;
    // Pinch tracking → in-band clamp → coverage push → release glide —
    // see _resolveFocalTop (pinch_morph/focal_top.dart).
    final focalTop = _resolveFocalTop(
      larger: larger,
      denser: denser,
      progress: progress,
      reflow: reflow,
      reflowWindow: reflowWindow,
      cellHeight: cellHeight,
      strideY: strideY,
      clipTop: clipTop,
      coverageClipTop: coverageClipTop,
      bandBottom: bandBottom,
      spacing: spacing,
    );

    // The band anchors horizontally on the focal slot's left, holding
    // the pinch-start pivot while the fingers are down and gliding to
    // the settle stop's rest column on release — see `_emittedFocalLeftX`.
    // Every slot emits at `emittedFocalLeft + columnOffset·strideX` and
    // `focalTop + rowOffset·strideY` — a uniform translation, so the
    // whole band moves as one rigid lattice.
    final emittedFocalLeft = _emittedFocalLeftX(cellWidth);
    if (PinchMorph.debugTraceEnabled && PinchMorph.debugTrace.length < 2000) {
      PinchMorph.debugTrace.add(
        'L=${level.toStringAsFixed(4)} pin=${pin.toStringAsFixed(2)} '
        'emitX=${emittedFocalLeft.toStringAsFixed(1)} '
        'restX=${(spacing + focalColumnDenser * denser.columnStride).toStringAsFixed(1)}/'
        '${(spacing + focalColumnLarger * larger.columnStride).toStringAsFixed(1)}',
      );
    }

    final zoomIn = level < startStop;
    // The photo swap finishes well before the slot glide does — easing the
    // crossfade to its endpoint early keeps tiles crisp through most of
    // the reflow window instead of lingering as washed double-images (iOS
    // reads rigid until the re-grid snaps). Photos swap on the style's
    // own window — not the adaptive position window, which may span most
    // of a big density jump: letting the crossfade follow it bleeds the
    // arriving photo in from the start of the gesture, the early-
    // replacement artifact the next-screen gating exists to prevent.
    final reflowCrossfade = _midpointRamp(progress, style.reflowWindow);
    final crossfade = zoomIn
        ? math.pow(reflowCrossfade, style.crossfadeEase).toDouble()
        : 1 - math.pow(1 - reflowCrossfade, style.crossfadeEase).toDouble();

    final (underTiles, stableTiles, overTiles, pills) = _TileEmitter(
      larger: larger,
      denser: denser,
      emittedFocalLeft: emittedFocalLeft,
      focalTop: focalTop,
      strideX: strideX,
      strideY: strideY,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      focalColumnLarger: focalColumnLarger,
      focalRowLarger: focalRowLarger,
      focalColumnDenser: focalColumnDenser,
      focalRowDenser: focalRowDenser,
      itemCount: itemCount,
      viewport: viewport,
      clipTop: clipTop,
      bandBottom: bandBottom,
      reversed: reversed,
      progress: progress,
      crossfade: crossfade,
      zoomIn: zoomIn,
      restScrolls: restScrolls,
      lowerStop: lowerStop,
      origin: origin,
      pinchStartStop: stops[startStop],
      startScroll: startScroll,
      focalIndex: focalIndex,
      isSectionStart: isSectionStart,
    ).emit();

    _visibleIndices
      ..clear()
      ..addAll(underTiles.map((tile) => tile.index))
      ..addAll(stableTiles.map((tile) => tile.index))
      ..addAll(overTiles.map((tile) => tile.index));

    return MorphFrame(
      tiles: [...underTiles, ...stableTiles, ...overTiles],
      pills: pills,
      // Mirrored clipTop is the header zone's distance from the real
      // bottom edge — emitted as the clip's real-space bounds.
      clipTop: reversed ? 0.0 : clipTop,
      clipBottom: reversed ? viewport.height - coverageClipTop : viewport.height,
      headerTop: reversed ? viewport.height - clipTop : headerOrigin - headerScroll,
    );
  }
}

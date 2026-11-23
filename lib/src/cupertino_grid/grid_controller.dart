part of '../cupertino_grid.dart';

/// Who is moving the scroll position — lets hosts tell user gestures
/// apart from programmatic jumps and coasting momentum. Reported by
/// [CupertinoGridController.scrollDriver]; transitions are tracked from
/// the grid's own scroll notifications.
enum GridScrollDriver {
  /// No scroll session in flight.
  idle,

  /// A finger is on the glass dragging the list.
  drag,

  /// Finger lifted; momentum is still scrolling (a fling). Anchors read
  /// in this phase are drive-bys — defer anchor-driven work (prefetch,
  /// gap probes) to [CupertinoGrid.onScrollSettled].
  ballistic,

  /// A `jumpTo`/`animateTo`/position correction is moving the viewport.
  programmatic,
}

/// External control surface for a [CupertinoGrid]: index navigation,
/// global-point hit-testing, drag-range selection with edge auto-scroll,
/// and scroll-session state — the mechanics a gallery host otherwise
/// re-derives from scroll geometry by hand.
///
/// Domain identity stays with the host: selection is emitted as item
/// INDICES through [selectedIndices]; mapping those back to real items
/// (and persisting the selection) is the host's job.
///
/// ```dart
/// final grid = CupertinoGridController();
/// CupertinoGrid(
///   controller: grid,
///   onScrollSettled: (anchor, direction) => prefetch(anchor),
///   itemCount: items.length,
///   itemBuilder: (context, index, targetSize) => MyTile(
///     onLongPressStart: (d) => grid.beginSelectionDrag(index, d.globalPosition),
///     onLongPressMoveUpdate: (d) => grid.updateSelectionDrag(d.globalPosition),
///     onLongPressEnd: (_) => grid.endSelectionDrag(),
///   ),
/// )
/// ```
final class CupertinoGridController {
  /// Creates the controller.
  CupertinoGridController({
    this.edgeScrollBand = 72,
    this.edgeScrollMaxSpeed = 18,
  });

  /// Distance from a viewport edge where a held selection drag starts
  /// auto-scrolling, in logical pixels.
  final double edgeScrollBand;

  /// Peak auto-scroll speed in logical px per ~16 ms tick — eases from
  /// zero as the pointer approaches the edge so selection stays
  /// controllable.
  final double edgeScrollMaxSpeed;

  /// Item indices the live selection drag covers — a contiguous SLOT
  /// sweep, so under `mirrorRows` the set is not a contiguous index
  /// range. Emits on every extension; listen and map indices to host
  /// identities.
  final ValueNotifier<Set<int>> selectedIndices = ValueNotifier<Set<int>>(
    const {},
  );

  _CupertinoGridState? _state;

  int? _dragAnchorIndex;
  int _dragLastIndex = -1;
  Set<int> _dragBase = const {};
  Offset? _lastDragGlobal;
  double _edgeScrollVelocity = 0;
  Timer? _edgeScrollTimer;

  /// Landing verification bookkeeping — a clamped jump near the list end
  /// can land short while `maxScrollExtent` still describes the
  /// pre-merge list, so the jump re-checks once extents settle.
  int? _pendingVerifyIndex;
  double _pendingVerifyInset = 0;
  int _verifyRetries = 0;

  void _attach(_CupertinoGridState state) => _state = state;

  void _detach(_CupertinoGridState state) {
    if (identical(_state, state)) _state = null;
  }

  /// The current scroll-session driver — see [GridScrollDriver].
  GridScrollDriver get scrollDriver =>
      _state?._scrollDriver ?? GridScrollDriver.idle;

  /// Whether the pinch morph currently owns the grid's geometry —
  /// mid-pinch geometry no longer matches the painted cells, so
  /// hit-tests and index navigation should not run against it.
  bool get morphActive => _state?._morphActive ?? false;

  /// The grid's scroll controller, when attached.
  ScrollController? get scrollController => _state?._scrollController;

  /// The committed density's geometry, when attached — row/slot mapping,
  /// tile rects and extent projections for host-side overlays.
  MorphGridStop? get stop => _state?._currentStop;

  /// Offset that lands [index]'s row at the viewport's leading edge plus
  /// [leadingInset] (status bar + floating chrome the row must clear).
  /// Axis-aware: under `reverse` the row's scroll-space bottom edge is
  /// the one pinned. The value is unclamped — callers scrolling should
  /// prefer [scrollToIndex], which also projects extents.
  double scrollOffsetForIndex(int index, {double leadingInset = 0}) {
    final state = _state;
    if (state == null) return 0;
    final stop = state._currentStop;
    final row = stop.rowOf(index);
    return state.widget.reverse
        ? stop.rowTop(row + 1, state._gridOrigin) +
              leadingInset -
              state._viewportHeight
        : stop.rowTop(row, state._gridOrigin) - leadingInset;
  }

  /// Positions the viewport so [index]'s row is visible — a no-op while
  /// the row is already fully on screen.
  ///
  /// [targetItemCount] is the item count the grid is about to rebuild to
  /// (the post-merge length when this call lands inside the same commit
  /// as a list reshape): the grid's own extent delta is projected onto
  /// the live `maxScrollExtent` — which still describes the OLD list
  /// mid-build — so a landing near the end clamps to the real post-merge
  /// extent instead of short of it. Supplying it also suppresses the
  /// grid's leading-row anchor hold for that pass: the hold would pull
  /// the viewport back toward the parked anchor mid-layout.
  ///
  /// `animate` glides instead of jumping; the landing verify pass only
  /// runs for jumps (a glide owns the position until it completes).
  void scrollToIndex(
    int index, {
    int? targetItemCount,
    double leadingInset = 0,
    bool animate = false,
    Duration duration = const Duration(milliseconds: 250),
    Curve curve = Curves.easeOut,
  }) {
    final state = _state;
    if (state == null || index < 0) return;
    final controller = state._scrollController;
    if (!controller.hasClients) return;
    final stop = state._currentStop;
    final row = stop.rowOf(index);
    final rowTop = stop.rowTop(row, state._gridOrigin);
    final rowBottom = stop.rowTop(row + 1, state._gridOrigin);
    // The merge already slid the target row inside the viewport — leave
    // the position alone and let the content materialize in place. The
    // diff still runs this pass and its anchor hold would drag the
    // viewport back to the OLD leading row — suppress it the same as a
    // jump landing.
    if (rowTop >= controller.offset &&
        rowBottom <= controller.offset + state._viewportHeight) {
      if (targetItemCount != null) state._suppressAnchorHold = true;
      return;
    }
    final position = controller.position;
    // position.maxScrollExtent still describes the pre-merge list
    // mid-build, so project the grid's own extent delta onto it — a bare
    // rowTop projection misses the header/footer extent and clamps the
    // landing short near the end.
    final liveMax = position.hasContentDimensions
        ? position.maxScrollExtent
        : 0.0;
    final oldCount = state._syncedCount >= 0
        ? state._syncedCount
        : state.widget.itemCount;
    final newCount = targetItemCount ?? state.widget.itemCount;
    final projectedMax = math.max(
      0.0,
      liveMax +
          stop.rowTop(stop.rowCount(newCount), state._gridOrigin) -
          stop.rowTop(stop.rowCount(oldCount), state._gridOrigin),
    );
    final rawOffset = state.widget.reverse
        ? rowBottom + leadingInset - state._viewportHeight
        : rowTop - leadingInset;
    final offset = rawOffset.clamp(position.minScrollExtent, projectedMax);
    if (targetItemCount != null) state._suppressAnchorHold = true;
    if (animate) {
      unawaited(controller.animateTo(offset, duration: duration, curve: curve));
      return;
    }
    controller.jumpTo(offset);
    _pendingVerifyIndex = index;
    _pendingVerifyInset = leadingInset;
    _verifyRetries = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _verifyLanding());
  }

  /// Re-checks a jumped landing once the merge frame's extents settle —
  /// a user drag or fling that started since owns the scroll and cancels
  /// it; a still-running programmatic session defers the check.
  void _verifyLanding() {
    final state = _state;
    final index = _pendingVerifyIndex;
    if (state == null || index == null) return;
    // The merge frame consumed the suppression — a re-jump re-arms it.
    state._suppressAnchorHold = false;
    switch (state._scrollDriver) {
      case GridScrollDriver.drag || GridScrollDriver.ballistic:
        _pendingVerifyIndex = null;
        return;
      case GridScrollDriver.programmatic when _verifyRetries < 40:
        _verifyRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) => _verifyLanding());
        return;
      case _:
        _pendingVerifyIndex = null;
    }
    final controller = state._scrollController;
    if (!controller.hasClients || index >= state.widget.itemCount) return;
    final stop = state._currentStop;
    final row = stop.rowOf(index);
    final rowTop = stop.rowTop(row, state._gridOrigin);
    final rowBottom = stop.rowTop(row + 1, state._gridOrigin);
    if (rowTop >= controller.offset &&
        rowBottom <= controller.offset + state._viewportHeight) {
      return;
    }
    final rawOffset = state.widget.reverse
        ? rowBottom + _pendingVerifyInset - state._viewportHeight
        : rowTop - _pendingVerifyInset;
    final offset = rawOffset.clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    state._suppressAnchorHold = true;
    controller.jumpTo(offset);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => state._suppressAnchorHold = false,
    );
  }

  /// Resolves the item under a GLOBAL screen point through the live
  /// stop, or −1 when the point lands outside the grid content. Axis-
  /// aware: under `reverse` a global point maps to
  /// `scrollY = offset + viewportHeight − localY`.
  int indexAtGlobalPoint(Offset global) {
    final state = _state;
    if (state == null || state.widget.itemCount == 0) return -1;
    final controller = state._scrollController;
    final box = state.context.findRenderObject() as RenderBox?;
    if (box == null || !controller.hasClients) return -1;
    final local = box.globalToLocal(global);
    final contentY = state.widget.reverse
        ? controller.offset + state._viewportHeight - local.dy
        : local.dy + controller.offset;
    return state._currentStop.indexAt(
      Offset(local.dx, contentY),
      state.widget.itemCount,
      state._gridOrigin,
    );
  }

  /// Anchors a drag-select range at [index] — the long-pressed tile —
  /// with the pointer at [global] (use the gesture's `globalPosition`).
  /// [base] indices stay selected for the whole session; the anchor
  /// itself always lands in the emitted set so a drag can't drop its
  /// own tile.
  void beginSelectionDrag(
    int index,
    Offset global, {
    Set<int> base = const {},
  }) {
    _endEdgeScroll();
    _dragAnchorIndex = index;
    _dragLastIndex = index;
    _dragBase = base;
    _lastDragGlobal = global;
    _emit({...base, index});
  }

  /// Feeds a pointer move to the session — extends the sweep to the tile
  /// under [global] and runs edge auto-scroll while the pointer sits in
  /// [edgeScrollBand].
  void updateSelectionDrag(Offset global) {
    _lastDragGlobal = global;
    _extendDragTo(global);
    _updateEdgeScroll(global);
  }

  /// Ends the session and stops edge auto-scroll. The last emitted set
  /// stays on [selectedIndices] — the host owns clearing it.
  void endSelectionDrag() {
    _dragAnchorIndex = null;
    _dragLastIndex = -1;
    _dragBase = const {};
    _lastDragGlobal = null;
    _endEdgeScroll();
  }

  void _emit(Set<int> indices) => selectedIndices.value = indices;

  /// Extends the range to the tile under [global]. The sweep is a
  /// contiguous SLOT range — display order — so under `mirrorRows` the
  /// emitted indices are mapped back through `itemAt`, not assumed
  /// contiguous. Skipped while a morph owns the geometry.
  void _extendDragTo(Offset global) {
    final state = _state;
    final anchor = _dragAnchorIndex;
    if (state == null || anchor == null || state._morphActive) return;
    final count = state.widget.itemCount;
    final target = indexAtGlobalPoint(global);
    if (target < 0 || target == _dragLastIndex) return;
    _dragLastIndex = target;
    final stop = state._currentStop;
    final lo = math.min(stop.slotOf(anchor, count), stop.slotOf(target, count));
    final hi = math.max(stop.slotOf(anchor, count), stop.slotOf(target, count));
    _emit({
      ..._dragBase,
      for (var slot = lo; slot <= hi; slot++)
        if (stop.itemAt(slot, count) case final i when i >= 0 && i < count) i,
    });
  }

  /// Auto-scroll while the held pointer sits in an edge band — the
  /// long-press owns the drag so the scroll view won't move on its own,
  /// matching iOS Photos' select-and-drift behavior.
  void _updateEdgeScroll(Offset global) {
    final state = _state;
    final box = state?.context.findRenderObject() as RenderBox?;
    if (state == null || box == null) return;
    final dy = box.globalToLocal(global).dy;
    double velocity = 0;
    if (dy < edgeScrollBand) {
      velocity =
          -edgeScrollMaxSpeed * (1 - (dy / edgeScrollBand)).clamp(0.0, 1.0);
    } else if (dy > box.size.height - edgeScrollBand) {
      velocity =
          edgeScrollMaxSpeed *
          (1 - (box.size.height - dy) / edgeScrollBand).clamp(0.0, 1.0);
    }
    // Reversed axis: toward the top edge is increasing offset.
    if (state.widget.reverse) velocity = -velocity;
    _edgeScrollVelocity = velocity;
    velocity == 0 ? _endEdgeScroll() : _startEdgeScroll();
  }

  void _startEdgeScroll() {
    _edgeScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final state = _state;
      final controller = state?._scrollController;
      final velocity = _edgeScrollVelocity;
      if (state == null ||
          controller == null ||
          !controller.hasClients ||
          velocity == 0) {
        _endEdgeScroll();
        return;
      }
      final position = controller.position;
      final next = (controller.offset + velocity).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next == controller.offset) {
        _endEdgeScroll();
        return;
      }
      controller.jumpTo(next);
      // Rows moved under the stationary finger — re-extend the range.
      final global = _lastDragGlobal;
      if (global != null) _extendDragTo(global);
    });
  }

  void _endEdgeScroll() {
    _edgeScrollTimer?.cancel();
    _edgeScrollTimer = null;
    _edgeScrollVelocity = 0;
  }

  /// Stops edge auto-scroll and disposes [selectedIndices]. Safe to call
  /// while attached — the grid detaches itself on unmount.
  void dispose() {
    _endEdgeScroll();
    selectedIndices.dispose();
  }
}

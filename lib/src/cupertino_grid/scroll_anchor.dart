part of '../cupertino_grid.dart';

/// The shortest insert duration that is safe for `AnimatedGrid` internals:
/// `Duration.zero` resolves `controller.forward()` SYNCHRONOUSLY inside
/// [SliverAnimatedGridState.insertItem], queuing its cleanup `.then` as a
/// microtask while the calling task keeps running — a `removeItem` later in
/// the same task extracts the item from `_incomingItems` first and the
/// `.then`'s `!` throws (framework `_TypeError` at
/// `animated_scroll_view.dart:1399`). Any nonzero duration instead resolves
/// inside the ticker task, where no `removeItem` can interleave between the
/// resolution and the `.then` drain.
///
/// Used for [_applyPhase]'s leading-hole inserts — the only inserts a
/// same-task `removeItem(0)` can reach (a second [_applyPhase] with a
/// smaller delta extracts the still-pending hole items). Hole children are
/// invisible, so the duration changes nothing visually. Visible-item
/// inserts in [_syncGrid] keep `Duration.zero`: their itemBuilder fades the
/// tile in, and no same-task removal ever targets a real item's slot —
/// `removeItem(0)` only reaches the phase holes, and [_syncGrid]'s own
/// removals always run before its insertions.
const Duration _kInstantInsertDuration = Duration(milliseconds: 1);

/// Scroll anchoring: keeping the committed grid glued to the same content
/// across cell-list reshapes (inserts, merges, column changes), scroll
/// notifications, and the edge-anchor callbacks.
extension _ScrollAnchor on _CupertinoGridState {
  /// Reads the grid and header slivers' scroll-content origins from their
  /// last layout. Returns whether the grid origin moved. Never call during
  /// build.
  bool _measureGridOrigin() {
    final header = _headerSliverKey.currentContext?.findRenderObject();
    if (header is RenderSliver && header.geometry != null) {
      _headerOrigin = header.constraints.precedingScrollExtent;
    }
    final sliver = _gridSliverKey.currentContext?.findRenderObject();
    if (sliver is! RenderSliver || sliver.geometry == null) return false;
    final origin = sliver.constraints.precedingScrollExtent;
    if ((origin - _gridOrigin).abs() < 0.5) return false;
    _gridOrigin = origin;
    return true;
  }

  void _updateScrollOffset() {
    if (_scrollController.hasClients) {
      _lastValidScrollOffset = _scrollController.offset;
    }
  }

  void _jumpToClamped(double offset) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _scrollController.jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  Offset _toLocal(Offset global, Offset fallback) {
    final box = context.findRenderObject() as RenderBox?;
    return (box != null && box.hasSize) ? box.globalToLocal(global) : fallback;
  }

  /// Moves the grid's leading-hole count to [next]: the keyed children
  /// re-map through `findChildIndexCallback` (slot = item + _phase), the
  /// leading slots appear/collapse instantly at the grid's head.
  ///
  /// [forColumns] is the column count [next] was computed for. A landing
  /// phase can exceed the CURRENT grid's column count while a controlled
  /// parent still owns the old density — `MorphGridStop` throws on
  /// phase >= columns, and the sliver would render a foreign hole count —
  /// so the stamp is held in [_pendingPhase] until the columns commit.
  /// The overlay covers the interim.
  void _applyPhase(int next, {int? forColumns}) {
    _pendingPhase = null;
    if (forColumns != null && forColumns != _effectiveColumns) {
      _pendingPhase = (forColumns, next);
      return;
    }
    final delta = next - _phase;
    if (delta == 0) return;
    _phase = next;
    final grid = _gridKey.currentState;
    if (grid == null) return;
    if (delta > 0) {
      for (var i = 0; i < delta; i++) {
        grid.insertItem(0, duration: _kInstantInsertDuration);
      }
    } else {
      for (var i = 0; i < -delta; i++) {
        grid.removeItem(0, (_, _) => const SizedBox.shrink(), duration: Duration.zero);
      }
    }
  }

  /// Diffs the current item keys against [_syncedKeys] — what the grid last
  /// displayed — and issues insert/remove calls. Runs in build so a merged
  /// or filtered list stays synced even when [CupertinoGrid.itemCount] is
  /// unchanged.
  void _syncGrid() {
    // The morph captured the item count when the pinch began — a merge or
    // stack-collapse landing mid-gesture shrinks it under the overlay's
    // feet, so frames would emit indices the page no longer has. Keep the
    // lattice count current and drop slots that now point past the tail.
    _morph.itemCount = widget.itemCount;
    if (_morphActive) {
      _overlayTiles.removeWhere((index) => index >= widget.itemCount);
      _overlayTileSizes.removeWhere((index, _) => index >= widget.itemCount);
      _overlayPills.removeWhere((slot) => slot.$2 >= widget.itemCount);
    }
    final version = widget.itemsVersion;
    if (_syncedCount == widget.itemCount && identical(_syncedVersion, version)) {
      return;
    }
    _syncedCount = widget.itemCount;
    _syncedVersion = version;
    final newKeys = [for (var i = 0; i < widget.itemCount; i++) _keyOf(i)];
    _indexByKey = {for (var i = 0; i < newKeys.length; i++) newKeys[i]: i};
    final oldKeys = _syncedKeys;
    _syncedKeys = newKeys;
    _morph.itemEpoch++;
    // The layout pass below emits the morph frame from LIVE fields:
    // stamping itemCount while focalIndex/phase still resolve against
    // the OLD list hands every emitted slot a shifted index for one
    // frame — the whole band paints a column off and snaps back (the
    // post-land blink). Re-resolve the focal + landing phase in-build;
    // the post-frame retarget only re-aims the settle glide's rest.
    if (_morphActive) _syncFocalIndex();
    final grid = _gridKey.currentState;
    if (grid == null) return;

    final oldSet = oldKeys.toSet();
    final newSet = newKeys.toSet();
    final insertions = <int>[];
    final removals = <int>[];
    for (var i = 0; i < newKeys.length; i++) {
      if (!oldSet.contains(newKeys[i])) insertions.add(i);
    }
    for (var i = 0; i < oldKeys.length; i++) {
      if (!newSet.contains(oldKeys[i])) removals.add(i);
    }
    if (insertions.isEmpty && removals.isEmpty) return;

    // Resolve the anchor — the first item at or beyond the viewport's
    // leading edge that survives into the new list — before mutating.
    final scrollPosition = _scrollController.hasClients ? _scrollController.position : null;
    var anchorIndex = -1;
    var lastRow = -1;
    var leadingIndex = -1;
    if (scrollPosition != null && scrollPosition.hasPixels && scrollPosition.hasContentDimensions) {
      final stop = _currentStop;
      final maxRow = math.max(0, stop.rowCount(oldKeys.length) - 1);
      // rowAtY·columns is a SLOT — the first item of that row sits phase
      // slots later (or the row is all holes at the grid's head).
      leadingIndex = math.max(
        0,
        stop.rowAtY(scrollPosition.pixels, _gridOrigin).clamp(0, maxRow) * stop.columns - stop.phase,
      );
      lastRow = stop.rowAtY(scrollPosition.pixels + scrollPosition.viewportDimension, _gridOrigin);
      for (var i = leadingIndex; i < oldKeys.length; i++) {
        if (_indexByKey.containsKey(oldKeys[i])) {
          anchorIndex = i;
          break;
        }
      }
    }
    // Removals before the anchor collapse instantly even when they are
    // still inside the window: an animating slot keeps displacing the
    // anchor across the animation while the one-shot correction below
    // assumes final geometry, and the residual drift reads as a jump.
    // Removals strictly past the anchor never displace it, so only those
    // keep animating — the fold is visible feedback where it happens.
    final anchorNewIndex = anchorIndex >= 0 ? _indexByKey[oldKeys[anchorIndex]] : null;
    final instantRemovals = <int>{};
    for (final index in removals) {
      if (anchorIndex < 0 || index < anchorIndex || _currentStop.rowOf(index) > lastRow) {
        instantRemovals.add(index);
      }
    }
    // Insertions obey the same rule: a slot animating open at-or-before the
    // anchor pushes it down progressively over the animation, while the
    // hold below already corrected to the final geometry — the anchor
    // visibly drifts. Past the last visible row nothing can be seen either.
    final instantInsertions = <int>{};
    for (final index in insertions) {
      if (anchorNewIndex == null || index <= anchorNewIndex || _currentStop.rowOf(index) > lastRow) {
        instantInsertions.add(index);
      }
    }
    // While an external actor owns the position (a seek landing), the whole
    // visible window is being swapped to different content — no insert or
    // removal animation can read as meaningful there; they stagger in under
    // the teleported viewport and present as pop-in. Resolve everything at
    // final geometry for this commit.
    final atomicSwap = !widget.holdScrollAnchor;
    widget.debugLog?.call(
      'grid:diff +${insertions.length} -${removals.length} '
      'instant=${instantRemovals.length}/${instantInsertions.length} '
      'atomic=$atomicSwap '
      'anchor=$anchorIndex lead=$leadingIndex '
      'px=${scrollPosition?.pixels.toStringAsFixed(0) ?? '-'}',
    );
    _holdLeadingRow(oldKeys, anchorIndex);

    // Removal positions are the doomed child's CURRENT slot — under a
    // mirrored layout that is not `index + phase` (runs flip inside their
    // rows). Process in descending slot order so each positional removal
    // leaves the lower slots it still points at untouched.
    final diffStop = _currentStop;
    final removalOrder = [...removals]
      ..sort((a, b) => diffStop.slotOf(b, oldKeys.length).compareTo(diffStop.slotOf(a, oldKeys.length)));
    for (final index in removalOrder) {
      final isTailEviction = insertions.isNotEmpty && index == oldKeys.length - 1;
      grid.removeItem(
        diffStop.slotOf(index, oldKeys.length),
        (context, animation) =>
            widget.removedItemBuilder?.call(context, index, animation) ??
            FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: const SizedBox.expand()),
            ),
        duration: atomicSwap || isTailEviction || instantRemovals.contains(index)
            ? Duration.zero
            : widget.changeAnimationDuration,
      );
    }
    // Appends land below the viewport — animating a whole page is jank.
    final isPureAppend = removals.isEmpty && insertions.first >= oldKeys.length;
    // Insert positions are the item's slot in the FINAL list — the same
    // approximation `index + phase` made, generalised to the mirrored
    // mapping (the evolving child list is only slot-accurate for inserts
    // processed in ascending slot order).
    final insertionOrder = [...insertions]
      ..sort((a, b) => diffStop.slotOf(a, newKeys.length).compareTo(diffStop.slotOf(b, newKeys.length)));
    var modelLength = oldKeys.length - removals.length + _phase;
    for (final index in insertionOrder) {
      grid.insertItem(
        diffStop.slotOf(index, newKeys.length).clamp(0, modelLength),
        // Real tiles animate through the itemBuilder's FadeTransition — a
        // nonzero duration would paint them translucent until the first
        // tick, so instant inserts keep Duration.zero. The _incomingItems
        // race can't reach them: same-task removes only ever target the
        // leading hole slots (_applyPhase), whose inserts run through
        // _kInstantInsertDuration.
        duration: atomicSwap || isPureAppend || instantInsertions.contains(index)
            ? Duration.zero
            : widget.changeAnimationDuration,
      );
      modelLength++;
    }

    if (_morphActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _retargetSettle());
    }
  }

  /// Scroll-space compensation for keyed children relocating. A keyed
  /// insert — or an instantly-collapsed removal — before the visible window
  /// shifts every later item to a different index — RenderSliverGrid
  /// (unlike RenderSliverList) reports no `scrollOffsetCorrection` for the
  /// move, so `pixels` stays put and the visible rows teleport by the
  /// displaced extent. Keep the leading row where it was: [_syncGrid]
  /// resolves the first surviving item at or beyond the viewport's
  /// leading edge (the anchor) and hands its old index here; the offset
  /// corrects by that item's row-top delta — inside the same build pass
  /// that issued the changes, before layout, so the shift never paints.
  ///
  /// Every removal before the anchor resolves instantly (see
  /// [_syncGrid]), so the layout's final geometry is already what this
  /// one-shot correction computes — the anchor's row-top delta is exact.
  ///
  /// Skipped while a morph owns the focal geometry and while parked at the
  /// leading edge itself (arriving items should visibly enter there).
  void _holdLeadingRow(List<Object?> oldKeys, int anchorIndex) {
    if (_morphActive || anchorIndex < 0 || oldKeys.isEmpty || !_scrollController.hasClients) {
      return;
    }
    if (!widget.holdScrollAnchor) {
      widget.debugLog?.call('grid:hold skip=external anchor=$anchorIndex');
      return;
    }
    final position = _scrollController.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    if (position.pixels <= position.minScrollExtent) {
      widget.debugLog?.call('grid:hold skip=parked anchor=$anchorIndex');
      return;
    }
    final stop = _currentStop;
    final newIndex = _indexByKey[oldKeys[anchorIndex]];
    if (newIndex == null) {
      widget.debugLog?.call('grid:hold skip=evicted anchor=$anchorIndex');
      return;
    }
    final delta = stop.rowTop(stop.rowOf(newIndex), _gridOrigin) - stop.rowTop(stop.rowOf(anchorIndex), _gridOrigin);
    // Never write past the post-diff extents: when a merge shrinks the
    // list, an unclamped correction leaves px > the new maxScrollExtent and
    // the next layout creeps the overshoot back ballistically — a slow
    // visible slide. The live max is still pre-layout, so project the
    // grid's own extent delta onto it — the live max already carries the
    // header/footer extent rowTop can't see; clamping to a bare grid-end
    // projection systematically under-shoots by that extent and slips the
    // anchor every merge near the end.
    final projectedMax = math.max(
      0.0,
      position.maxScrollExtent +
          stop.rowTop(stop.rowCount(widget.itemCount), _gridOrigin) -
          stop.rowTop(stop.rowCount(oldKeys.length), _gridOrigin),
    );
    final applied = (position.pixels + delta).clamp(position.minScrollExtent, projectedMax) - position.pixels;
    if (applied.abs() > precisionErrorTolerance) {
      position.correctBy(applied);
      _updateScrollOffset();
      widget.debugLog?.call(
        'grid:hold anchor=$anchorIndex delta=${applied.toStringAsFixed(1)} raw=${delta.toStringAsFixed(1)}',
      );
    } else {
      widget.debugLog?.call('grid:hold anchor=$anchorIndex delta=0 raw=${delta.toStringAsFixed(1)}');
    }
  }

  void _handleScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.pixels >= metrics.maxScrollExtent - widget.nearEndExtent) {
      widget.onNearEnd?.call();
    }

    if (notification is UserScrollNotification) {
      _lastDirection = switch (notification.direction) {
        ScrollDirection.forward => -1,
        ScrollDirection.reverse => 1,
        ScrollDirection.idle => _lastDirection,
      };
    }

    if (notification is ScrollUpdateNotification || notification is UserScrollNotification) {
      _fireAnchor(direction: _lastDirection);
    }
  }

  /// Reports the topmost scrolled row's first item — the anchor a
  /// thumbnail prefetcher loads around — whenever it or the scroll
  /// direction changes.
  void _fireAnchor({required int direction}) {
    final callback = widget.onVisibleAnchorChanged;
    if (callback == null || widget.itemCount == 0 || !_scrollController.hasClients) {
      return;
    }
    final stop = _currentStop;
    // The topmost visible row — under reverse that's the scroll-space
    // extent near pixels + viewportHeight, not pixels itself.
    final anchorY = widget.reverse
        ? _scrollController.position.pixels + _viewportHeight
        : _scrollController.position.pixels;
    final row = math.max(0, stop.rowAtY(anchorY, _gridOrigin));
    final anchor = math.min(widget.itemCount - 1, math.max(0, row * stop.columns - stop.phase));
    if (anchor == _lastAnchorIndex && direction == _lastDirection) return;
    _lastAnchorIndex = anchor;
    callback(anchor, direction, stop.tileWidth.ceil());
  }
}

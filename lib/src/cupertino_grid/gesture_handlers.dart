part of '../cupertino_grid.dart';

/// Gesture → morph choreography: the two-finger recognizer's callbacks,
/// morph activation, the settle spring's tick and the density commit.
/// An extension so [_CupertinoGridState]'s build tree stays readable
/// without widening the public surface.
extension _GestureHandlers on _CupertinoGridState {
  void _onScaleStart(_PinchStartDetails details) {
    final itemCount = widget.itemCount;
    if (itemCount == 0 || _pinching) return;
    // A pinch landing mid-settle/mid-fade must not be ignored — between
    // the release spring (~300 ms) and the overlay fade (140 ms) that was
    // ~600 ms of dead gestures after every zoom. The morph is
    // interruptible: finalize the pending commit instantly, then begin
    // the new pinch from the settled grid.
    if (_morphActive) {
      _finishMorphEarly();
    } else if (_settle.isAnimating) {
      // A no-op pinch (level never left the start stop — e.g. pinching
      // out at the densest grid) still launched a settle whose post-frame
      // commit would land under the new gesture; cancel it outright.
      _settle.stop();
      _morphEpoch++;
    }

    final focal = _toLocal(details.focalPoint, details.localFocalPoint);
    _measureGridOrigin();
    if (_scrollController.hasClients) _scrollController.position.hold(() {});

    final stops = _buildLadder();
    final current = _currentStop;
    final start = math.max(0, stops.indexWhere((stop) => stop.columns == current.columns));
    final scroll = _currentScrollOffset;
    final origin = _gridOrigin;
    // Screen↔scroll: normal screenY = scrollY − scroll; reversed
    // screenY = viewport.height + scroll − scrollY.
    int indexAtPoint(Offset local) => widget.reverse
        ? stops[start].indexAt(Offset(local.dx, scroll + _viewportHeight - local.dy), itemCount, origin)
        : stops[start].indexAt(local + Offset(0, scroll), itemCount, origin);
    // Intent beats geometry: a finger's position pins the tile it covers
    // (content tracks a dragged finger), so when both fingers cover the
    // same tile it is unambiguously the target. When they straddle and
    // the midpoint lands on a tile one of them covers, the FIRST touch
    // decides — not whichever tile the noisy midpoint fell into. A
    // midpoint landing on a tile neither finger covers means the fingers
    // deliberately bracketed it, so midpoint semantics win there.
    final perFinger = [for (final p in details.pointerPositions) indexAtPoint(_toLocal(p, p))];
    final fingerTiles = perFinger.toSet();
    final midIndex = indexAtPoint(focal);
    final focalIndex = fingerTiles.length == 1
        ? perFinger.first
        : (fingerTiles.contains(midIndex) ? perFinger.first : midIndex);
    _focalAnchorKey = _anchorKeyOf(focalIndex);
    _focalItemKey = _keyOf(focalIndex);
    final rawFocalRect = stops[start].tileRect(focalIndex, origin, itemCount);
    final focalRect = widget.reverse
        ? Rect.fromLTRB(
            rawFocalRect.left,
            _viewportHeight + scroll - rawFocalRect.bottom,
            rawFocalRect.right,
            _viewportHeight + scroll - rawFocalRect.top,
          )
        : rawFocalRect.shift(Offset(0, -scroll));

    final (minScroll, trailing) = _scrollMetrics(itemCount, current);

    _morph.begin(
      stops: stops,
      startStop: start,
      focalIndex: focalIndex,
      focalFraction: Offset(
        (focal.dx - focalRect.left) / focalRect.width,
        (focal.dy - focalRect.top) / focalRect.height,
      ),
      focalPoint: focal,
      startScroll: scroll,
      minScroll: minScroll,
      trailing: trailing,
      coverageLeading: widget.morphCoverageLeading,
      itemCount: itemCount,
      origin: origin,
      headerOrigin: _headerOrigin,
      viewport: Size(_viewportWidth, _viewportHeight),
      reversed: widget.reverse,
      // A phase stamped for a density the grid hasn't committed yet can
      // exceed the start stop's column count — clamp rather than throw.
      phase: _phase.clamp(0, stops[start].columns - 1),
      centerFocal: widget.centerFocalOnCommit,
    );
    _pinchBaseLogTile = _morph.logTileWidthAt(start.toDouble());
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _levelVelocity = 0;
    _rawOverscale = 1;
    _lastUpdateLevel = _morph.level;
    _lastUpdateStamp = 0;
    _lastUpdateWall = 0;
    _pinching = true;
    // A new gesture lands on a firm surface — the previous bounce's
    // rebound has no place in the fresh frame.
    if (_edgeSqueeze.value != 1) {
      _edgeSqueeze
        ..stop()
        ..value = 1;
    }
    // The morph itself stays dormant until the pinch actually moves the
    // level — a pinch clamped to the current stop (e.g. zooming out while
    // already densest) renders exactly the resting grid, so mounting the
    // overlay would only fire thumbnail loads and flash placeholders.
  }

  /// Viewport size changed while the morph engine holds stamped geometry —
  /// the ladder's tile widths, the mirrored focal point, and the rest
  /// scrolls all derive from the old extent. Re-stamp them from the freshly
  /// measured metrics so frames and the commit stay continuous instead of
  /// snapping on release.
  void _reframeMorph() {
    if (!_morphActive && !_settle.isAnimating) return;
    final stops = _buildLadder();
    final current = _currentStop;
    final (minScroll, trailing) = _scrollMetrics(widget.itemCount, current);
    _morph.reframe(
      viewport: Size(_viewportWidth, _viewportHeight),
      stops: stops,
      minScroll: minScroll,
      trailing: trailing,
      coverageLeading: widget.morphCoverageLeading,
    );
    // Ladder indices may have moved with the new ladder — re-aim an
    // in-flight settle at the remapped target from the remapped level.
    if (_settle.isAnimating) {
      _settleFromLevel = _morph.level;
      _settleTarget = _morph.settleStop;
    }
  }

  /// First pinch movement that changes the level: mount the overlay, seed
  /// its child slots from the current frame and warm every reachable stop.
  /// The render object requests anything else it needs as the lattice slides.
  void _activateMorph() {
    _rebuild(() {
      _morphActive = true;
      final frame = _morph.frame(_sectionStartSet().contains);
      _overlayTiles.clear();
      // A host without a decoded-image path paints tiles through mounted
      // children — pre-mount the window so the first frames have content.
      // With overlayImageFor a child is only the persistent-miss fallback
      // (onSlotsNeeded, streak-gated in the render object): mounting the
      // whole window up front is the gesture's biggest single-frame cost.
      if (widget.overlayImageFor == null) {
        _overlayTiles.addAll(frame.tiles.map((tile) => tile.index));
      }
      _overlayPills
        ..clear()
        ..addAll(frame.pills.map((pill) => (pill.layer, pill.index)));
      _overlayTileSizes
        ..clear()
        ..addAll({for (final tile in frame.tiles) tile.index: tile.targetSize});
      _overlayTileSize = _morph.stops.fold(0, (m, stop) => math.max(m, stop.tileWidth.ceil()));
    });
    // Only the neighbouring stops — every reachable stop's screen queued at
    // once is hundreds of platform fetches that keep decoding for seconds
    // after the gesture ends. The settle stop is warmed on release.
    _warmStops([_morph.startStop - 1, _morph.startStop + 1]);
  }

  /// The overlay render object reports slots it wants children for — mount
  /// them so the next layout picks them up.
  void _onOverlaySlotsNeeded(Set<int> tileIndices, Set<(int, int)> pillSlots) {
    if (!mounted || !_morphActive) return;
    _rebuild(() {
      _overlayTiles.addAll(tileIndices);
      // Keep a mounted slot's first size — the same index flips between
      // under/over roles at the two stops' sizes, and a changed targetSize
      // reloads the child's thumbnail cubit (gray ↔ blur flicker).
      for (final tile in _morph.frame(_sectionStartSet().contains).tiles) {
        _overlayTileSizes.putIfAbsent(tile.index, () => tile.targetSize);
      }
      _overlayPills.addAll(pillSlots);
    });
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_pinching) return;
    // Only the pinch spread drives the morph — moving both fingers together
    // does not pan it.
    final raw = _pinchBaseLogTile + math.log(math.max(details.scale, 1e-3));
    var (level, overscale) = _morph.levelForLogTile(raw);
    _rawOverscale = overscale;
    // Interleaved per-finger move events jitter the raw span by sub-pixel
    // amounts — invisible on the cell-size curve, but inside the reflow
    // window it lands on a ~15× slope and the lattice visibly lurches a
    // few pixels at random. The engine low-passes the level on the event
    // clock, stripping the shimmer while deliberate travel feels instant.
    final stamp = details.sourceTimeStamp?.inMicroseconds ?? 0;
    _morph.trackLevel(
      level,
      dtSeconds: stamp != 0 && _lastUpdateStamp != 0 && stamp != _lastUpdateStamp
          ? (stamp - _lastUpdateStamp).abs() / Duration.microsecondsPerSecond
          : null,
    );
    final refractory = DateTime.now().isBefore(_refractoryUntil);
    // Largest-tile end: the morph overscale already stretches cells, so the
    // refractory gate only needs to hold it at 1.
    if (overscale > 1 && refractory && _refractoryEdge == -1) overscale = 1;
    // Densest end: resolve() clamps to the floor — the elastic feedback
    // rides on the scroll view transform instead of the morph overlay, so
    // an edge bounce never pays for overlay tiles or thumbnail fetches.
    final densestLog = _morph.stops.isEmpty ? 0.0 : _morph.logTileWidth(_morph.stops.length - 1);
    if (raw < densestLog && !_reduceMotion) {
      final squeeze = refractory && _refractoryEdge == 1
          ? 1.0
          : math.exp(-(densestLog - raw) * widget.style.edgeSqueezeGain).clamp(widget.style.minEdgeSqueeze, 1.0);
      _edgeFocal = _toLocal(details.focalPoint, details.localFocalPoint);
      _edgeSqueeze
        ..stop()
        ..value = squeeze;
    } else if (_edgeSqueeze.value != 1) {
      // Back inside the ladder without releasing — the squeeze releases
      // instantly; the spring is only for the finger-up rebound.
      _edgeSqueeze
        ..stop()
        ..value = 1;
    }
    _morph.set(overscale: _reduceMotion ? 1 : overscale);
    // Flick estimate for the release commit — event-clock deltas, so
    // dropped frames and paused fingers don't inflate the sample. Tracks
    // the RAW level: momentum intent, not the low-passed display.
    if (stamp != 0 && _lastUpdateStamp != 0) {
      final dt = (stamp - _lastUpdateStamp) / Duration.microsecondsPerSecond;
      if (dt > 0.004 && dt < 0.2) {
        _levelVelocity = _levelVelocity * 0.55 + ((level - _lastUpdateLevel) / dt).clamp(-20.0, 20.0) * 0.45;
      }
    }
    if (stamp != 0) _lastUpdateStamp = stamp;
    _lastUpdateLevel = level;
    _lastUpdateWall = DateTime.now().microsecondsSinceEpoch;
    // Reduce-motion pinches never mount the overlay: the lattice stays at
    // rest while the level tracks silently, and the release snaps the grid
    // straight to the committed stop.
    if (!_reduceMotion && !_morphActive && (_morph.level != _morph.startStop || overscale != 1)) {
      _activateMorph();
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (!_pinching) return;
    _pinching = false;
    // The commit decision reads the raw level (gesture intent); the
    // displayed, low-passed level is where the settle starts from so the
    // glide stays continuous with what was on screen.
    final level = _lastUpdateLevel;
    final lower = level.floor();
    final fraction = level - lower;
    // Held-still releases discard the stale flick estimate.
    final velocity =
        DateTime.now().microsecondsSinceEpoch - _lastUpdateWall < widget.style.flickStaleDuration.inMicroseconds
        ? _levelVelocity
        : 0.0;
    // Momentum carries only in the direction the gesture actually
    // travelled: the lift-off wobble — the spread springing back a few
    // pixels as the fingers come up — otherwise reads as a reverse flick
    // and bounces a mostly-travelled transition back to the start stop.
    final travel = level - _morph.startStop;
    final int target;
    if (fraction < 1e-4) {
      target = lower;
    } else if (travel > 0 && velocity > widget.style.flickVelocity) {
      target = fraction > widget.style.commitThreshold ? lower + 1 : lower;
    } else if (travel < 0 && velocity < -widget.style.flickVelocity) {
      target = fraction < 1 - widget.style.commitThreshold ? lower : lower + 1;
    } else {
      // Slow release, or a flick against the travel direction — land on
      // the nearer stop.
      target = fraction < 0.5 ? lower : lower + 1;
    }
    final settleStop = target.clamp(0, _morph.stops.length - 1);
    _warmStops([settleStop]);
    _morph.settleStop = settleStop;
    _settleTarget = settleStop;
    // Commit the density up front: a parent's rebuild can reshape the cell
    // list (stack fold/unfold) — landing it during the settle lets the
    // glide re-anchor onto the surviving cell before the reveal instead
    // of handing the fade a lattice computed on the stale index.
    final settleColumns = _morph.stops[settleStop].columns;
    if (settleColumns != _effectiveColumns) {
      if (widget.columns == null) {
        _rebuild(() => _internalColumns = settleColumns);
      }
      widget.onColumnsChanged?.call(settleColumns);
      // The pinch commits to a new density — iOS Photos ticks here.
      unawaited(HapticFeedback.selectionClick());
    }
    // A reshape that landed mid-gesture (its _syncGrid ran while _pinching
    // suppressed _retargetSettle) may already have moved the pinched item —
    // re-resolve now so the phase below maps the resolved index, not the
    // stale one.
    final overscaleFocal = _syncFocalIndex();
    // The settle lands on this stop's centred phase — shift the leading
    // slots now so the grid reveals exactly what the overlay glides to.
    // A controlled parent may still own the old columns: the stamp is
    // held until the density lands rather than thrown on.
    _applyPhase(_morph.stops[settleStop].phase, forColumns: settleColumns);
    // Released while stretched past the largest tile beyond the commit
    // threshold — the "keep zooming at the last zoom" gesture. The settle
    // still lands the largest stop; the host decides what to open for the
    // pinched item and flies it from the emitted rect.
    if (settleStop == 0 && _rawOverscale >= widget.style.overscaleCommitThreshold) {
      final launch = _launchFocal(overscaleFocal);
      widget.onOverscaleCommit?.call(
        OverscaleCommit(index: overscaleFocal, rect: launch.$1, overscale: _rawOverscale, targetSize: launch.$2),
      );
    }
    _settleFromLevel = _morph.level;
    _settleFromLogOverscale = math.log(_morph.overscale);
    _settleFromPin = 1;
    // Stamped before `_settle.value = 0` below — that assignment notifies
    // listeners synchronously, and a stale stamp would make the stall
    // guard relaunch inside the launch itself.
    _settleTickWall = DateTime.now();
    _lastSettleProgress = 0;
    _settleRelaunches = 0;
    // Test bindings drive frames manually — pumped time must advance the
    // spring however coarsely the harness asks, and slow pump/compare
    // cycles would trip a wall-gap guard. Detect them by binding type so
    // the guard only runs on real vsync-driven settles.
    _settleFakeTime = WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding');
    // A release while rubber-banded arms that edge's refractory window —
    // the next pinch within it meets a hard stop, not a second bounce.
    if (_edgeSqueeze.value != 1 || _morph.overscale != 1) {
      _refractoryEdge = _edgeSqueeze.value != 1 ? 1 : -1;
      _refractoryUntil = DateTime.now().add(widget.style.edgeRefractory);
    }
    if (_edgeSqueeze.value != 1) {
      unawaited(
        _edgeSqueeze
            .animateWith(SpringSimulation(widget.style.settleSpring, _edgeSqueeze.value, 1, 0))
            .then((_) {}, onError: (_) {}),
      );
    }
    _settle.value = 0;
    // Reduce motion: same commit, zero travel — the instant-finalize path
    // lands the density, jump and teardown with no spring or fade.
    if (_reduceMotion) {
      _finishMorphEarly();
      return;
    }
    // Preserve release momentum in the normalized settle coordinate. The
    // spring animates 0→1 regardless of how far the level must travel, so
    // convert stops/second into progress/second and keep only velocity
    // directed toward the selected stop. A modest cap prevents a very short
    // gesture sample from launching the overlay past its landing frame.
    final settleDistance = settleStop.toDouble() - _settleFromLevel;
    final settleVelocity = settleDistance.abs() < 1e-6 ? 0.0 : (velocity / settleDistance).clamp(0.0, 4.0).toDouble();
    final epoch = _morphEpoch;
    // A completed spring's TickerFuture resolves before _onSettleTick's stall
    // guard can relaunch — the .then below is already scheduled. Gating the
    // commit on the run id lets the guard supersede it: only the last settle
    // run commits, so a replayed glide can't re-animate a committed morph.
    final settleRun = _settleRelaunches;
    unawaited(
      _settle.animateWith(SpringSimulation(widget.style.settleSpring, 0, 1, settleVelocity)).then(
        (_) {
          if (mounted && epoch == _morphEpoch && settleRun == _settleRelaunches) _commitMorph(settleStop);
        },
        // stop() on interrupt/dispose completes the future with
        // TickerCanceled — expected, not an error to report.
        onError: (_) {},
      ),
    );
  }

  void _onSettleTick() {
    final now = DateTime.now();
    final lastWall = _settleTickWall;
    _settleTickWall = now;
    // The spring is clock-driven: a UI-thread stall between ticks lands as
    // one giant value step — the whole remaining glide snaps in a frame,
    // even when the jump lands the spring at p=1. The discriminator is the
    // jump, not the value: a legitimately-ending spring arrives in small
    // final steps, a stalled one carries a quarter+ of the travel at once.
    // Relaunch from the frozen pose so the travel replays. Never under a
    // test binding — pumped gaps there are the harness's intent.
    if (!_settleFakeTime && lastWall != null) {
      final wallGap = now.difference(lastWall);
      final jump = _settle.value - _lastSettleProgress;
      if (wallGap > const Duration(milliseconds: 50) && jump > 0.25 && _settleRelaunches < 3) {
        _relaunchSettle();
        return;
      }
    }
    final progress = _settle.value.clamp(0.0, 1.0);
    _lastSettleProgress = progress;
    _morph.set(
      level: _settleFromLevel + (_settleTarget - _settleFromLevel) * progress,
      overscale: math.exp(_settleFromLogOverscale * (1 - progress)),
      pin: _settleFromPin * (1 - progress),
    );
  }

  /// Re-anchors the settle spring on the pose the UI-thread stall froze
  /// at: `from` fields capture the live morph values so progress 0 maps to
  /// exactly what was on screen — the remaining distance then animates
  /// over real frames instead of arriving as one jump.
  void _relaunchSettle() {
    _settleRelaunches++;
    _settleFromLevel = _morph.level;
    _settleFromLogOverscale = math.log(_morph.overscale);
    _settleFromPin = _morph.pin;
    _settle.stop();
    _settle.value = 0;
    final epoch = _morphEpoch;
    final settleRun = _settleRelaunches;
    unawaited(
      _settle.animateWith(SpringSimulation(widget.style.settleSpring, 0, 1, 0)).then(
        (_) {
          if (mounted && epoch == _morphEpoch && settleRun == _settleRelaunches) _commitMorph(_settleTarget);
        },
        // stop() on interrupt/dispose completes the future with
        // TickerCanceled — expected, not an error to report.
        onError: (_) {},
      ),
    );
  }

  /// Switches the real grid to the settled stop and jumps it under the
  /// overlay — whose frame is now exactly that stop's rest layout — then
  /// fades the overlay out, giving the grid's tiles a beat to pick up the
  /// thumbnails the overlay already loaded at the same size.
  void _commitMorph(int stopIndex) {
    final stop = _morph.stops[stopIndex];
    final scroll = _morph.restScrolls[stopIndex];
    _morph.set(level: stopIndex.toDouble(), overscale: 1, pin: 0);
    // Density already committed when the settle began — this only fires
    // when a controlled parent did not adopt it then.
    if (stop.columns != _effectiveColumns) {
      if (widget.columns == null) {
        _rebuild(() => _internalColumns = stop.columns);
      }
      widget.onColumnsChanged?.call(stop.columns);
    }
    _lastValidScrollOffset = scroll;
    final epoch = _morphEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A new pinch may have finalized this morph before the frame ran —
      // the epoch check keeps the stale jump + fade from clobbering it.
      if (!mounted || epoch != _morphEpoch) return;
      // Resolved here, after the rebuild the column change may have
      // triggered: the committed item list can differ from the one the
      // pinch started on (stack fold/unfold, merges), so the focal item's
      // index is re-resolved through its anchor key — a jump computed on
      // the stale index centered a different cell entirely.
      _jumpToClamped(_commitScroll(stopIndex));
      unawaited(
        _overlayFade.forward(from: 0).then((_) {
          if (!mounted || epoch != _morphEpoch) return;
          _rebuild(() {
            _morphActive = false;
            _overlayTiles.clear();
            _overlayTileSizes.clear();
            _overlayPills.clear();
          });
          _overlayFade.value = 0;
          // The committed stop requests a different tile size — re-fire the
          // anchor even though the anchor item didn't move.
          _lastAnchorIndex = -1;
          _fireAnchor(direction: _lastDirection);
        }, onError: (_) {}),
      );
    });
  }

  /// Interrupt path for [_onScaleStart]: a new pinch landed while the
  /// settle spring or the overlay fade was still running. Both stop where
  /// they are; the settle target's commit lands synchronously (its density
  /// was already applied when the settle began — only the scroll jump and
  /// overlay teardown remain), and control falls through so the new pinch
  /// begins from the settled grid.
  void _finishMorphEarly() {
    _morphEpoch++;
    _settle.stop();
    _overlayFade
      ..stop()
      ..value = 0;
    _morph.set(level: _settleTarget.toDouble(), overscale: 1, pin: 0);
    _lastValidScrollOffset = _commitScroll(_settleTarget);
    _jumpToClamped(_lastValidScrollOffset);
    _rebuild(() {
      _morphActive = false;
      _overlayTiles.clear();
      _overlayTileSizes.clear();
      _overlayPills.clear();
    });
    _lastAnchorIndex = -1;
    _fireAnchor(direction: _lastDirection);
  }

  /// The pinched cell's painted rect in GLOBAL screen coordinates at
  /// release plus the decode-size hint it was painted at — the launch
  /// pose and content key a detail viewer's shared-element flight starts
  /// from. While the overlay is mounted both come from slot (0,0)'s
  /// emitted tile; under reduce motion (no overscaled frame ever painted)
  /// the resting grid cell and its stop's tile width stand in, the last
  /// pose actually shown.
  (Rect, int) _launchFocal(int index) {
    Rect? local;
    var targetSize = _morph.stops[_morph.startStop].tileWidth.ceil();
    if (_morphActive) {
      for (final tile in _morph.frame(_sectionStartSet().contains).tiles) {
        if (tile.columnOffset == 0 && tile.rowOffset == 0) {
          local = tile.rect;
          targetSize = tile.targetSize;
          break;
        }
      }
    }
    if (local == null) {
      final scroll = _currentScrollOffset;
      final raw = _morph.stops[_morph.startStop].tileRect(index, _gridOrigin, widget.itemCount);
      local = widget.reverse
          ? Rect.fromLTRB(
              raw.left,
              _viewportHeight + scroll - raw.bottom,
              raw.right,
              _viewportHeight + scroll - raw.top,
            )
          : raw.shift(Offset(0, -scroll));
    }
    final box = context.findRenderObject();
    return (box is RenderBox ? local.shift(box.localToGlobal(Offset.zero)) : local, targetSize);
  }

  /// Index the pinched cell occupies in the CURRENT item list: the pinched
  /// item itself when it survives the commit's reshape, otherwise the
  /// first cell sharing its group anchor — the stack header that folded
  /// it away, which precedes its members and survives a collapse.
  int _resolveFocalIndex() {
    final itemKey = _focalItemKey;
    if (itemKey != null) {
      final resolved = _indexByKey[itemKey];
      if (resolved != null) return resolved;
    }
    final anchorKey = _focalAnchorKey;
    if (anchorKey != null && widget.itemAnchorKey != null) {
      for (var i = 0; i < widget.itemCount; i++) {
        if (_anchorKeyOf(i) == anchorKey) return i;
      }
    } else if (anchorKey != null) {
      return _indexByKey[anchorKey] ?? _morph.focalIndex;
    }
    return _morph.focalIndex;
  }

  /// Re-resolves the pinched item against the CURRENT cell list and
  /// re-stamps the settle stop's landing phase for it — the phase was
  /// computed at pinch start for the index the item held then, so a
  /// reshape that shifted it (stack fold/unfold, a merge inserting cells
  /// before it) leaves every destination stamped stale.
  ///
  /// The rephase is unconditional, not index-diffed: a reshape landing
  /// BEFORE release re-resolves the index while [PinchMorph.settleStop]
  /// still sits on the start stop — rephaseLanding's no-op case — so
  /// once release picks the destination the index no longer differs and
  /// a diff guard would never repair the phase. A tail-only itemCount
  /// change reclamps the target the same way. [rephaseLanding] re-derives
  /// the identical phase for an unmoved index and [_applyPhase] early-outs
  /// on a zero delta, so a sync where nothing moved costs nothing.
  int _syncFocalIndex() {
    final index = _resolveFocalIndex().clamp(0, math.max(0, widget.itemCount - 1)).toInt();
    _morph.focalIndex = index;
    _morph.rephaseLanding(index);
    _applyPhase(_morph.stops[_morph.settleStop].phase, forColumns: _morph.stops[_morph.settleStop].columns);
    return index;
  }

  /// The footer sliver's own height — the content tail below the grid.
  /// Read from the render object so a grid that FITS the viewport (no
  /// scroll extent to derive it from) still reserves the chrome a
  /// scrollable destination needs below its last row.
  double get _footerExtent {
    final box = _footerSliverKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : 0.0;
  }

  /// The scroll bounds the morph's clamps need: the real min extent, and
  /// the content tail below the grid (footer chrome keeps its extent at
  /// every density). The extent formula only sees the tail while the
  /// content overflows the viewport; a fitting grid takes the footer's
  /// measured height instead.
  (double, double) _scrollMetrics(int itemCount, MorphGridStop stop) {
    var minScroll = 0.0;
    var trailing = 0.0;
    if (_scrollController.hasClients && _scrollController.position.hasContentDimensions) {
      final position = _scrollController.position;
      minScroll = position.minScrollExtent;
      if (position.maxScrollExtent > position.minScrollExtent) {
        trailing = math.max(
          0.0,
          position.maxScrollExtent + position.viewportDimension - stop.rowTop(stop.rowCount(itemCount), _gridOrigin),
        );
      }
    }
    return (minScroll, trailing == 0 ? _footerExtent : trailing);
  }

  /// Scroll offset that puts the pinched item's anchor under the finger at
  /// [stopIndex]'s stop — [PinchMorph.restScrollFor] re-measured against
  /// the CURRENT item list. [PinchMorph.restScrolls] was captured at
  /// pinch start; when nothing reshaped the two agree. The write keeps
  /// the map on the scroll the commit actually lands — and shares
  /// begin()'s clamp, so an out-of-range edge focal can't shift the
  /// target after the overlay already emitted the clamped rest frame.
  double _commitScroll(int stopIndex) {
    final index = _syncFocalIndex();
    final rest = _morph.restScrolls[stopIndex] = _morph.restScrollFor(
      stopIndex,
      itemIndex: index,
      itemCount: widget.itemCount,
    );
    // The re-resolve can re-stamp the settle stop's landing phase and the
    // write above can move the rest scroll — plain field mutations that
    // don't notify on their own. Re-emit the committed lattice or the
    // fade paints the overlay's last, pre-mutation frame over the jumped,
    // rephased grid.
    _morph.set();
    return rest;
  }

  /// A mid-morph reshape (stack fold on commit, merge) invalidated the
  /// rest position the settle is gliding towards — re-resolve the focal
  /// item and bend the glide onto the anchor's new rest slot, so the
  /// overlay's last frame is exactly where the grid lands.
  ///
  /// Only while the glide is actually in flight: [_morphActive] stays true
  /// through the overlay fade, but after the commit lands there is no
  /// glide left to bend — the grid already jumped to the emitted rest.
  /// Re-aiming then shifts the overlay's lattice off the landed grid
  /// mid-fade (the post-landing ghost). A reshape arriving between the
  /// settle's end and the commit is picked up by [_commitScroll]'s
  /// [_syncFocalIndex] instead.
  void _retargetSettle() {
    if (!mounted || !_morphActive || _pinching || !_settle.isAnimating) {
      return;
    }
    final index = _syncFocalIndex();
    final rest = _morph.restScrollFor(_morph.settleStop, itemIndex: index, itemCount: widget.itemCount);
    if ((rest - _morph.restScrolls[_morph.settleStop]).abs() >= 0.5) {
      _morph.restScrolls[_morph.settleStop] = rest;
    }
    // _syncFocalIndex can re-stamp the settle stop's phase even when the
    // rest target didn't move — the emitted lattice changed either way.
    _morph.set();
  }

  /// Reports each reachable stop's visible range at that stop's own tile
  /// size — the size its overlay layer and, after commit, the real grid
  /// request, so neither waits on a reload.
  void _warmStops(Iterable<int> stopIndices) {
    final warm = widget.onWarmRange;
    if (warm == null || widget.itemCount == 0) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    for (final k in stopIndices) {
      if (k < 0 || k >= _morph.stops.length) continue;
      final stop = _morph.stops[k];
      final scroll = _morph.restScrolls[k];
      // Slots → items: subtract the stop's leading phase holes.
      final first = math.max(0, (stop.rowAtY(scroll, _morph.origin) - 1) * stop.columns - stop.phase);
      final end = math.min(
        widget.itemCount,
        (stop.rowAtY(scroll + _viewportHeight, _morph.origin) + 2) * stop.columns - stop.phase,
      );
      if (first >= end) continue;
      warm(first, end, stop.tileWidth.ceil(), dpr);
    }
  }
}

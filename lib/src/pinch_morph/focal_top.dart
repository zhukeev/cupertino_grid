part of '../pinch_morph.dart';

/// The vertical half of `frame()`: resolves the ONE scalar both lattices
/// anchor their rows on — the focal cell's emitted top — through four
/// stages: pinch tracking, the in-band clamp while the fingers hold, the
/// coverage push when the content can cover the band, and the release
/// glide to rest. Extracted so `frame()` reads interval → geometry →
/// emit.
extension _FocalTop on PinchMorph {
  /// The focal cell's emitted top this frame.
  double _resolveFocalTop({
    required MorphGridStop larger,
    required MorphGridStop denser,
    required double progress,
    required double reflow,
    required double reflowWindow,
    required double cellHeight,
    required double strideY,
    required double clipTop,
    required double coverageClipTop,
    required double bandBottom,
    required double spacing,
  }) {
    final settle = stops[settleStop];
    final restTop = settle.tileTop(focalIndex, origin) - restScrolls[settleStop];
    // anchor.dy — the pinch point under the fingers while they hold,
    // gliding to the settled stop's rest position on release — derived
    // here so the horizontal half's interval re-derivation stays off the
    // emitted frame's path.
    final pinchDy = pin >= 1
        ? focalPoint.dy
        : lerpDouble(restTop + focalFraction.dy * settle.tileHeight, focalPoint.dy, pin)!;
    var focalTop = pinchDy - focalFraction.dy * cellHeight;
    // While the fingers are down the focal cell keeps whatever band
    // clipping it had at pinch start — but the gesture may never push it
    // FURTHER off-screen: a pinch rooted near a bezel lets the cell drift
    // toward the visible grid instead of tracking the finger behind it —
    // iOS's "come close to the focal image". When the cell is bigger than
    // the band the bounds invert so it still covers. Scaled by [pin] so
    // the release glides back to the true rest layout.
    if (pin > 0) {
      final minTop = math.min(clipTop, _pinchStartFocalRect.top);
      final maxTop = math.max(bandBottom, _pinchStartFocalRect.bottom) - cellHeight;
      focalTop += (focalTop.clamp(math.min(minTop, maxTop), math.max(minTop, maxTop)) - focalTop) * pin;
    }

    // Coverage beats visibility: if keeping the focal cell on screen
    // would open a content hole, the lattice still shifts to cover.
    // Content shorter than the band can't cover either way — every
    // placement leaves a hole somewhere, so it just holds the pinch
    // position (iOS Photos shows the margin too). When a pinch grows the
    // content past the screen-height boundary the position must glide to
    // the coverage-clamped one — blended over a fixed slice of the
    // gesture past the solved crossing so the lattice slides instead of
    // pivoting the instant the blended extent crosses.
    final bandTop = coverageClipTop + spacing;
    final bandHeight = bandBottom - bandTop;
    // The floors never pull an edge past the margin it PARKED at: at a
    // list boundary the parked grid already shows the same sliver, so
    // dragging the edge deeper mid-gesture manufactures a position the
    // settle must glide back out of — the vertical wobble. Mid-list
    // pinches park their edges off the band, so the floors stay at the
    // band edges and the push still covers gaps the morph itself opens.
    final coverTop = math.max(bandTop, clipTop);
    final coverBottom = math.min(
      bandBottom,
      stops[startStop].rowTop(stops[startStop].rowCount(itemCount), origin) - startScroll,
    );

    // Content-extent surplus (`rows·stride − bandHeight`) at blend
    // position [s]: negative while the content can't cover the band.
    // Only the crossing bisection samples interior points — the endpoints
    // read straight off the stops (the start carries the rubber-band
    // overscale).
    double overhangAt(double s) {
      final reflowAt = PinchMorph._midpointRamp(s, reflowWindow);
      final strideAt =
          math.exp(lerpDouble(math.log(larger.tileWidth), math.log(denser.tileWidth), s)!) *
              lerpDouble(larger.aspect, denser.aspect, reflowAt)! +
          spacing;
      final rowsAt = lerpDouble(
        larger.rowCount(itemCount).toDouble(),
        denser.rowCount(itemCount).toDouble(),
        reflowAt,
      )!;
      return rowsAt * strideAt - bandHeight;
    }

    final startOverhang =
        larger.rowCount(itemCount) * (larger.tileWidth * overscale * larger.aspect + spacing) - bandHeight;
    final endOverhang = denser.rowCount(itemCount) * (denser.tileWidth * denser.aspect + spacing) - bandHeight;
    final double coverageBlend;
    if (startOverhang < 0 && endOverhang < 0) {
      coverageBlend = 0;
    } else if (startOverhang >= 0 && endOverhang >= 0) {
      coverageBlend = 1;
    } else {
      // Bisect the blended extent for the interval point where the
      // content first covers the band — the handoff the push eases over.
      var lo = 0.0;
      var hi = 1.0;
      for (var i = 0; i < _coverageBisectionSteps; i++) {
        final mid = (lo + hi) / 2;
        if ((overhangAt(mid) < 0) == (startOverhang < 0)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      final crossing = (lo + hi) / 2;
      // The handoff starts AT the crossing — on the underfilled side the
      // pinch position is already continuous, and the coverage push the
      // covering side demands eases in over the window instead of
      // injecting the parked hole the moment the extent crosses.
      final direction = endOverhang > startOverhang ? 1.0 : -1.0;
      coverageBlend = PinchMorph._smoothstep((progress - crossing) * direction / style.coverageBlendSpan);
    }

    // This level's covering position: the pinch position pushed back
    // inside whichever content edge it leaves bare — computed only while
    // the blend engages (underfilled content or a disengaged handoff
    // keeps the pinch position; every placement would leave a hole
    // somewhere anyway).
    final rowsAbove = lerpDouble(larger.rowOf(focalIndex).toDouble(), denser.rowOf(focalIndex).toDouble(), reflow)!;
    final rowsTotal = lerpDouble(larger.rowCount(itemCount).toDouble(), denser.rowCount(itemCount).toDouble(), reflow)!;
    var pushedTop = focalTop;
    if (coverageBlend > 0 && rowsTotal * strideY - bandHeight >= 0) {
      final contentTop = pushedTop - rowsAbove * strideY;
      if (contentTop > coverTop) pushedTop -= contentTop - coverTop;
      final contentBottom = pushedTop + (rowsTotal - rowsAbove) * strideY;
      if (contentBottom < coverBottom) pushedTop += coverBottom - contentBottom;
    }
    final coverageTop = coverageBlend == 0 ? focalTop : lerpDouble(focalTop, pushedTop, coverageBlend)!;
    final uncoveredTop = focalTop;
    focalTop = _settleGlide.resolve(pin: pin, uncoveredTop: focalTop, coverageTop: coverageTop, restTop: restTop);
    if (PinchMorph.debugTraceEnabled && PinchMorph.debugTrace.length < 2000) {
      PinchMorph.debugTrace.add(
        'L=${level.toStringAsFixed(4)} pin=${pin.toStringAsFixed(3)} '
        'unc=${uncoveredTop.toStringAsFixed(1)} push=${pushedTop.toStringAsFixed(1)} '
        'cov=${coverageBlend.toStringAsFixed(3)} covTop=${coverageTop.toStringAsFixed(1)} '
        'rest=${restTop.toStringAsFixed(1)} out=${focalTop.toStringAsFixed(1)} '
        'covFloor=${coverTop.toStringAsFixed(1)}/${coverBottom.toStringAsFixed(1)} '
        'strideY=${strideY.toStringAsFixed(1)} rowsAbove=${rowsAbove.toStringAsFixed(2)} '
        'anchor=${pinchDy.toStringAsFixed(1)}',
      );
    }
    return focalTop;
  }
}

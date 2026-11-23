import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/physics.dart' show SpringDescription;

/// Tunable feel of a [CupertinoGrid] pinch — every knob defaults to the
/// value tuned against iOS Photos reference footage.
///
/// Pass a modified copy to [CupertinoGrid.style] to retune the gesture;
/// the engine-side half also flows into [PinchMorph.style] if you drive the
/// morph without the widget. Knobs are grouped:
///
/// - Reflow/crossfade: [reflowWindow], [crossfadeEase], [coverageBlendSpan],
///   [rubberBand] — how the lattice slides and photos swap mid-gesture.
/// - Release: [settleSpring], [commitThreshold], [flickVelocity],
///   [flickStaleDuration] — how the settle lands and how flicks commit.
/// - Edge squeezes: [minEdgeSqueeze], [edgeSqueezeGain], [edgeRefractory] —
///   the rubber-band a pinch at the densest stop gets.
/// - Overlay dressing: [pillExtent], [pillGap], [stickyImageBytes].
@immutable
final class PinchMorphStyle {
  /// Creates the style with iOS-Photos defaults, or overrides per knob.
  ///
  /// Knobs are domain-checked at construction (a const context, so a bad
  /// literal fails to compile): window/span knobs are strictly positive —
  /// they divide — rate and extent knobs non-negative, and the [0, 1]
  /// fractions stay in range.
  const PinchMorphStyle({
    this.reflowWindow = 0.25,
    this.crossfadeEase = 2.0,
    this.coverageBlendSpan = 0.45,
    this.levelSmoothing = 0.03,
    this.rubberBand = 1.0,
    this.settleSpring = const SpringDescription(mass: 1, stiffness: 400, damping: 40),
    this.commitThreshold = 0.18,
    this.flickVelocity = 2.0,
    this.flickStaleDuration = const Duration(microseconds: 90000),
    this.minEdgeSqueeze = 0.94,
    this.edgeSqueezeGain = 0.12,
    this.edgeRefractory = const Duration(milliseconds: 600),
    this.overscaleCommitThreshold = 1.5,
    this.pillExtent = 26.0,
    this.pillGap = 4.0,
    this.stickyImageBytes = 48 * 1024 * 1024,
  }) : assert(reflowWindow > 0 && reflowWindow <= 1, 'reflowWindow is a share of an interval: 0 < x <= 1'),
       assert(crossfadeEase > 0, 'crossfadeEase is an exponent: x > 0'),
       assert(coverageBlendSpan > 0, 'coverageBlendSpan divides into the blend: x > 0'),
       assert(levelSmoothing >= 0, 'levelSmoothing is a filter time constant: x >= 0'),
       assert(rubberBand >= 0, 'rubberBand is a damping factor: x >= 0'),
       assert(commitThreshold >= 0 && commitThreshold <= 1, 'commitThreshold is a fraction: 0 <= x <= 1'),
       assert(flickVelocity >= 0, 'flickVelocity is a speed floor: x >= 0'),
       assert(minEdgeSqueeze > 0 && minEdgeSqueeze <= 1, 'minEdgeSqueeze is the squeeze floor: 0 < x <= 1'),
       assert(edgeSqueezeGain >= 0, 'edgeSqueezeGain is a log-width gain: x >= 0'),
       assert(overscaleCommitThreshold > 1, 'overscaleCommitThreshold is a stretch factor: x > 1'),
       assert(pillExtent >= 0, 'pillExtent is a height: x >= 0'),
       assert(pillGap >= 0, 'pillGap is a gap: x >= 0'),
       assert(stickyImageBytes >= 0, 'stickyImageBytes is a byte cap: x >= 0');

  /// Share of an interval, centred on its midpoint, over which the lattice
  /// slides between stops and slots crossfade — `0.25` keeps the grid rigid
  /// through most of the gesture like iOS (a brief shuffle, not a
  /// morph-long dissolve). This calibrates the ladder's *average* density
  /// step: the effective window scales with the interval's log-width
  /// distance (bigger jumps reflow over more of the gesture), floored at
  /// half this value and capped at 0.9 of the interval.
  final double reflowWindow;

  /// Crossfade completion curve exponent — above 1 the photo swap resolves
  /// early in the reflow window so blends don't linger near a stop.
  final double crossfadeEase;

  /// Share of the interval past the coverage crossing over which the
  /// coverage push eases in (one-sided: 0 at the crossing, 1 this far into
  /// the covering side). Widening spreads the push thinner.
  final double coverageBlendSpan;

  /// Time constant (seconds) of the pinch-level low-pass — interleaved
  /// per-finger move events jitter the raw span by sub-pixel amounts,
  /// invisible on the cell-size curve but amplified ~15× inside the reflow
  /// window where the lattice visibly lurches a few pixels at random.
  /// `0.03` strips that shimmer while deliberate travel still converges in
  /// ~80 ms; `0` disables the filter (raw level).
  final double levelSmoothing;

  /// Stretch response when the pinch overshoots past the largest-tile
  /// stop — `exp(excess · rubberBand)`. `1.0` tracks the pinch spread
  /// exactly (the "pull the photo open" gesture needs the stretch to sit
  /// under the fingers for its launch hand-off); below 1 damps it into a
  /// rubber-band peek.
  final double rubberBand;

  /// Release spring — critically damped at the default (ratio 1, i.e.
  /// `damping = 2·√(mass·stiffness)`), settling in ~300 ms without bounce.
  final SpringDescription settleSpring;

  /// Fraction of an interval the pinch must travel for release to carry on
  /// to the next stop instead of springing back.
  final double commitThreshold;

  /// Stops/sec the morph level must be moving at release for momentum to
  /// carry the commit past [commitThreshold]; slower releases land on the
  /// nearer stop (iOS Photos' flick-vs-drag rule).
  final double flickVelocity;

  /// A level sample older than this reads as fingers-held-still — the
  /// release commit then ignores the stale flick estimate.
  final Duration flickStaleDuration;

  /// Minimum scale an edge pinch can squeeze to at the densest stop —
  /// `0.94` is a gentle 6% rubber-band.
  final double minEdgeSqueeze;

  /// Log-width gain of the edge squeeze curve — how fast the squeeze
  /// approaches [minEdgeSqueeze] as the pinch pushes past the end.
  final double edgeSqueezeGain;

  /// Cooldown after an edge squeeze ends before another may start — keeps
  /// repeated bezel pinches from machine-gunning scale pulses.
  final Duration edgeRefractory;

  /// Stretch past the largest-tile stop at which a release "commits" the
  /// overscale — fires [CupertinoGrid.onOverscaleCommit] instead of being
  /// just a rubber-band peek. With the default full [rubberBand] tracking,
  /// `1.5` means the pinch must spread ~1.5× past the hero tile before the
  /// fingers lift — the photo reads "pulled open", still comfortably
  /// reachable in one gesture.
  final double overscaleCommitThreshold;

  /// Height of a section pill band in the morph overlay — the dedup/clip
  /// geometry AND the enforced layout height of pill children, so a
  /// [CupertinoGrid.sectionLabelBuilder] taller than this is clipped to
  /// the band rather than overlapping its neighbour.
  final double pillExtent;

  /// Vertical gap between a section pill and its tile band.
  final double pillGap;

  /// Byte cap on the overlay's retained decoded images — oldest entries
  /// evict once past this. ~48 MB keeps every warmed thumbnail of a
  /// mid-size library.
  final int stickyImageBytes;
}

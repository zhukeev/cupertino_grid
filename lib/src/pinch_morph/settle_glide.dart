part of '../pinch_morph.dart';

/// Release glide for a coverage-clamped park.
///
/// Instead of re-deriving the coverage clamp through the settle — its
/// targets keep sweeping as the level eases, and `clipTop` collapses with
/// the header, re-injecting a down-then-up dip — the settle latches the
/// clamped position and glides it to the rest top, scaled by the pin *at
/// the latch* so a mid-settle onset stays continuous (lerping with the
/// raw pin would jump by `(rest − from)·(1 − pin)` on the latching
/// frame). Both glide endpoints are coverage-valid against the band —
/// the feasible interval is convex — so the lerp cannot open a hole. A
/// park the clamp left alone keeps the live path; there is no dip to
/// unwind.
final class _SettleGlide {
  /// The last emitted frame's focal top, and its pre-coverage value — the
  /// pair that detects whether the coverage clamp moved the parked
  /// lattice.
  double _lastFocalTop = 0;
  double _lastUncoveredTop = 0;
  double _fromTop = 0;

  /// Pin at the latch; the glide fraction is `pin / _pinAtLatch` so the
  /// latched frame itself is continuous. A latch at pin≈0 (a release
  /// tested as an instant 1→0 jump) lands straight on rest.
  double _pinAtLatch = 1;
  bool _decided = false;
  bool _active = false;

  /// Back to the live path — called at pinch start and every frame the
  /// fingers are down.
  void reset() {
    _decided = false;
    _active = false;
    _pinAtLatch = 1;
  }

  /// The frame's focal top: the coverage-clamped position while fingers
  /// are down, and during release a monotone glide to [restTop] once a
  /// clamp has latched.
  double resolve({
    required double pin,
    required double uncoveredTop,
    required double coverageTop,
    required double restTop,
  }) {
    if (pin >= 1) {
      reset();
      _lastUncoveredTop = uncoveredTop;
      return _lastFocalTop = coverageTop;
    }
    if (!_decided) {
      _decided = true;
      // A clamped park: the parked frame's emitted top differs from what
      // the uncovered position would have been.
      if ((_lastFocalTop - _lastUncoveredTop).abs() > 1e-6) {
        _latch(_lastFocalTop, pin);
      }
    }
    // A clamp that only engages mid-settle latches at its onset so the
    // switch to the glide stays continuous.
    if (!_active && (coverageTop - uncoveredTop).abs() > 1e-6) {
      _latch(coverageTop, pin);
    }
    if (!_active) return _lastFocalTop = coverageTop;
    final fraction = _pinAtLatch > 1e-6 ? (pin / _pinAtLatch).clamp(0.0, 1.0) : 0.0;
    return _lastFocalTop = lerpDouble(restTop, _fromTop, fraction)!;
  }

  void _latch(double fromTop, double pin) {
    _active = true;
    _fromTop = fromTop;
    _pinAtLatch = pin;
  }
}

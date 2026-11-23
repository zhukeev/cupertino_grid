part of '../cupertino_grid.dart';

/// [ScaleStartDetails] carrying the engaged pointers' positions at the
/// moment the pinch engaged — lets the widget resolve the intended focal
/// tile per finger instead of trusting only their midpoint.
final class _PinchStartDetails extends ScaleStartDetails {
  _PinchStartDetails({required this.pointerPositions, super.focalPoint, super.localFocalPoint, super.pointerCount});

  /// Global position of each engaged pointer (first-down first).
  final List<Offset> pointerPositions;
}

/// Two-finger pinch recognizer: reports scale relative to the pointer span
/// at gesture start and, unlike [ScaleGestureRecognizer], only engages once
/// a second pointer lands — single-finger drags keep scrolling.
final class _TwoFingerScaleGestureRecognizer extends OneSequenceGestureRecognizer {
  ValueChanged<_PinchStartDetails>? onStart;
  ValueChanged<ScaleUpdateDetails>? onUpdate;
  ValueChanged<ScaleEndDetails>? onEnd;

  /// Tracked pointers and their last positions — includes swallowed extra
  /// fingers (claimed so nothing else gestures on them mid-pinch), which
  /// never participate in the math: only [_pairA]/[_pairB] do.
  final Map<int, Offset> _positions = {};

  /// The engaged pointer pair, locked at activation — a third finger can
  /// never change the focal/span basis or silently swap the pair.
  int? _pairA;
  int? _pairB;

  Offset _initialFocal = Offset.zero;
  double _initialSpan = 0;
  bool _active = false;
  VelocityTracker? _tracker;

  Offset? get _a => _positions[_pairA];
  Offset? get _b => _positions[_pairB];

  Offset get _focal {
    final a = _a;
    final b = _b;
    return (a == null || b == null) ? _initialFocal : (a + b) / 2;
  }

  double get _span {
    final a = _a;
    final b = _b;
    return (a == null || b == null) ? _initialSpan : (b - a).distance;
  }

  bool _isPair(int pointer) => pointer == _pairA || pointer == _pairB;

  void _drop(int pointer) {
    _positions.remove(pointer);
    stopTrackingPointer(pointer);
  }

  void _end() {
    _active = false;
    _pairA = null;
    _pairB = null;
    onEnd?.call(ScaleEndDetails(velocity: _tracker?.getVelocity() ?? Velocity.zero));
    _tracker = null;
    resolve(GestureDisposition.rejected);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer);
    _positions[event.pointer] = event.position;
    if (_positions.length == 2 && !_active) {
      _active = true;
      _pairA = _positions.keys.first;
      _pairB = _positions.keys.last;
      _initialSpan = _span;
      _initialFocal = _focal;
      _tracker = VelocityTracker.withKind(event.kind);
      resolve(GestureDisposition.accepted); // cancels the pending scroll drag
      onStart?.call(
        _PinchStartDetails(
          pointerCount: 2,
          localFocalPoint: _initialFocal,
          focalPoint: _initialFocal,
          pointerPositions: [_a!, _b!],
        ),
      );
    } else if (_active) {
      // Third+ fingers: claimed so the scroll view can't win their arena
      // and scroll mid-pinch — but they never join the pair, and their
      // moves are ignored entirely.
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _positions.containsKey(event.pointer)) {
      _positions[event.pointer] = event.position;
      if (!_active || !_isPair(event.pointer)) return;
      _tracker?.addPosition(event.timeStamp, event.position);
      final focal = _focal;
      onUpdate?.call(
        ScaleUpdateDetails(
          pointerCount: 2,
          scale: _initialSpan > 0 ? _span / _initialSpan : 1,
          localFocalPoint: focal,
          focalPoint: focal,
          focalPointDelta: focal - _initialFocal,
          sourceTimeStamp: event.timeStamp,
        ),
      );
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      final wasPair = _active && _isPair(event.pointer);
      _drop(event.pointer);
      // Lifting either engaged finger ends the pinch — extras never
      // promote into the freed slot (no silent pair swap mid-gesture).
      if (wasPair) _end();
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    // Always drop the pointer: a rejection while active means the arena
    // took the pointer stream away, and keeping it wedged `_positions`
    // past two entries forever — every later pinch stayed at
    // `length != 2` and never engaged.
    final wasPair = _isPair(pointer);
    _positions.remove(pointer);
    if (_active && wasPair) _end();
  }

  @override
  String get debugDescription => 'two finger scale';

  @override
  void didStopTrackingLastPointer(int pointer) {
    // Defensive: any bookkeeping left over (e.g. an arena loss that routed
    // around handleEvent) dies with the last tracked pointer.
    _positions.clear();
    _pairA = null;
    _pairB = null;
  }
}

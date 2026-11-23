import 'package:flutter/widgets.dart';

/// One-edge clamp: a drag or fling past `maxScrollExtent` stops dead
/// instead of elastic-bouncing — with no content left at the far edge,
/// the pull only reads as "more to load". The near edge keeps its
/// platform bounce so a pull-to-refresh there still travels.
///
/// Built for a reversed axis (where the exhausted oldest edge is the max
/// end) but works on either axis — the clamp always applies to the max
/// scroll extent.
final class FarEdgeClampScrollPhysics extends AlwaysScrollableScrollPhysics {
  /// Creates physics that clamps the max edge and bounces the min edge.
  const FarEdgeClampScrollPhysics({super.parent});

  @override
  FarEdgeClampScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FarEdgeClampScrollPhysics(parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // Drag deltas landing past the far edge collapse onto it exactly —
    // the near edge's elastic handles the other direction.
    if (offset < 0 && position.pixels - offset > position.maxScrollExtent) {
      return position.pixels - position.maxScrollExtent;
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // A fling toward the far edge clamps; the other way keeps the spring.
    if (velocity > 0) {
      return const ClampingScrollPhysics().createBallisticSimulation(position, velocity);
    }
    return super.createBallisticSimulation(position, velocity);
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (value > position.maxScrollExtent) {
      return value - position.maxScrollExtent;
    }
    return super.applyBoundaryConditions(position, value);
  }
}

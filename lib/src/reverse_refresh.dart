import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

/// Pull-to-refresh for a reversed-axis scroll view.
///
/// [CupertinoSliverRefreshControl] asserts `AxisDirection.down`, so under
/// a bottom-anchored (iOS-Photos-style) axis it cannot live inside the
/// scroll view at all. This overlay instead watches the scroll view's
/// overscroll at the leading edge — pixels below `minScrollExtent` — and
/// fires [onRefresh] on release once the pull passes [trigger].
final class CupertinoReverseRefresh extends StatefulWidget {
  /// Creates a reversed-axis pull-to-refresh overlay around [child].
  const CupertinoReverseRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.indicatorInset = 12,
    this.indicatorBuilder,
    this.trigger = 72,
  });

  /// Fires once per armed pull — concurrent pulls while a refresh is in
  /// flight are ignored.
  final Future<void> Function() onRefresh;

  /// The scroll view — typically a reversed `CustomScrollView`.
  final Widget child;

  /// Distance the indicator floats above the bottom edge — bump it past
  /// floating chrome (a tab bar) so the pull zone reads under it.
  final double indicatorInset;

  /// Builds the pull indicator; defaults to a [CupertinoActivityIndicator].
  /// The widget already fades in and scales with pull progress.
  final Widget Function(BuildContext context)? indicatorBuilder;

  /// Overscroll distance that arms the refresh on release.
  final double trigger;

  @override
  State<CupertinoReverseRefresh> createState() => _CupertinoReverseRefreshState();
}

final class _CupertinoReverseRefreshState extends State<CupertinoReverseRefresh> {
  final ValueNotifier<double> _extent = ValueNotifier(0);
  bool _refreshing = false;

  bool _onScroll(ScrollNotification notification) {
    final overscroll = notification.metrics.minScrollExtent - notification.metrics.pixels;
    final DragUpdateDetails? dragDetails = switch (notification) {
      ScrollUpdateNotification(:final dragDetails) => dragDetails,
      OverscrollNotification(:final dragDetails) => dragDetails,
      _ => null,
    };
    if (dragDetails != null && overscroll > 0) {
      _extent.value = overscroll;
    } else if (notification is ScrollEndNotification ||
        (notification is ScrollUpdateNotification && notification.dragDetails == null)) {
      // Finger lifted — fire only when pulled past the trigger distance.
      if (_extent.value >= widget.trigger) unawaited(_refresh());
      _extent.value = 0;
    }
    return false;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        children: [
          widget.child,
          Positioned(
            left: 0,
            right: 0,
            bottom: widget.indicatorInset,
            child: Center(
              child: ValueListenableBuilder<double>(
                valueListenable: _extent,
                builder: (context, extent, _) {
                  if (!_refreshing && extent <= 8) {
                    return const SizedBox.shrink();
                  }
                  final progress = (extent / widget.trigger).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: _refreshing ? 1 : progress,
                    // The indicator grows with pull distance so the gesture
                    // reads as charging the refresh, not a pop-in.
                    child: Transform.scale(
                      scale: _refreshing ? 1 : 0.5 + 0.5 * progress,
                      child:
                          widget.indicatorBuilder?.call(context) ??
                          const RepaintBoundary(child: CupertinoActivityIndicator()),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

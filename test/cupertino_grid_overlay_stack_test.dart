import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Regression: an `overlayBuilder` that returns a non-positioned widget
/// (e.g. `SizedBox.shrink`) while the morph is active used to collapse the
/// stack to zero size — the screen went white mid-pinch and the recognizer
/// lost hit area. A non-positioned sentinel child keeps the stack expanded.
void main() {
  testWidgets('pinch stays alive when overlayBuilder returns SizedBox.shrink', (tester) async {
    final assets = [for (var i = 0; i < 120; i++) 'item-$i'];
    var columns = 3;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => CupertinoGrid(
              itemCount: assets.length,
              columnCountsForWidth: (w) => w >= 600 ? const [20, 8, 5, 2] : const [16, 5, 3, 1],
              columns: columns,
              onColumnsChanged: (c) => setOuter(() => columns = c),
              itemKey: (index) => assets[index],
              itemsVersion: assets,
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
              overlayBuilder:
                  (context, {required stop, required gridOrigin, required scrollController, required morphActive}) =>
                      morphActive
                      ? const SizedBox.shrink() // non-positioned — used to collapse the stack
                      : const Positioned(right: 0, top: 0, child: SizedBox(width: 44, height: 44)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(170, 400));
    await finger2.moveTo(const Offset(230, 400));
    await tester.pump();
    await tester.pump();

    // The scroll view must not have collapsed while the morph is active.
    expect(tester.getSize(find.byType(CustomScrollView)), const Size(800, 600));

    // And the morph overlay must have mounted tile children under its
    // IgnorePointer (the render object lays them out itself).
    expect(find.descendant(of: find.byType(IgnorePointer), matching: find.byType(ColoredBox)), findsWidgets);

    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();
  });

  testWidgets('pinch works with the decoded-image overlay path', (tester) async {
    // A 1x1 ui.Image resolved synchronously covers every overlay tile —
    // no tile child widgets are mounted for them at all.
    final picture = ui.PictureRecorder();
    ui.Canvas(picture).drawRect(const Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..color = const Color(0xFF336699));
    final image = await picture.endRecording().toImage(1, 1);
    addTearDown(image.dispose);

    final assets = [for (var i = 0; i < 120; i++) 'item-$i'];
    var columns = 3;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => CupertinoGrid(
              itemCount: assets.length,
              columnCountsForWidth: (w) => w >= 600 ? const [20, 8, 5, 2] : const [16, 5, 3, 1],
              columns: columns,
              onColumnsChanged: (c) => setOuter(() => columns = c),
              itemKey: (index) => assets[index],
              itemsVersion: assets,
              overlayImageFor: (index, targetSize) => image,
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    await finger1.moveTo(const Offset(170, 400));
    await finger2.moveTo(const Offset(230, 400));
    await tester.pump();
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    // The pinch committed to a new density without needing a single
    // overlay child widget.
    expect(columns, isNot(3));
  });

  /// Regression: `performLayout` used to keep the provider's raw `ui.Image`
  /// handle in its per-frame swap-pair map. A provider that evicts its own
  /// handle mid-layout (the overlay image cache can do exactly that when a
  /// stream completes synchronously inside `overlayImageFor`) left the map
  /// pointing at a disposed image, and the next swap partner cloning it
  /// threw "Cannot clone a disposed image". The overlay must clone up front
  /// and track only its own handles.
  testWidgets('overlay pair morph survives mid-layout provider eviction', (tester) async {
    final picture = ui.PictureRecorder();
    ui.Canvas(picture).drawRect(const Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..color = const Color(0xFF336699));
    final source = await picture.endRecording().toImage(1, 1);
    addTearDown(source.dispose);

    // A cache of one: every resolve hands out a fresh handle and disposes
    // the one the previous resolve returned — the minimal mid-pass
    // eviction an image cache can perform (OverlayImageCache's byte cap
    // disposes handles it already served, synchronously inside
    // `overlayImageFor` when a provider stream completes).
    ui.Image? current;
    ui.Image? provider(int index, int targetSize) {
      current?.dispose();
      current = source.clone();
      return current;
    }

    addTearDown(() => current?.dispose());

    // A no-op pair morph effect — its presence is what makes the overlay
    // clone the departing tile's image for a swap pair.
    var pairCount = 0;
    final effect = TileMorphEffect.callbacks(
      paint: (canvas, {required image, required rect, required progress, focal = Offset.zero, opacity = 1.0}) {},
      paintPair:
          (
            canvas, {
            required from,
            required to,
            required flow,
            required rect,
            required t,
            required progress,
            focal = Offset.zero,
          }) {},
      flowImage: (from, to) async {
        pairCount++;
        return null;
      },
    );

    final assets = [for (var i = 0; i < 120; i++) 'item-$i'];
    var columns = 3;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => CupertinoGrid(
              itemCount: assets.length,
              columnCountsForWidth: (w) => w >= 600 ? const [20, 8, 5, 2] : const [16, 5, 3, 1],
              columns: columns,
              onColumnsChanged: (c) => setOuter(() => columns = c),
              itemKey: (index) => assets[index],
              itemsVersion: assets,
              overlayImageFor: provider,
              overlayTileEffect: effect,
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    // Sweep the pinch in small steps — swap pairs only exist while the
    // frame's crossfade sits inside its window, so intermediate frames
    // must land mid-interval rather than jumping to the commit.
    for (var i = 1; i <= 14; i++) {
      await finger1.moveTo(Offset(140 + 7.0 * i, 400));
      await finger2.moveTo(Offset(260 - 7.0 * i, 400));
      await tester.pump();
    }
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(columns, isNot(3));
    // The sweep must have produced swap pairs — without them the disposed
    // handle is never cloned and the test proves nothing.
    expect(pairCount, greaterThan(0));
  });

  /// Regression: during zoom-in the lone-tile warp used to fire on EVERY
  /// unpaired tile — including held departing photos whose slot swaps to
  /// an item off the destination viewport, so cells far outside the next
  /// screen visibly morphed. Off-window lone tiles must stay on the rigid
  /// draw; only on-next-screen slots may reach the shader.
  testWidgets('zoom-in lone-tile warp stays inside the next screen', (tester) async {
    final picture = ui.PictureRecorder();
    ui.Canvas(picture).drawRect(const Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..color = const Color(0xFF336699));
    final image = await picture.endRecording().toImage(1, 1);
    addTearDown(image.dispose);

    var imageResolves = 0;
    var pairCalls = 0;
    var paintCalls = 0;
    final effect = TileMorphEffect.callbacks(
      paint: (canvas, {required image, required rect, required progress, focal = Offset.zero, opacity = 1.0}) {
        paintCalls++;
      },
      paintPair:
          (
            canvas, {
            required from,
            required to,
            required flow,
            required rect,
            required t,
            required progress,
            focal = Offset.zero,
          }) {
            pairCalls++;
          },
    );

    final assets = [for (var i = 0; i < 120; i++) 'item-$i'];
    var columns = 3;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => CupertinoGrid(
              itemCount: assets.length,
              columnCountsForWidth: (w) => w >= 600 ? const [20, 8, 5, 2] : const [16, 5, 3, 1],
              columns: columns,
              onColumnsChanged: (c) => setOuter(() => columns = c),
              itemKey: (index) => assets[index],
              itemsVersion: assets,
              overlayImageFor: (index, targetSize) {
                imageResolves++;
                return image;
              },
              overlayTileEffect: effect,
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    // Spread apart — the zoom-in direction the lone-tile warp serves.
    for (var i = 1; i <= 14; i++) {
      await finger1.moveTo(Offset(140 - 7.0 * i, 400));
      await finger2.moveTo(Offset(260 + 7.0 * i, 400));
      await tester.pump();
    }
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    // In-window lone tiles still warp — the feature itself is alive.
    expect(paintCalls, greaterThan(0));
    // resolves counts every image op, pairCalls every paired one — their
    // difference is the lone ops. Before the gate every lone op warped,
    // making this exactly 0; off-window lone ops must now be skipped.
    expect(imageResolves - pairCalls - paintCalls, greaterThan(0));
  });

  testWidgets('overscaling the largest stop commits the keep-zooming gesture', (tester) async {
    OverscaleCommit? fired;
    final assets = [for (var i = 0; i < 40; i++) 'item-$i'];
    var columns = 1;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => CupertinoGrid(
              itemCount: assets.length,
              columnCountsForWidth: (w) => const [16, 5, 3, 1],
              columns: columns,
              onColumnsChanged: (c) => setOuter(() => columns = c),
              onOverscaleCommit: (commit) => fired = commit,
              // The edge refractory is wall-clocked — test fake time can
              // never expire it, so the second pull would meet a hard
              // stop instead of painting overscale. Zero it for this one.
              style: const PinchMorphStyle(edgeRefractory: Duration.zero),
              itemKey: (index) => assets[index],
              itemsVersion: assets,
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Modest spread past the hero stop — a 1.3× stretch is below the
    // 1.5 commit threshold, so the release only rubber-bands back.
    var finger1 = await tester.createGesture();
    var finger2 = await tester.createGesture();
    await finger1.down(const Offset(250, 300));
    await finger2.down(const Offset(350, 300));
    await tester.pump();
    await finger1.moveTo(const Offset(235, 300));
    await finger2.moveTo(const Offset(365, 300));
    await tester.pump();
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();
    expect(fired, isNull);

    // A wide spread — overscale at/past the threshold — commits the
    // gesture and reports the pinched item; the grid still settles back
    // to the 1-column stop.
    finger1 = await tester.createGesture();
    finger2 = await tester.createGesture();
    await finger1.down(const Offset(250, 300));
    await finger2.down(const Offset(350, 300));
    await tester.pump();
    for (var i = 1; i <= 6; i++) {
      await finger1.moveTo(Offset(250 - 35.0 * i, 300));
      await finger2.moveTo(Offset(350 + 35.0 * i, 300));
      await tester.pump();
    }
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();
    expect(fired?.index, 0);
    // The launch rect hands off the pose the overlay actually painted:
    // the hero cell stretched ~5× wider than the screen, centred on it,
    // taller than the viewport — a shared-element flight starts exactly
    // on the pixels the user last saw.
    final rect = fired!.rect;
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.width, greaterThan(screen.width * 4));
    expect(rect.center.dx, closeTo(screen.width / 2, screen.width));
    expect(rect.overlaps(Offset.zero & screen), isTrue);
    expect(fired!.overscale, greaterThan(1.5));
    expect(columns, 1);
  });

  testWidgets('a held pinch still mounts fallbacks when images never resolve', (tester) async {
    // Regression: a miss below the mount streak only advanced while the
    // pointer produced layouts — holding a pinch over content that never
    // decodes (a background warm fills the tile cache without notifying
    // the overlay) stranded slots on the placeholder tint until the
    // fingers moved. The overlay schedules a bounded follow-up layout per
    // miss, so the fallback child mounts with zero further pointer input.
    final assets = [for (var i = 0; i < 120; i++) 'item-$i'];
    var columns = 3;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => CupertinoGrid(
              itemCount: assets.length,
              columnCountsForWidth: (w) => w >= 600 ? const [20, 8, 5, 2] : const [16, 5, 3, 1],
              columns: columns,
              onColumnsChanged: (c) => setOuter(() => columns = c),
              itemKey: (index) => assets[index],
              itemsVersion: assets,
              // Every emitted tile misses — nothing decodes and no
              // listenable notifies.
              overlayImageFor: (index, targetSize) => null,
              overlayItemBuilder: (context, index, targetSize) => const _MissFallback(),
              itemBuilder: (context, index, targetSize) =>
                  ColoredBox(color: Colors.primaries[index % Colors.primaries.length]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finger1 = await tester.createGesture();
    final finger2 = await tester.createGesture();
    await finger1.down(const Offset(140, 400));
    await finger2.down(const Offset(260, 400));
    await tester.pump();
    // One small spread to emit the frame, then HOLD — the streak must
    // mature on the overlay's own scheduled layouts, not pointer deltas.
    await finger1.moveTo(const Offset(134, 400));
    await finger2.moveTo(const Offset(266, 400));
    await tester.pump();

    expect(find.byType(_MissFallback), findsNothing);

    // Drain the retry layouts — mount streak + slots-needed callback +
    // child mount each need a frame; give it slack.
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }

    expect(find.byType(_MissFallback), findsWidgets);

    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();
  });
}

/// Marker for the mounted-miss fallback in the held-pinch test — distinct
/// from the base itemBuilder so `find` only hits overlay children.
final class _MissFallback extends StatelessWidget {
  const _MissFallback();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

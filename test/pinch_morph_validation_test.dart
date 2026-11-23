import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cupertino_grid/cupertino_grid.dart';

/// Boundary validation: degenerate public inputs fail on an assertion at
/// the API edge instead of emitting NaN geometry, range errors, or a
/// silently clamped layout downstream.
void main() {
  List<MorphGridStop> stops() => [
    MorphGridStop(3, 390, spacing: 2, aspect: 1),
    MorphGridStop(5, 390, spacing: 2, aspect: 1),
  ];

  PinchMorph begun() {
    final morph = PinchMorph();
    morph.begin(
      stops: stops(),
      startStop: 0,
      focalIndex: 10,
      focalFraction: const Offset(0.5, 0.5),
      focalPoint: const Offset(195, 350),
      startScroll: 0,
      minScroll: 0,
      trailing: 0,
      itemCount: 200,
      origin: 0,
      headerOrigin: 0,
      viewport: const Size(390, 700),
    );
    return morph;
  }

  group('MorphGridStop', () {
    test('rejects degenerate constructor inputs', () {
      expect(() => MorphGridStop(0, 390, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(-3, 390, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, 0, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, double.nan, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, double.infinity, spacing: 2, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: -1, aspect: 1), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: 2, aspect: 0), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: 2, aspect: double.nan), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: 2, aspect: 1, phase: -1), throwsArgumentError);
      expect(() => MorphGridStop(3, 390, spacing: 2, aspect: 1, phase: 3), throwsArgumentError);
    });

    test('accepts the domain edges', () {
      expect(MorphGridStop(1, 390, spacing: 0, aspect: 0.01).tileWidth, greaterThan(0));
    });
  });

  group('PinchMorphStyle', () {
    test('rejects out-of-domain knobs', () {
      expect(() => PinchMorphStyle(reflowWindow: 0), throwsAssertionError);
      expect(() => PinchMorphStyle(reflowWindow: 1.5), throwsAssertionError);
      expect(() => PinchMorphStyle(crossfadeEase: 0), throwsAssertionError);
      expect(() => PinchMorphStyle(coverageBlendSpan: 0), throwsAssertionError);
      expect(() => PinchMorphStyle(rubberBand: -0.1), throwsAssertionError);
      expect(() => PinchMorphStyle(commitThreshold: -0.1), throwsAssertionError);
      expect(() => PinchMorphStyle(commitThreshold: 1.5), throwsAssertionError);
      expect(() => PinchMorphStyle(flickVelocity: -1), throwsAssertionError);
      expect(() => PinchMorphStyle(minEdgeSqueeze: 0), throwsAssertionError);
      expect(() => PinchMorphStyle(minEdgeSqueeze: 1.2), throwsAssertionError);
      expect(() => PinchMorphStyle(edgeSqueezeGain: -1), throwsAssertionError);
      expect(() => PinchMorphStyle(pillExtent: -1), throwsAssertionError);
      expect(() => PinchMorphStyle(pillGap: -1), throwsAssertionError);
      expect(() => PinchMorphStyle(stickyImageBytes: -1), throwsAssertionError);
    });
  });

  group('PinchMorph.begin', () {
    void Function() call({List<MorphGridStop>? stops, int startStop = 0, int focalIndex = 10, int itemCount = 200}) {
      return () => PinchMorph().begin(
        stops: stops ?? [MorphGridStop(3, 390, spacing: 2, aspect: 1), MorphGridStop(5, 390, spacing: 2, aspect: 1)],
        startStop: startStop,
        focalIndex: focalIndex,
        focalFraction: const Offset(0.5, 0.5),
        focalPoint: const Offset(195, 350),
        startScroll: 0,
        minScroll: 0,
        trailing: 0,
        itemCount: itemCount,
        origin: 0,
        headerOrigin: 0,
        viewport: const Size(390, 700),
      );
    }

    test('rejects an empty stop list', () {
      expect(call(stops: const []), throwsAssertionError);
    });

    test('accepts a single-stop ladder', () {
      expect(call(stops: [MorphGridStop(3, 390, spacing: 2, aspect: 1)]), returnsNormally);
    });

    test('rejects an out-of-range startStop', () {
      expect(call(startStop: 2), throwsAssertionError);
      expect(call(startStop: -1), throwsAssertionError);
    });

    test('rejects an unsorted or duplicated ladder — levelForLogTile divides by column gaps', () {
      expect(
        call(stops: [MorphGridStop(5, 390, spacing: 2, aspect: 1), MorphGridStop(3, 390, spacing: 2, aspect: 1)]),
        throwsAssertionError,
      );
      expect(
        call(stops: [MorphGridStop(3, 390, spacing: 2, aspect: 1), MorphGridStop(3, 390, spacing: 2, aspect: 1)]),
        throwsAssertionError,
      );
    });

    test('rejects out-of-range focal indices and item counts', () {
      expect(call(focalIndex: -1), throwsAssertionError);
      expect(call(focalIndex: 200), throwsAssertionError);
      expect(call(itemCount: 0), throwsAssertionError);
      expect(call(focalIndex: 10, itemCount: 5), throwsAssertionError);
    });

    test('rejects non-finite geometry', () {
      void Function() call({
        Offset focalPoint = const Offset(195, 350),
        Offset focalFraction = const Offset(0.5, 0.5),
        double startScroll = 0,
        double origin = 0,
        Size viewport = const Size(390, 700),
      }) {
        return () => PinchMorph().begin(
          stops: stops(),
          startStop: 0,
          focalIndex: 10,
          focalFraction: focalFraction,
          focalPoint: focalPoint,
          startScroll: startScroll,
          minScroll: 0,
          trailing: 0,
          itemCount: 200,
          origin: origin,
          headerOrigin: 0,
          viewport: viewport,
        );
      }

      expect(call(focalPoint: const Offset(double.nan, 350)), throwsAssertionError);
      expect(call(focalFraction: const Offset(0.5, double.infinity)), throwsAssertionError);
      expect(call(startScroll: double.nan), throwsAssertionError);
      expect(call(origin: double.negativeInfinity), throwsAssertionError);
      expect(call(viewport: Size.zero), throwsAssertionError);
      expect(call(viewport: const Size(-390, 700)), throwsAssertionError);
      expect(call(viewport: const Size(double.infinity, 700)), throwsAssertionError);
    });
  });

  group('PinchMorph.set', () {
    test('rejects non-finite and out-of-range values', () {
      expect(() => begun().set(level: double.nan), throwsAssertionError);
      expect(() => begun().set(level: double.infinity), throwsAssertionError);
      expect(() => begun().set(level: -1), throwsAssertionError);
      expect(() => begun().set(overscale: 0), throwsAssertionError);
      expect(() => begun().set(overscale: -1), throwsAssertionError);
      expect(() => begun().set(pin: double.nan), throwsAssertionError);
    });

    test('accepts boundary values', () {
      expect(() => begun().set(level: 0), returnsNormally);
      expect(() => begun().set(level: 5), returnsNormally);
      expect(() => begun().set(overscale: 1), returnsNormally);
      expect(() => begun().set(pin: 1), returnsNormally);
    });
  });

  test('frame() before begin() fails on the precondition, not a range error', () {
    expect(() => PinchMorph().frame((_) => false), throwsAssertionError);
  });
}

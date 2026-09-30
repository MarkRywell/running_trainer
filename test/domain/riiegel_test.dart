import 'dart:math' as math;

import 'package:ai_running_trainer/domain/engine/riiegel.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('raw prediction', () {
    test('is identity for the same distance', () {
      const t = Duration(minutes: 45);
      for (final d in RaceDistance.values) {
        expect(
          predict(anchor: d, time: t, target: d, conservative: false),
          t,
          reason: d.label,
        );
      }
    });

    test('a longer distance always takes longer', () {
      const t = Duration(minutes: 45);
      var previous = Duration.zero;
      for (final d in [
        RaceDistance.k5,
        RaceDistance.k10,
        RaceDistance.half,
        RaceDistance.marathon,
      ]) {
        final got = predict(anchor: RaceDistance.k10, time: t, target: d);
        expect(got, greaterThan(previous), reason: d.label);
        previous = got;
      }
    });

    test('is invertible — a marathon implies its 10K back', () {
      const marathon = Duration(hours: 3, minutes: 30);
      final k10 = predict(
        anchor: RaceDistance.marathon,
        time: marathon,
        target: RaceDistance.k10,
        conservative: false,
      );
      final roundTrip = predict(
        anchor: RaceDistance.k10,
        time: k10,
        target: RaceDistance.marathon,
        conservative: false,
      );
      // Within a second; the exponent is not perfectly symmetric in
      // floating point.
      expect(
        (roundTrip - marathon).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('uses the published exponent of 1.06', () {
      // 1 hour for 10K -> marathon should be 4.21975 ^ 1.06 times that.
      const t = Duration(hours: 1);
      final raw = rawPrediction(
        anchorMetres: 10000,
        anchorSeconds: 3600,
        targetMetres: 42197.5,
      );
      final expected = 3600 * _powForTest(42197.5 / 10000, 1.06);
      expect(raw, closeTo(expected, 0.001));
      expect(
        predict(anchor: RaceDistance.k10, time: t, target: RaceDistance.marathon,
            conservative: false).inSeconds,
        raw.round(),
      );
    });
  });

  group('conservative margin', () {
    test('is not applied to shorter projections', () {
      // Riegel errs pessimistic when shortening, which is the safe direction.
      expect(
        conservativeMargin(42197.5, 10000),
        1.0,
        reason: 'marathon -> 10K',
      );
    });

    test('is not applied to near-neighbour distances', () {
      // Only a 25% stretch or more triggers the correction.
      expect(conservativeMargin(10000, 12000), 1.0);
      expect(conservativeMargin(10000, 12500), 1.0);
    });

    test('scales with how far we extrapolate', () {
      final toHalf = conservativeMargin(10000, 21097.5);
      final toMarathon = conservativeMargin(10000, 42197.5);
      final fromFiveK = conservativeMargin(5000, 42197.5);
      expect(toHalf, greaterThan(1.0));
      expect(toMarathon, greaterThan(toHalf));
      expect(fromFiveK, greaterThan(toMarathon));
    });

    test('makes 10K -> marathon predictions slower than raw Riegel', () {
      const t = Duration(minutes: 45);
      final raw = predict(
        anchor: RaceDistance.k10,
        time: t,
        target: RaceDistance.marathon,
        conservative: false,
      );
      final safe = predict(
        anchor: RaceDistance.k10,
        time: t,
        target: RaceDistance.marathon,
      );
      expect(safe, greaterThan(raw));
    });

    test('leaves shorter predictions untouched', () {
      // 10K -> 5K shortens, and Riegel errs pessimistic in that direction,
      // which is the safe one. No correction.
      const t = Duration(minutes: 45);
      final raw = predict(
        anchor: RaceDistance.k10,
        time: t,
        target: RaceDistance.k5,
        conservative: false,
      );
      final safe = predict(
        anchor: RaceDistance.k10,
        time: t,
        target: RaceDistance.k5,
      );
      expect(safe, raw);
    });

    test('moves a 45:00 10K marathon prediction by 1-4 minutes', () {
      // The bias this exists to correct is documented as 1-3 minutes; allow
      // a little slack either way so the test is a real guard, not a ratchet.
      const t = Duration(minutes: 45);
      final raw = predict(
        anchor: RaceDistance.k10,
        time: t,
        target: RaceDistance.marathon,
        conservative: false,
      );
      final safe = predict(
        anchor: RaceDistance.k10,
        time: t,
        target: RaceDistance.marathon,
      );
      final deltaMin = (safe - raw).inSeconds / 60;
      expect(deltaMin, greaterThanOrEqualTo(1));
      expect(deltaMin, lessThanOrEqualTo(4));
    });
  });

  group('monotonicity with the margin applied', () {
    test('still increasing with distance', () {
      const t = Duration(minutes: 50);
      var previous = Duration.zero;
      for (final d in [
        RaceDistance.k5,
        RaceDistance.k10,
        RaceDistance.half,
        RaceDistance.marathon,
      ]) {
        final got = predict(anchor: RaceDistance.k10, time: t, target: d);
        expect(got, greaterThan(previous), reason: d.label);
        previous = got;
      }
    });

    test('a slower anchor never predicts a faster time', () {
      var previous = Duration.zero;
      for (var m = 40; m <= 70; m += 5) {
        final got = predict(
          anchor: RaceDistance.k10,
          time: Duration(minutes: m),
          target: RaceDistance.marathon,
        );
        expect(got, greaterThan(previous), reason: '${m}min 10K');
        previous = got;
      }
    });
  });

  test('a realistic case stays in a sane range', () {
    // 45:00 10K should imply a marathon somewhere in the 3:30-4:00 band.
    final marathon = predict(
      anchor: RaceDistance.k10,
      time: const Duration(minutes: 45),
      target: RaceDistance.marathon,
    );
    final minutes = marathon.inMinutes;
    expect(minutes, greaterThanOrEqualTo(210)); // 3:30
    expect(minutes, lessThanOrEqualTo(240)); // 4:00
  });
}

double _powForTest(double base, double exp) =>
    math.pow(base, exp).toDouble();

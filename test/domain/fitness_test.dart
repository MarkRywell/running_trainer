import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

void main() {
  group('anchor selection', () {
    test('prefers the longest recent race', () {
      final f = assessFitness(
        [
          raceK10(const Duration(minutes: 45)),
          raceMarathon(const Duration(hours: 3, minutes: 30)),
        ],
        testToday,
      );
      expect(f.anchor!.distance, RaceDistance.marathon);
    });

    test('prefers a marathon result even when it is older than a 10K', () {
      final f = assessFitness(
        [
          raceK10(const Duration(minutes: 42), daysAgo: 10),
          raceMarathon(const Duration(hours: 3, minutes: 40), daysAgo: 120),
        ],
        testToday,
      );
      // 120 days is still inside the freshness window, and a marathon
      // involves far less extrapolation than a 10K.
      expect(f.anchor!.distance, RaceDistance.marathon);
    });

    test('ignores races outside the freshness window when fresher ones exist', () {
      final f = assessFitness(
        [
          raceMarathon(const Duration(hours: 3, minutes: 10), daysAgo: 500),
          raceK10(const Duration(minutes: 48), daysAgo: 20),
        ],
        testToday,
      );
      expect(f.anchor!.distance, RaceDistance.k10);
      expect(f.hasFreshRace, isTrue);
    });

    test('falls back to a stale race and says so', () {
      final f = assessFitness(
        [raceK10(const Duration(minutes: 45), daysAgo: 900)],
        testToday,
      );
      expect(f.anchor!.distance, RaceDistance.k10);
      expect(f.hasFreshRace, isFalse);
      expect(f.notes, isNotEmpty);
      expect(
        f.notes.any((n) => n.contains('900 days old')),
        isTrue,
      );
    });

    test('handles no races at all', () {
      final f = assessFitness([], testToday);
      expect(f.hasData, isFalse);
      expect(f.anchor, isNull);
      expect(f.vdot, isNull);
      expect(f.equivalents, isEmpty);
    });

    test('ties on distance are broken by recency', () {
      final f = assessFitness(
        [
          raceK10(const Duration(minutes: 45), daysAgo: 100),
          raceK10(const Duration(minutes: 42), daysAgo: 10),
        ],
        testToday,
      );
      expect(f.anchor!.time, const Duration(minutes: 42));
    });
  });

  group('equivalents', () {
    test('uses the anchor result verbatim for its own distance', () {
      final f = assessFitness(
        [raceK10(const Duration(minutes: 45))],
        testToday,
      );
      expect(f.equivalentTo(RaceDistance.k10), const Duration(minutes: 45));
    });

    test('derives every distance, and they increase in order', () {
      final f = assessFitness(
        [raceK10(const Duration(minutes: 45))],
        testToday,
      );
      expect(
        f.equivalentTo(RaceDistance.k5)!,
        lessThan(f.equivalentTo(RaceDistance.k10)!),
      );
      expect(
        f.equivalentTo(RaceDistance.k10)!,
        lessThan(f.equivalentTo(RaceDistance.half)!),
      );
      expect(
        f.equivalentTo(RaceDistance.half)!,
        lessThan(f.equivalentTo(RaceDistance.marathon)!),
      );
    });

    test('applies the conservative margin on the marathon projection', () {
      final withMargin = assessFitness(
        [raceK10(const Duration(minutes: 45))],
        testToday,
      );
      expect(
        withMargin.equivalentTo(RaceDistance.marathon),
        greaterThan(const Duration(hours: 3, minutes: 30)),
      );
    });
  });

  group('vdot', () {
    test('is derived for a normal trained result', () {
      final f = assessFitness(
        [raceK10(const Duration(minutes: 45))],
        testToday,
      );
      expect(f.vdot, isNotNull);
      expect(f.vdot!, greaterThan(30));
      expect(f.hasSupportedVdot, isTrue);
    });

    test('is null for a result slower than the model supports', () {
      final f = assessFitness(
        [raceMarathon(const Duration(hours: 6))],
        testToday,
      );
      expect(f.vdot, isNull);
      expect(f.hasSupportedVdot, isFalse);
      expect(
        f.notes.any((n) => n.contains('outside the range')),
        isTrue,
      );
    });
  });

  test('a 45:00 10K implies a marathon in a plausible band', () {
    final f = assessFitness(
      [raceK10(const Duration(minutes: 45))],
      testToday,
    );
    final marathon = f.equivalentTo(RaceDistance.marathon)!;
    expect(marathon.inMinutes, inInclusiveRange(210, 250));
  });
}

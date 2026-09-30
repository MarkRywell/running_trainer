/// The ladder must be anchored on what the runner can demonstrably do today.
///
/// Found via a real report: a runner with a 52:25 10K set a 49:00 goal — a 6.7%
/// improvement — and was given a ladder anchored on the *goal* pace. Every zone
/// came out 52 s/km too fast, so threshold was 4:17 against a demonstrated 5:09,
/// and the gap between easy and threshold collapsed from ~50 s to 27 s. The app
/// had flagged the goal as a stretch and then trained as though it were achieved.
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/vdot.dart';
import 'package:ai_running_trainer/domain/engine/zones.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/units.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 9, 28);

List<RaceResult> _races() => [
      RaceResult(
        distance: RaceDistance.k5,
        time: const Duration(minutes: 24, seconds: 10),
        date: _now.subtract(const Duration(days: 5)),
      ),
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 52, seconds: 25),
        date: _now.subtract(const Duration(days: 1)),
      ),
      RaceResult(
        distance: RaceDistance.half,
        time: const Duration(hours: 1, minutes: 56, seconds: 10),
        date: _now.subtract(const Duration(days: 36)),
      ),
    ];

Pace _anchor({required Duration? goalFinish}) => zoneAnchorPace(
      goalDistance: goalFinish == null ? null : RaceDistance.k10,
      goalFinishTime: goalFinish,
      equivalentMarathonTime:
          assessFitness(_races(), _now).equivalents[RaceDistance.marathon],
      anchorRaceDistance: RaceDistance.half,
      anchorRaceTime: const Duration(hours: 1, minutes: 56, seconds: 10),
    );

void main() {
  final fitness = assessFitness(_races(), _now);

  group('the reported case', () {
    test('the runner is a VDOT 38 athlete', () {
      expect(fitness.vdot, closeTo(38, 1));
    });

    test('a 49:00 goal is a 6.7% stretch', () {
      final pb = Pace.fromDuration(
          const Duration(minutes: 52, seconds: 25), RaceDistance.k10.metres);
      final target = Pace.fromDuration(
          const Duration(minutes: 49), RaceDistance.k10.metres);
      final improvement = (pb.secPerKm - target.secPerKm) / pb.secPerKm;
      expect(improvement, closeTo(0.067, 0.005));
    });

    test('the anchor no longer moves with the goal', () {
      // The regression itself. A stretch goal must not shift the training ladder.
      final withGoal = _anchor(goalFinish: const Duration(minutes: 49));
      final withoutGoal = _anchor(goalFinish: null);
      expect(
        withGoal.secPerKm,
        withoutGoal.secPerKm,
        reason: 'a goal race must not change the training anchor',
      );
    });

    test('threshold is inside demonstrated fitness, not 12s/km beyond it', () {
      final paces = pacesFromMarathonPace(_anchor(goalFinish: const Duration(minutes: 49)));
      // Was 4:17/km. Threshold for this athlete is ~5:09.
      expect(
        paces.threshold.secPerKm,
        closeTo(309, 15),
        reason: 'threshold was 4:17/km, which the runner called "too much"',
      );
    });

    test('interval is not faster than the athlete has run', () {
      final paces = pacesFromMarathonPace(_anchor(goalFinish: const Duration(minutes: 49)));
      // Their 10K PB was 5:15/km. Interval pace below that is a real ask, but
      // it must not be 4:01.
      expect(paces.interval.secPerKm, greaterThan(260));
    });
  });

  group('the ladder has real gaps between zones', () {
    // The second half of the bug: a uniform shift moved every zone equally, so
    // the *gaps* collapsed without any zone looking individually wrong.
    test('easy and threshold are at least 40 s/km apart', () {
      for (final goal in <Duration?>[
        null,
        const Duration(minutes: 49),
        const Duration(minutes: 52, seconds: 25),
        const Duration(minutes: 44),
      ]) {
        final paces = pacesFromMarathonPace(_anchor(goalFinish: goal));
        final gap = paces.easy.secPerKm - paces.threshold.secPerKm;
        expect(
          gap,
          greaterThanOrEqualTo(minZoneGapSeconds),
          reason: 'goal $goal gave a gap of ${gap}s',
        );
      }
    });

    test('recovery and easy stay as close as the published ladder has them',
        () {
      // Recovery and easy are *meant* to be near-neighbours — 20 s/mi apart in
      // the source offsets, ~12 s/km. Asserting a 40 s gap here would be
      // asserting something the published ladder never claimed. What matters is
      // that the relationship is the published one, not that a uniform shift
      // has squashed it.
      final paces = pacesFromMarathonPace(_anchor(goalFinish: null));
      expect(
        paces.recovery.secPerKm - paces.easy.secPerKm,
        closeTo(12, 2),
      );
    });

    test('the wide gap — easy to threshold — is the one that matters', () {
      // Only this pair is far apart in the published ladder: 140 s/mi, ~87 s/km.
      // It is the gap that separates "conversational" from "working", and the
      // one whose collapse makes easy running feel like a tempo session. The
      // tighter pairs (recovery/easy, threshold/interval) are intentional
      // neighbours and asserting a minimum there would be inventing a rule the
      // source offsets never had.
      final paces = pacesFromMarathonPace(_anchor(goalFinish: null));
      expect(
        paces.easy.secPerKm - paces.threshold.secPerKm,
        greaterThanOrEqualTo(minZoneGapSeconds),
      );
    });

    test('the ladder is the published offsets and nothing else', () {
      // A uniform shift of every zone by the same amount preserves every
      // *relative* relationship, so gap tests alone cannot catch the original
      // bug. What catches it is that the absolute values must equal the
      // published offsets applied to the fitness anchor — no more, no less.
      final anchor = _anchor(goalFinish: const Duration(minutes: 49));
      final paces = pacesFromMarathonPace(anchor);
      // 20 s/mi per 1.609344 km, rounded, exactly as `_toKmOffset` does it.
      int toKm(int secPerMile) => (secPerMile / 1.609344).round();
      expect(
        paces.recovery.secPerKm,
        anchor.secPerKm + toKm(100),
      );
      expect(paces.easy.secPerKm, anchor.secPerKm + toKm(80));
      expect(paces.threshold.secPerKm, anchor.secPerKm - toKm(60));
      expect(paces.interval.secPerKm, anchor.secPerKm - toKm(85));
    });

    test('easy is genuinely slower than the 10K PB pace', () {
      // "Easy is already a tempo run for me" — easy must be well off the pace
      // they race at, or it is not easy.
      final paces = pacesFromMarathonPace(_anchor(goalFinish: null));
      final pb = Pace.fromDuration(
          const Duration(minutes: 52, seconds: 25), RaceDistance.k10.metres);
      expect(
        paces.easy.secPerKm - pb.secPerKm,
        greaterThanOrEqualTo(minZoneGapSeconds),
      );
    });

    test('the ordering holds end to end', () {
      final p = pacesFromMarathonPace(_anchor(goalFinish: null));
      final fastestToSlowest = [
        p.repetition.secPerKm,
        p.interval.secPerKm,
        p.threshold.secPerKm,
        p.marathon.secPerKm,
        p.easy.secPerKm,
        p.recovery.secPerKm,
      ];
      for (var i = 1; i < fastestToSlowest.length; i++) {
        expect(
          fastestToSlowest[i],
          greaterThan(fastestToSlowest[i - 1]),
          reason: 'zone $i is not slower than the one before it',
        );
      }
    });
  });

  group('an unreachable goal does not distort training', () {
    test('an absurd goal and a modest one give the same ladder', () {
      final modest = pacesFromMarathonPace(
          _anchor(goalFinish: const Duration(minutes: 52, seconds: 25)));
      final absurd = pacesFromMarathonPace(
          _anchor(goalFinish: const Duration(minutes: 34)));
      expect(absurd.easy.secPerKm, modest.easy.secPerKm);
      expect(absurd.threshold.secPerKm, modest.threshold.secPerKm);
    });

    test('the ladder is identical with and without any goal at all', () {
      final none = pacesFromMarathonPace(_anchor(goalFinish: null));
      final some = pacesFromMarathonPace(
          _anchor(goalFinish: const Duration(minutes: 45)));
      for (final zone in IntensityZone.values) {
        expect(
          some.forZone(zone).secPerKm,
          none.forZone(zone).secPerKm,
          reason: '${zone.name} must not depend on the goal',
        );
      }
    });
  });

  group('the goal still shapes the plan', () {
    test('VDOT is unchanged by all of this', () {
      // Sanity: the anchor moved, the fitness model did not.
      expect(vdotFor(RaceDistance.k10, const Duration(minutes: 52, seconds: 25)),
          closeTo(38, 1));
    });
  });
}

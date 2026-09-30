/// Rep formats, and the two ways the app used to make them unreachable.
///
/// Every assertion here is about output the runner reads. A rep format that is
/// merely *representable* — a field on the model, a function that solves one —
/// is not the same as a plan that contains it, and the two failures below were
/// both invisible to the whole suite: the plans generated, every volume
/// invariant passed, and the runner was simply handed twelve tempos.
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:ai_running_trainer/domain/plan/race_plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The reported case: 45 km a week, four days, no race on the calendar.
RunnerProfile _noGoalRunner({double km = 45, int days = 4}) =>
    RunnerProfile(
      name: 'Sam',
      age: 34,
      gender: Gender.preferNotToSay,
      monthsRunning: 36,
      daysPerWeek: days,
      estimatedWeeklyKm: km,
    );

List<RaceResult> _races() => [raceK10(const Duration(minutes: 45))];

TrainingPlan _noGoalPlan({double km = 45, int days = 4}) => generate(
      profile: _noGoalRunner(km: km, days: days),
      races: _races(),
      goal: null,
      startDate: testToday,
    );

Iterable<Workout> _sets(TrainingPlan p) => p.weeks
    .expand((w) => w.workouts)
    .where((w) => w.type == WorkoutType.intervals);

/// The paces a trained 45 km runner trains on: a 45-minute 10K.
final _paces = derivePaces(
  fitness: assessFitness([raceK10(const Duration(minutes: 45))], testToday),
  goal: null,
  beginner: false,
);

void main() {
  group('a runner with no goal race still gets rep work', () {
    // The original report: 45 km a week, four days, nothing to race, and the
    // only hard running in twelve weeks was a threshold block. A flat
    // `List.filled(12, PlanPhase.base)` made that structural — no goal race was
    // not a reason to stop doing repetition work, only a reason not to
    // periodise toward a finish line.
    final plan = _noGoalPlan();

    test('the block contains repetition sessions', () {
      expect(_sets(plan), isNotEmpty,
          reason: 'a trained runner with no goal is not a beginner');
    });

    test('and more than one of them', () {
      expect(_sets(plan).length, greaterThanOrEqualTo(2));
    });

    test('and more than one rep distance, so the work is not repetitive', () {
      final distances = _sets(plan).map((w) => w.repDistanceM).toSet();
      expect(distances.length, greaterThanOrEqualTo(2),
          reason: 'got $distances');
    });

    test('the block is not twelve identical weeks', () {
      final descriptions =
          plan.weeks.expand((w) => w.workouts).map((w) => w.title).toSet();
      expect(descriptions.length, greaterThanOrEqualTo(3));
    });

    test('every set carries its structure on the workout itself', () {
      for (final w in _sets(plan)) {
        expect(w.reps, isNotNull, reason: w.title);
        expect(w.repDistanceM, isNotNull, reason: w.title);
        expect(w.repRecovery, isNotNull, reason: w.title);
      }
    });
  });

  group('the hard fraction is derived, not assumed', () {
    // 0.32 was a single flat constant applied to every interval session. It is
    // roughly right for one specific format — 3 min on / 3 min jog — and wrong
    // by a wide margin for everything else. Reading a 400m set as 32% hard made
    // `hardVolumeKm`, and therefore the 80/20 check, a fiction.
    final paces = _paces;

    test('a 400m set with 90s recovery is far harder than 0.32 says', () {
      final fraction = hardFractionForReps(
        reps: 10,
        repDistanceM: 400,
        repWork: null,
        recovery: const Duration(seconds: 90),
        repPaceSecondsPerKm: paces.interval.secPerKm.toDouble(),
        easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
      );
      // The content of the assertion is the gap from the old constant, not the
      // absolute value: at 90s recovery a short-rep set spends most of its
      // distance above easy pace, and 0.32 understated that by roughly a third.
      expect(fraction, greaterThan(intervalHardFraction * 1.25));
      expect(fraction, isNot(closeTo(intervalHardFraction, 0.05)));
    });

    test('a long set is harder still than a short one', () {
      double fraction(int m, int reps) => hardFractionForReps(
            reps: reps,
            repDistanceM: m,
            repWork: null,
            recovery: const Duration(seconds: 90),
            repPaceSecondsPerKm: paces.forZone(m > 1000
                    ? IntensityZone.threshold
                    : IntensityZone.interval)
                .secPerKm
                .toDouble(),
            easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
          );

      expect(fraction(2000, 3), greaterThan(fraction(400, 10)));
    });

    test('every generated set reports the derived value', () {
      for (final plan in [
        _noGoalPlan(),
        _noGoalPlan(km: 70, days: 5),
        _withGoal(),
      ]) {
        for (final w in _sets(plan)) {
          final expected = hardFractionForReps(
            reps: w.reps!,
            repDistanceM: w.repDistanceM,
            repWork: null,
            recovery: w.repRecovery!,
            repPaceSecondsPerKm:
                paces.forZone(w.repZone!).secPerKm.toDouble(),
            easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
          );
          expect(w.hardFractionOfDistance, closeTo(expected, 0.01),
              reason: '${w.title} in week ${w.title}');
        }
      }
    });
  });

  group('a solved set fits the week it was prescribed for', () {
    final paces = _paces;

    test('the rep count is what the room allows, not a constant', () {
      // Fixing the count would mean the session's distance had to come from
      // somewhere else, and then the week would stop adding up.
      final big = solveSet(
        RepFormat(
          distanceM: 400,
          recovery: const Duration(seconds: 90),
          zone: IntensityZone.interval,
        ),
        9,
        paces,
      )!;
      final small = solveSet(
        RepFormat(
          distanceM: 400,
          recovery: const Duration(seconds: 90),
          zone: IntensityZone.interval,
        ),
        5,
        paces,
      )!;
      expect(big.reps, greaterThan(small.reps));
      expect(big.distanceKm, lessThanOrEqualTo(9));
      expect(small.distanceKm, lessThanOrEqualTo(5));
    });

    test('a set that cannot reach three reps is not prescribed at all', () {
      final solved = solveSet(
        RepFormat(
          distanceM: 2000,
          recovery: const Duration(seconds: 180),
          zone: IntensityZone.threshold,
        ),
        1.0,
        paces,
      );
      expect(solved, isNull);
    });

    test('a week too small for a 400m set gets a shorter one, not a cut one',
        () {
      final solved = solveFormatSet(6, paces);
      expect(solved, isNotNull);
      expect(solved!.reps, greaterThanOrEqualTo(3),
          reason: 'a truncated set is not a set');
    });

    test('the 400m set is gated on a week big enough to absorb it', () {
      // Sharpest session the app can hand out, so it is gated the same way
      // `longRunShare` is day-aware: against the smallest week that can hold it.
      expect(solveFormatSet(9, paces)!.format.distanceM, 400);
      expect(
        solveFormatSet(9, paces, from: 1)!.format.distanceM,
        isNot(400),
        reason: 'a runner below the volume floor must not get 400m reps',
      );
    });

    test('no generated plan prescribes 400m reps below the volume floor', () {
      for (final w in _noGoalPlan(km: 25).weeks) {
        for (final s in w.workouts) {
          if (s.type != WorkoutType.intervals) continue;
          expect(
            s.repDistanceM == 400 && w.targetVolumeKm < minVolumeForSharpReps,
            isFalse,
            reason: 'week ${w.weekNumber} prescribed 400m reps at '
                '${w.targetVolumeKm.toStringAsFixed(1)} km',
          );
        }
      }
    });
  });

  group('rep structure survives the safety pass', () {
    // `enforceSafety` and `attachWeekdays` both rebuild a `Workout`. When
    // `_withWeekday` was a hand-written copy of the field list it dropped every
    // field added afterwards, and a session titled "800 m reps" was rendered
    // with no reps on it. The title still looked right, so nothing reported it.
    test('a set keeps its reps after enforcement', () {
      for (final plan in [_noGoalPlan(), _withGoal()]) {
        for (final week in plan.weeks) {
          for (final w in week.workouts) {
            if (w.type != WorkoutType.intervals) continue;
            expect(w.reps, isNotNull, reason: 'week ${week.weekNumber}');
            expect(w.repDistanceM, isNotNull, reason: 'week ${week.weekNumber}');
            expect(w.repRecovery, isNotNull, reason: 'week ${week.weekNumber}');
          }
        }
      }
    });

    test('withWeekday carries every field', () {
      const w = Workout(
        title: '800 m reps',
        type: WorkoutType.intervals,
        zone: IntensityZone.interval,
        description: '',
        reps: 8,
        repDistanceM: 800,
        repRecovery: Duration(seconds: 90),
        repZone: IntensityZone.interval,
      );
      final moved = w.withWeekday(3);
      expect(moved.reps, 8);
      expect(moved.repDistanceM, 800);
      expect(moved.repRecovery, const Duration(seconds: 90));
      expect(moved.repZone, IntensityZone.interval);
      expect(moved.weekday, 3);
    });
  });

  group('a week has exactly as many quality sessions as it budgets for', () {
    // The failure this pins: `qualitySessionsFor` returned 2 for a four-day
    // specific week and the placement guard could not fire below five days —
    // index 3 is the long run on `[1,3,5,7]`. The second session fell through
    // to the easy branch. The week still summed to its target, so every
    // invariant passed and the runner got one tempo and one easy run where the
    // arithmetic had budgeted two hard sessions.
    //
    // A base block is one quality session a week at any day count, which is a
    // design choice rather than an accident: there is no peak to prepare for, so
    // a second hard day would be hard work with nothing behind it.
    int expected(PlanWeek w, {required bool goalBlock}) {
      if (w.isCutback) return 0;
      if (w.phase == PlanPhase.baseBlock) return 0;
      // The race is flagged as quality: it is the hardest thing in that week by
      // a wide margin, and a session log that treated it as an easy day would
      // misreport the week entirely.
      if (w.phase == PlanPhase.raceWeek) return 1;
      if (!goalBlock) return 1;
      return qualitySessionsFor(w.phase, w.runCount);
    }

    for (final days in [3, 4, 5, 6]) {
      test('at $days days a week', () {
        final plans = <TrainingPlan, bool>{
          _noGoalPlan(days: days): false,
          generate(
            profile: _noGoalRunner(days: days),
            races: _races(),
            goal: goal(RaceDistance.k10,
                finishTime: const Duration(minutes: 45), inWeeks: 16),
            startDate: testToday,
          ): true,
        };
        plans.forEach((plan, isGoalBlock) {
          for (final w in plan.weeks) {
            // The final taper week carries one goal-pace session by design.
            if (w.phase == PlanPhase.taper) {
              expect(w.qualityCount, lessThanOrEqualTo(1),
                  reason: 'week ${w.weekNumber}');
              continue;
            }
            expect(w.qualityCount, expected(w, goalBlock: isGoalBlock),
                reason: 'week ${w.weekNumber} (${w.phase.name}, '
                    '${w.runCount} days, goal=$isGoalBlock)');
          }
        });
      });
    }

    test('and no more than one rep set in a week', () {
      // Two sets pushed `easyFraction` to 0.75 against a 0.77 floor. A
      // double-quality week is tempo plus set.
      for (final plan in [
        _noGoalPlan(days: 5),
        _noGoalPlan(days: 6),
        _withGoal(),
      ]) {
        for (final w in plan.weeks) {
          final sets =
              w.workouts.where((s) => s.type == WorkoutType.intervals).length;
          expect(sets, lessThanOrEqualTo(1),
              reason: 'week ${w.weekNumber} has $sets sets');
        }
      }
    });
  });

  group('the set week does not depend on the block length', () {
    // The alternation used to be on the absolute plan week, so the number of
    // set sessions depended on where the base/specific boundary landed after
    // rounding. Change the block length by one and the count moved for no
    // reason the runner could see.
    int setWeeks(TrainingPlan p) => p.weeks
        .where((w) =>
            w.workouts.any((s) => s.type == WorkoutType.intervals))
        .length;

    test('a one-week difference in runway does not halve the set count', () {
      final a = generate(
        profile: _noGoalRunner(),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50), inWeeks: 14),
        startDate: testToday,
      );
      final b = generate(
        profile: _noGoalRunner(),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50), inWeeks: 15),
        startDate: testToday,
      );
      expect((setWeeks(a) - setWeeks(b)).abs(), lessThanOrEqualTo(1),
          reason: 'got ${setWeeks(a)} and ${setWeeks(b)}');
    });
  });
}

TrainingPlan _withGoal() => generate(
      profile: _noGoalRunner(),
      races: _races(),
      goal: goal(RaceDistance.half,
          finishTime: const Duration(hours: 1, minutes: 50), inWeeks: 16),
      startDate: testToday,
    );

/// The invariant that was missing while a trained runner received twelve weeks
/// with no hard sessions in them.
///
/// Every assertion here is about the *output*: a plan is either a trained plan
/// with quality work, or a beginner block without any. The middle case — a
/// trained plan that has quietly lost its quality sessions — was reachable and
/// undetected, and the unit ambiguity in the experience counter was what
/// reached it.
library;

import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

bool _isHard(Workout w) =>
    w.type == WorkoutType.tempo || w.type == WorkoutType.intervals;

/// Weeks that are supposed to carry quality work.
///
/// Cutbacks and the taper deliberately drop it — a cutback is a deload and the
/// taper is about arriving fresh — so neither is a violation.
bool _expectsQuality(PlanWeek w) =>
    !w.isCutback &&
    w.phase != PlanPhase.taper &&
    w.phase != PlanPhase.raceWeek;

final _trained = RunnerProfile(
  name: 'Mark',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 36,
  daysPerWeek: 4,
  estimatedWeeklyKm: 35,
);

final _races = <RaceResult>[
  RaceResult(
    distance: RaceDistance.half,
    time: const Duration(hours: 1, minutes: 56, seconds: 10),
    date: DateTime.now().subtract(const Duration(days: 36)),
  ),
  RaceResult(
    distance: RaceDistance.k10,
    time: const Duration(minutes: 52, seconds: 25),
    date: DateTime.now().subtract(const Duration(days: 1)),
  ),
];

GoalRace _goal() => GoalRace(
      distance: RaceDistance.k10,
      date: DateTime.now().add(const Duration(days: 120)),
      finishTimeGoal: const Duration(minutes: 49),
      daysPerWeek: 4,
    );

void main() {
  group('a trained plan always has hard sessions', () {
    test('base block, no goal race', () {
      final plan = generate(
        profile: _trained,
        races: _races,
        goal: null,
        startDate: testToday,
      );
      expect(plan.path, TrainingPath.trainedRace);
      for (final w in plan.weeks) {
        if (!_expectsQuality(w)) continue;
        expect(
          w.workouts.any(_isHard),
          isTrue,
          reason: 'week ${w.weekNumber} (${w.phase.name}) has no hard session: '
              '${w.workouts.map((s) => s.type.name)}',
        );
      }
    });

    test('race block', () {
      final plan = generate(
        profile: _trained,
        races: _races,
        goal: _goal(),
        startDate: testToday,
      );
      for (final w in plan.weeks) {
        if (!_expectsQuality(w)) continue;
        expect(
          w.workouts.any(_isHard),
          isTrue,
          reason: 'week ${w.weekNumber} (${w.phase.name}) has no hard session',
        );
      }
    });

    test('at three days a week, where the tempo is the only quality session',
        () {
      // The tightest case. Here dropping quality leaves an all-easy week, which
      // is why `suppressQuality` is too blunt at this day count.
      final plan = generate(
        profile: _trained.copyWith(daysPerWeek: 3),
        races: _races,
        goal: _goal().copyWith(daysPerWeek: 3),
        startDate: testToday,
      );
      for (final w in plan.weeks) {
        if (!_expectsQuality(w)) continue;
        expect(
          w.workouts.any(_isHard),
          isTrue,
          reason: 'three-day week ${w.weekNumber} lost its only hard session',
        );
      }
    });

    test('at five and six days a week', () {
      for (final days in [5, 6]) {
        final plan = generate(
          profile: _trained.copyWith(daysPerWeek: days),
          races: _races,
          goal: _goal().copyWith(daysPerWeek: days),
          startDate: testToday,
        );
        for (final w in plan.weeks) {
          if (!_expectsQuality(w)) continue;
          expect(
            w.workouts.any(_isHard),
            isTrue,
            reason: '$days-day week ${w.weekNumber} lost its hard session',
          );
        }
      }
    });
  });

  group('a beginner block has none, and that is the only such plan', () {
    test('the beginner base block carries zero hard sessions', () {
      // The documented safety property. It is what makes the trained-plan
      // assertions above meaningful: a plan is one or the other.
      final plan = generate(
        profile: const RunnerProfile(
          name: 'New',
          age: 27,
          gender: Gender.preferNotToSay,
          monthsRunning: 3,
          daysPerWeek: 3,
        ),
        races: const [],
        goal: null,
        startDate: testToday,
      );
      expect(plan.path, TrainingPath.beginnerBase);
      for (final w in plan.weeks) {
        expect(w.workouts.any(_isHard), isFalse);
      }
    });

    test('so the two paths are distinguishable by construction', () {
      final beginner = generate(
        profile: _trained.copyWith(monthsRunning: 3),
        races: _races,
        goal: null,
        startDate: testToday,
      );
      final trained = generate(
        profile: _trained,
        races: _races,
        goal: null,
        startDate: testToday,
      );
      expect(beginner.path, TrainingPath.beginnerBase);
      expect(trained.path, TrainingPath.trainedRace);
      expect(
        trained.weeks.any((w) => w.workouts.any(_isHard)),
        isTrue,
        reason: 'the two paths must differ in exactly the way that matters',
      );
    });
  });

  group('the reported runner, exactly as stored', () {
    // Straight from the device diagnostic: monthsRunning was 3 instead of 36.
    // Everything else was correct and could not save them.
    test('monthsRunning=3 strips a three-year runner of all hard sessions', () {
      final plan = generate(
        profile: _trained.copyWith(monthsRunning: 3),
        races: _races,
        goal: _goal(),
        startDate: testToday,
      );
      expect(plan.path, TrainingPath.beginnerBase);
      final hard = plan.weeks
          .where((w) => w.workouts.any(_isHard))
          .length;
      expect(hard, lessThanOrEqualTo(1), reason: 'only the race week');
    });

    test('monthsRunning=36 gives the same runner their hard sessions back', () {
      final plan = generate(
        profile: _trained,
        races: _races,
        goal: _goal(),
        startDate: testToday,
      );
      expect(plan.path, TrainingPath.trainedRace);
      final hard = plan.weeks
          .where((w) => w.workouts.any(_isHard))
          .length;
      expect(hard, greaterThanOrEqualTo(8),
          reason: 'a periodised block is mostly hard-session weeks');
    });
  });

  group('the week-over-volume invariant still holds', () {
    test('and quality weeks stay inside the easy-share rule', () {
      for (final days in [3, 4, 5, 6]) {
        final plan = generate(
          profile: _trained.copyWith(daysPerWeek: days),
          races: _races,
          goal: _goal().copyWith(daysPerWeek: days),
          startDate: testToday,
        );
        for (final w in plan.weeks) {
          if (w.phase == PlanPhase.raceWeek) continue;
          expect(satisfiesEasyRule(w), isTrue,
              reason: '$days-day week ${w.weekNumber}');
        }
      }
    });
  });
}

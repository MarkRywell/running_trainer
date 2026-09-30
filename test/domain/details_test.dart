/// Phase 7: editing the runner's own details, and the three ways to redo a plan.
///
/// The distinction these tests exist to protect is between an **edit** and a
/// **restart**. An edit must keep the weeks already logged, because completion is
/// keyed on week-start dates and the start date does not move. A restart must
/// clear them, because new start dates mean new keys and carrying the old ones
/// across would credit a fresh block with work done in the last one.
library;

import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:ai_running_trainer/domain/progress.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

const _volume15 = RunnerProfile(
  name: 'Sam',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 24,
  daysPerWeek: 3,
  estimatedWeeklyKm: 15,
);

void main() {
  group('RunnerProfile.copyWith', () {
    test('an omitted optional field is left alone', () {
      final p = _volume15.copyWith(age: 35);
      expect(p.age, 35);
      expect(p.estimatedWeeklyKm, 15);
    });

    test('an optional field can be set', () {
      final p = _volume15.copyWith(estimatedWeeklyKm: const Optional(42));
      expect(p.estimatedWeeklyKm, 42);
    });

    test('an optional field can be cleared back to null', () {
      // The whole reason for the wrapper. With a plain `double?` parameter,
      // `null` means "leave alone" and there is no way to express "the runner
      // removed this" — so a form could set a value but never clear one.
      final cleared = _volume15.copyWith(estimatedWeeklyKm: const Optional(null));
      expect(cleared.estimatedWeeklyKm, isNull);
    });

    test('cleared reports only what it cleared', () {
      final p = _volume15.cleared(weeklyKm: true);
      expect(p.estimatedWeeklyKm, isNull);
      expect(p.name, 'Sam');
      expect(p.daysPerWeek, 3);
    });
  });

  group('weekly volume is what the plan starts from', () {
    test('a stated volume seeds the plan instead of the race-time guess', () {
      // The bug this field was missing for: a 52:25 10K implies ~31 km/week, so
      // a runner who actually does 15 was handed a 30 km opening week.
      final guess = generate(
        profile: _volume15.cleared(weeklyKm: true),
        races: [raceK10(const Duration(minutes: 52, seconds: 25))],
        goal: null,
        startDate: testToday,
      );
      final stated = generate(
        profile: _volume15,
        races: [raceK10(const Duration(minutes: 52, seconds: 25))],
        goal: null,
        startDate: testToday,
      );

      expect(stated.weeks.first.targetVolumeKm, lessThan(20));
      expect(
        guess.weeks.first.targetVolumeKm,
        greaterThan(stated.weeks.first.targetVolumeKm * 1.4),
        reason: 'the guess really is the thing that was over-prescribing',
      );
    });

    test('a stated volume caps growth just as the guess does', () {
      final plan = generate(
        profile: _volume15,
        races: [raceK10(const Duration(minutes: 52, seconds: 25))],
        goal: null,
        startDate: testToday,
      );
      // weeklyVolumeCeiling allows current + 35%.
      for (final w in plan.weeks) {
        expect(
          w.targetVolumeKm,
          lessThanOrEqualTo(15 * 1.35 + 0.01),
          reason: 'week ${w.weekNumber}',
        );
      }
    });
  });

  group('week keys are what make an edit safe', () {
    test('the same start date produces the same keys', () {
      final a = generate(
        profile: _volume15,
        races: const [],
        goal: null,
        startDate: testToday,
      );
      final b = generate(
        profile: _volume15.cleared(weeklyKm: true),
        races: const [],
        goal: null,
        startDate: testToday,
      );
      expect(
        a.weeks.map((w) => weekKey(w.startDate)),
        b.weeks.map((w) => weekKey(w.startDate)),
      );
    });

    test('a different start date produces different keys', () {
      // Which is exactly why a restart cannot keep the old logs: they would be
      // filed against weeks that do not exist.
      final a = generate(
        profile: _volume15,
        races: const [],
        goal: null,
        startDate: testToday,
      );
      final b = generate(
        profile: _volume15,
        races: const [],
        goal: null,
        startDate: testToday.add(const Duration(days: 7)),
      );
      expect(
        a.weeks.map((w) => weekKey(w.startDate)),
        isNot(b.weeks.map((w) => weekKey(w.startDate))),
      );
    });
  });

  group('a goal date in the past', () {
    test('still produces a usable plan rather than throwing', () {
      // Editing details can leave a stale goal behind. The plan must survive it;
      // the validation layer is what warns, not a crash.
      final plan = generate(
        profile: _volume15,
        races: [raceK10(const Duration(minutes: 52, seconds: 25))],
        goal: GoalRace(
          distance: RaceDistance.marathon,
          date: testToday.subtract(const Duration(days: 30)),
          finishTimeGoal: const Duration(hours: 3, minutes: 30),
          daysPerWeek: 3,
        ),
        startDate: testToday,
      );
      expect(plan.weekCount, greaterThan(0));
    });
  });

  group('WeekLog stays the unit of record', () {
    test('a log keyed to a real week reads back', () {
      final plan = generate(
        profile: _volume15,
        races: const [],
        goal: null,
        startDate: testToday,
      );
      final logs = {
        weekKey(plan.weeks[0].startDate):
            const WeekLog(completed: true, difficulty: 4),
      };
      final progress = PlanProgress(plan: plan, weekLogs: logs);
      expect(progress.isComplete(0), isTrue);
      expect(progress.completedCount, 1);
    });
  });
}

import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:ai_running_trainer/domain/progress.dart';
import 'package:ai_running_trainer/domain/units.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Builds a plan truncated to [weeks] weeks starting on [start].
TrainingPlan planOf(int weeks, DateTime start) {
  final full = generate(
    profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
    races: [raceK10(const Duration(minutes: 45))],
    goal: goal(
      RaceDistance.marathon,
      finishTime: const Duration(hours: 3, minutes: 40),
      inWeeks: 18,
    ),
    startDate: start,
  );
  return TrainingPlan(
    path: full.path,
    weeks: full.weeks.take(weeks).toList(),
    paces: full.paces,
    weeklyVolumeKm: full.weeklyVolumeKm,
    startDate: start,
    goal: full.goal,
    flags: full.flags,
  );
}

DateTime mondayAfter(DateTime d) {
  final x = DateTime(d.year, d.month, d.day);
  return x.add(Duration(days: 7 - x.weekday));
}

/// Builds a log map marking each given week-start key as completed.
///
/// Keeps the completion tests readable now that a log is a record rather than
/// a bare boolean.
Map<String, WeekLog> logs(Set<String> keys) => {
      for (final k in keys) k: const WeekLog(completed: true),
    };

void main() {
  final start = DateTime(2026, 3, 2); // a Monday

  group('weekKey', () {
    test('is stable and zero-padded', () {
      expect(weekKey(DateTime(2026, 3, 2)), '2026-03-02');
      expect(weekKey(DateTime(2026, 12, 25)), '2026-12-25');
    });

    test('distinguishes different weeks', () {
      expect(weekKey(start), isNot(weekKey(start.add(const Duration(days: 7)))));
    });
  });

  group('completion', () {
    test('nothing is complete by default', () {
      final p = planOf(8, start);
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      expect(prog.completedCount, 0);
      expect(prog.firstIncompleteIndex, 0);
      expect(prog.isFinished, isFalse);
    });

    test('marks by week start date, not position', () {
      final p = planOf(8, start);
      final keys = {
        weekKey(p.weeks[0].startDate),
        weekKey(p.weeks[1].startDate),
      };
      final prog = PlanProgress(plan: p, weekLogs: logs(keys), now: start);
      expect(prog.isComplete(0), isTrue);
      expect(prog.isComplete(1), isTrue);
      expect(prog.isComplete(2), isFalse);
      expect(prog.completedCount, 2);
    });

    test('ignores keys for weeks that do not exist', () {
      final p = planOf(4, start);
      final stray = {weekKey(start.add(const Duration(days: 400)))};
      final prog = PlanProgress(plan: p, weekLogs: logs(stray), now: start);
      expect(prog.completedCount, 0);
    });

    test('isFinished only when every week is done', () {
      final p = planOf(3, start);
      final all = {for (final w in p.weeks) weekKey(w.startDate)};
      expect(
        PlanProgress(plan: p, weekLogs: logs(all), now: start).isFinished,
        isTrue,
      );
      final partial = {weekKey(p.weeks[0].startDate)};
      expect(
        PlanProgress(plan: p, weekLogs: logs(partial), now: start).isFinished,
        isFalse,
      );
    });
  });

  group('calendarWeekIndex', () {
    final p = planOf(8, start);

    test('is week 1 on the plan start date', () {
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      expect(prog.calendarWeekIndex, 0);
    });

    test('advances through the block', () {
      for (var w = 0; w < 8; w++) {
        final prog = PlanProgress(
          plan: p,
          weekLogs: const {},
          now: start.add(Duration(days: 7 * w + 3)),
        );
        expect(prog.calendarWeekIndex, w, reason: 'week $w');
      }
    });

    test('clamps to the last week once the block has ended', () {
      final prog = PlanProgress(
        plan: p,
        weekLogs: const {},
        now: start.add(const Duration(days: 7 * 30)),
      );
      expect(prog.calendarWeekIndex, 7);
    });

    test('stays at week 1 before the plan starts', () {
      final prog = PlanProgress(
        plan: p,
        weekLogs: const {},
        now: start.subtract(const Duration(days: 30)),
      );
      expect(prog.calendarWeekIndex, 0);
    });
  });

  group('missed weeks', () {
    test('nothing missed at the start', () {
      final p = planOf(8, start);
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      expect(prog.missedWeekCount, 0);
    });

    test('counts unlogged past weeks, not future ones', () {
      final p = planOf(8, start);
      // Five weeks in, nothing done: the four before this one are missed, and
      // neither this week nor any future week counts.
      final prog = PlanProgress(
        plan: p,
        weekLogs: const {},
        now: start.add(const Duration(days: 7 * 4 + 2)),
      );
      expect(prog.calendarWeekIndex, 4);
      expect(prog.missedWeekCount, 4);
    });

    test('partially logged weeks are not counted as missed', () {
      final p = planOf(8, start);
      final keys = {
        weekKey(p.weeks[0].startDate),
        weekKey(p.weeks[1].startDate),
      };
      final prog = PlanProgress(
        plan: p,
        weekLogs: logs(keys),
        now: start.add(const Duration(days: 7 * 4 + 2)),
      );
      expect(prog.missedWeekCount, 2);
    });
  });

  group('suggestedWeekIndex — the returning-after-a-month case', () {
    test('a runner returning weeks later is put back on the first missed week',
        () {
      final p = planOf(12, start);
      // A month later, nothing logged. The calendar says week 5, but they
      // have done none of it, so they should be on week 1.
      final prog = PlanProgress(
        plan: p,
        weekLogs: const {},
        now: start.add(const Duration(days: 7 * 4 + 2)),
      );
      expect(prog.calendarWeekIndex, 4);
      expect(prog.missedWeekCount, 4);
      expect(prog.suggestedWeekIndex, 0);
    });

    test('goes back to the first gap, not to week 1', () {
      final p = planOf(12, start);
      // Weeks 1 and 2 done, then nothing: back to week 3.
      final keys = {
        weekKey(p.weeks[0].startDate),
        weekKey(p.weeks[1].startDate),
      };
      final prog = PlanProgress(
        plan: p,
        weekLogs: logs(keys),
        now: start.add(const Duration(days: 7 * 5 + 1)),
      );
      expect(prog.suggestedWeekIndex, 2);
    });

    test('a runner on track is left alone', () {
      final p = planOf(12, start);
      final keys = {
        weekKey(p.weeks[0].startDate),
        weekKey(p.weeks[1].startDate),
        weekKey(p.weeks[2].startDate),
      };
      final prog = PlanProgress(
        plan: p,
        weekLogs: logs(keys),
        now: start.add(const Duration(days: 7 * 3 + 1)),
      );
      // The week in progress is not "missed" — only weeks strictly before it.
      expect(prog.missedWeekCount, 0);
      expect(prog.suggestedWeekIndex, 3);
    });

    test('a runner ahead of the calendar is not dragged backwards', () {
      final p = planOf(12, start);
      // Finished 4 weeks while still inside week 2.
      final keys = {
        for (var i = 0; i < 4; i++) weekKey(p.weeks[i].startDate),
      };
      final prog = PlanProgress(
        plan: p,
        weekLogs: logs(keys),
        now: start.add(const Duration(days: 7 * 1 + 2)),
      );
      expect(prog.missedWeekCount, 0);
      // Calendar says week 2, but they have done four, so week 5.
      expect(prog.suggestedWeekIndex, 4);
    });

    test('a finished block stays on the last week', () {
      final p = planOf(6, start);
      final all = {for (final w in p.weeks) weekKey(w.startDate)};
      final prog = PlanProgress(
        plan: p,
        weekLogs: logs(all),
        now: start.add(const Duration(days: 21)),
      );
      expect(prog.isFinished, isTrue);
      expect(prog.suggestedWeekIndex, 5);
    });
  });

  group('provisional weeks', () {
    test('a week before any gap is real', () {
      final p = planOf(8, start);
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      expect(prog.isProvisional(0), isFalse);
      expect(prog.isProvisional(1), isTrue);
      expect(prog.outstandingBefore(0), 0);
    });

    test('becomes real once the earlier week is done', () {
      final p = planOf(8, start);
      final keys = {weekKey(p.weeks[0].startDate)};
      final prog = PlanProgress(plan: p, weekLogs: logs(keys), now: start);
      expect(prog.isProvisional(0), isFalse);
      expect(prog.isProvisional(1), isFalse);
      expect(prog.isProvisional(2), isTrue);
    });

    test('counts how many earlier weeks are outstanding', () {
      final p = planOf(8, start);
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      expect(prog.outstandingBefore(3), 3);
    });
  });

  group('across plan regeneration', () {
    test('completion survives a goal change because it keys on dates',
        () {
      // This is the whole reason completion is not keyed on week number.
      final before = planOf(12, start);
      final keys = {
        weekKey(before.weeks[0].startDate),
        weekKey(before.weeks[1].startDate),
        weekKey(before.weeks[2].startDate),
      };

      // Regenerate with a different goal — a real regeneration may produce
      // a different number of weeks.
      final after = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(
          RaceDistance.half,
          finishTime: const Duration(hours: 1, minutes: 40),
          inWeeks: 10,
        ),
        startDate: start,
      );

      final prog = PlanProgress(plan: after, weekLogs: logs(keys), now: start);
      expect(prog.completedCount, 3);
      expect(prog.firstIncompleteIndex, 3);
    });
  });

  group('adherence and difficulty signals', () {
    Map<String, WeekLog> logged(TrainingPlan p, List<WeekLog> byIndex) => {
          for (var i = 0; i < byIndex.length; i++)
            weekKey(p.weeks[i].startDate): byIndex[i],
        };

    test('adherence is null when nothing is recorded', () {
      final p = planOf(6, start);
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      // "No data" must not read as 0%.
      expect(prog.sessionAdherence, isNull);
      expect(prog.volumeAdherence, isNull);
      expect(prog.averageDifficulty, isNull);
    });

    test('session adherence compares done against prescribed', () {
      final p = planOf(6, start);
      // Week 1 prescribes 4 sessions (trained, 4 days), week 2 also 4.
      final prog = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [
          WeekLog(completed: true, sessionsDone: 4),
          WeekLog(completed: true, sessionsDone: 2),
        ]),
        now: start,
      );
      expect(prog.sessionsLogged, 6);
      expect(prog.sessionsPrescribedInLoggedWeeks, p.weeks[0].runCount * 2);
      expect(prog.sessionAdherence, closeTo(6 / (p.weeks[0].runCount * 2), 0.001));
    });

    test('volume adherence compares actual against prescribed', () {
      final p = planOf(6, start);
      final target = p.weeks[0].targetVolumeKm;
      final prog = PlanProgress(
        plan: p,
        weekLogs: logged(p, [
          WeekLog(completed: true, actualKm: target * 0.8),
        ]),
        now: start,
      );
      expect(prog.volumeAdherence, closeTo(0.8, 0.01));
    });

    test('a partially logged plan only counts the logged weeks', () {
      final p = planOf(8, start);
      final prog = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [WeekLog(completed: true, actualKm: 40)]),
        now: start,
      );
      // The other seven weeks must not drag the denominator in.
      expect(prog.kmPrescribedInLoggedWeeks, p.weeks[0].targetVolumeKm);
    });

    test('average difficulty ignores unrated weeks', () {
      final p = planOf(6, start);
      final prog = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [
          WeekLog(completed: true, difficulty: 6),
          WeekLog(completed: true, difficulty: 8),
          WeekLog(completed: true),
        ]),
        now: start,
      );
      expect(prog.averageDifficulty, 7.0);
    });

    test('hardWeeks lists the weeks that felt too hard', () {
      final p = planOf(6, start);
      final prog = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [
          WeekLog(completed: true, difficulty: 8),
          WeekLog(completed: true, difficulty: 5),
          WeekLog(completed: true, difficulty: 9),
        ]),
        now: start,
      );
      expect(prog.hardWeeks, [0, 2]);
    });

    test('looksTooHard needs three hard weeks and a high average', () {
      final p = planOf(10, start);
      // Three hard weeks: the block is miscalibrated.
      final hard = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [
          WeekLog(completed: true, difficulty: 8),
          WeekLog(completed: true, difficulty: 9),
          WeekLog(completed: true, difficulty: 8),
        ]),
        now: start,
      );
      expect(hard.looksTooHard, isTrue);

      // Only two hard weeks is not enough signal.
      final two = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [
          WeekLog(completed: true, difficulty: 8),
          WeekLog(completed: true, difficulty: 9),
        ]),
        now: start,
      );
      expect(two.looksTooHard, isFalse);
    });

    test('a runner who does everything easily is not flagged as too hard', () {
      final p = planOf(10, start);
      final easy = PlanProgress(
        plan: p,
        weekLogs: logged(p, const [
          WeekLog(completed: true, difficulty: 5, sessionsDone: 4),
          WeekLog(completed: true, difficulty: 5, sessionsDone: 4),
          WeekLog(completed: true, difficulty: 4, sessionsDone: 4),
          WeekLog(completed: true, difficulty: 5, sessionsDone: 4),
        ]),
        now: start,
      );
      expect(easy.looksTooHard, isFalse);
    });

    test('logFor returns an empty log rather than null', () {
      final p = planOf(4, start);
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: start);
      expect(prog.logFor(0).hasData, isFalse);
      expect(prog.hasLog(0), isFalse);
      expect(prog.logFor(99).hasData, isFalse);
    });
  });

  test('a plan with no weeks does not divide by zero', () {    final empty = TrainingPlan(
      path: TrainingPath.trainedRace,
      weeks: const [],
      paces: const TrainingPaces(
        repetition: Pace(0),
        interval: Pace(0),
        threshold: Pace(0),
        marathon: Pace(0),
        easy: Pace(0),
        recovery: Pace(0),
      ),
      weeklyVolumeKm: 0,
      startDate: start,
    );
    final prog = PlanProgress(plan: empty, weekLogs: const {}, now: start);
    expect(prog.weekCount, 0);
    expect(prog.completionRate, 0);
    expect(prog.calendarWeekIndex, 0);
    expect(prog.missedWeekCount, 0);
    expect(prog.isFinished, isFalse);
  });
}

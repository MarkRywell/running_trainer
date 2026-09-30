import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

List<PlanFlag> runValidate({
  RunnerProfile? profile,
  List<RaceResult> races = const [],
  GoalRace? goal,
  Map<String, WeekLog> weekLogs = const {},
}) {
  final p = profile ?? trainedProfile();
  return validate(
    profile: p,
    fitness: assessFitness(races, testToday),
    goal: goal,
    today: testToday,
    weekLogs: weekLogs,
  );
}

bool hasFlag(List<PlanFlag> flags, String needle) =>
    flags.any((f) => '${f.title} ${f.detail}'.toLowerCase().contains(needle.toLowerCase()));

void main() {
  group('isBeginnerPath', () {
    test('a runner with under a year of running is on the beginner path', () {
      expect(
        isBeginnerPath(trainedProfile(monthsRunning: 11), assessFitness([], testToday)),
        isTrue,
      );
    });

    test('exactly twelve months is not automatically beginner', () {
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      expect(
        isBeginnerPath(trainedProfile(monthsRunning: 12), f),
        isFalse,
      );
    });

    test('genuinely low volume sends an experienced runner to the base path', () {
      // 8 km a week over four days is under half of what those four days would
      // normally cover. The old rule tested this against a flat 24 km, which a
      // three-day runner could never reach — see the three-day case below.
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      expect(
        isBeginnerPath(trainedProfile(monthsRunning: 40, weeklyKm: 8), f),
        isTrue,
      );
    });

    test('a three-day runner is judged against three days, not a flat total', () {
      // 15 km a week over three days is about 5 km a run — normal, not a
      // beginner. A flat 24 km threshold called this a beginner and produced a
      // 3 km long run for a runner with a 1:56 half marathon.
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      expect(
        isBeginnerPath(
          trainedProfile(monthsRunning: 24, daysPerWeek: 3, weeklyKm: 15),
          f,
        ),
        isFalse,
      );
    });

    test('the same volume over more days is not a beginner either', () {
      // The threshold scales with days, so 20 km means something different at
      // three days than at six.
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      expect(
        isBeginnerPath(
          trainedProfile(monthsRunning: 40, daysPerWeek: 3, weeklyKm: 8),
          f,
        ),
        isTrue,
      );
      expect(
        isBeginnerPath(
          trainedProfile(monthsRunning: 40, daysPerWeek: 3, weeklyKm: 20),
          f,
        ),
        isFalse,
      );
    });

    test('no race data sends an experienced runner to the base path', () {
      expect(
        isBeginnerPath(trainedProfile(monthsRunning: 40), assessFitness([], testToday)),
        isTrue,
      );
    });

    test('a properly trained runner is not a beginner', () {
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      expect(
        isBeginnerPath(trainedProfile(monthsRunning: 40, weeklyKm: 40), f),
        isFalse,
      );
    });
  });

  group('goal time versus current fitness', () {
    test('a conservative goal raises no warning', () {
      // Current equivalent marathon from a 45:00 10K is well under 4:00.
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 4), inWeeks: 18),
      );
      expect(hasFlag(flags, 'slower than your current equivalent'), isTrue);
      expect(flags.where((f) => f.severity == FlagSeverity.warning), isEmpty);
    });

    test('a realistic improvement goal is not flagged', () {
      // A 45:00 10K implies roughly a 3:30 marathon here, so 3:26 is a ~2%
      // gain — inside the ~3% a block typically delivers.
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 26), inWeeks: 18),
      );
      expect(flags.where((f) => f.severity == FlagSeverity.caution), isEmpty);
      expect(flags.where((f) => f.severity == FlagSeverity.warning), isEmpty);
    });

    test('an aggressive goal is flagged as a stretch', () {
      // ~4.4% faster than the implied equivalent: past typical, inside the
      // ~5% stretch ceiling.
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 22), inWeeks: 18),
      );
      final f = flags.firstWhere((x) => x.title.contains('stretch goal'));
      expect(f.severity, FlagSeverity.caution);
    });

    test('an unrealistic goal is flagged as beyond the block', () {
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 5), inWeeks: 18),
      );
      final f = flags.firstWhere((f) => f.title.contains('Beyond what this block'));
      expect(f.severity, FlagSeverity.warning);
      expect(f.detail, contains('typically delivers'));
    });

    test('no race data means no goal-time opinion', () {
      final flags = runValidate(
        profile: beginnerProfile(),
        races: const [],
        goal: goal(RaceDistance.k5, finishTime: const Duration(minutes: 25), inWeeks: 14),
      );
      expect(hasFlag(flags, 'faster'), isFalse);
    });

    test('headroom tightens as the distance grows', () {
      final marathon = improvementHeadroom(RaceDistance.marathon);
      final k5 = improvementHeadroom(RaceDistance.k5);
      expect(marathon.stretch, lessThan(k5.stretch));
    });
  });

  group('race too close', () {
    test('a comfortable runway raises nothing', () {
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 45), inWeeks: 18),
      );
      expect(flags.where((f) => f.title.contains('weeks to race day')), isEmpty);
    });

    test('a very short runway is a warning and suggests alternatives', () {
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 45), inWeeks: 5),
      );
      final f = flags.firstWhere((f) => f.title.contains('weeks to race day'));
      expect(f.severity, FlagSeverity.warning);
      expect(f.suggestedDate, isNotNull);
      expect(f.suggestedDistance, RaceDistance.half);
    });

    test('a moderately short runway is a caution, not a warning', () {
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 45), inWeeks: 11),
      );
      final f = flags.firstWhere((f) => f.title.contains('weeks to race day'));
      expect(f.severity, FlagSeverity.caution);
    });

    test('a beginner needs more runway than a trained runner', () {
      expect(
        requiredRunwayWeeks(beginner: true, goal: RaceDistance.marathon),
        greaterThan(requiredRunwayWeeks(beginner: false, goal: RaceDistance.marathon)),
      );
    });

    test('a shorter goal needs less runway than a marathon', () {
      expect(
        requiredRunwayWeeks(beginner: false, goal: RaceDistance.k10),
        lessThan(requiredRunwayWeeks(beginner: false, goal: RaceDistance.marathon)),
      );
    });
  });

  group('distance versus history', () {
    test('a beginner entering a marathon is warned, with a suggestion', () {
      final flags = runValidate(
        profile: beginnerProfile(monthsRunning: 4),
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 4, minutes: 30), inWeeks: 22),
      );
      final f = flags.firstWhere((x) => x.title.contains('Marathon from a beginner'));
      expect(f.severity, FlagSeverity.warning);
      expect(f.suggestedDistance, RaceDistance.half);
    });

    test('a beginner entering a 5K is not warned about distance', () {
      final flags = runValidate(
        profile: beginnerProfile(monthsRunning: 4),
        goal: goal(RaceDistance.k5, finishTime: const Duration(minutes: 28), inWeeks: 12),
      );
      expect(hasFlag(flags, 'Marathon from a beginner'), isFalse);
    });

    test('a trained runner entering a marathon is not warned', () {
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.marathon, finishTime: const Duration(hours: 3, minutes: 45), inWeeks: 18),
      );
      expect(hasFlag(flags, 'Marathon from a beginner'), isFalse);
    });
  });

  group('input validation', () {
    test('a past race is rejected', () {
      final past = GoalRace(
        distance: RaceDistance.marathon,
        date: testToday.subtract(const Duration(days: 10)),
        finishTimeGoal: const Duration(hours: 3, minutes: 30),
        daysPerWeek: 4,
      );
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: past,
      );
      expect(flags.any((f) => f.title.contains('already happened')), isTrue);
    });

    test('fewer than three days a week is flagged but not blocked', () {
      final flags = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(
          RaceDistance.marathon,
          finishTime: const Duration(hours: 3, minutes: 45),
          inWeeks: 18,
          daysPerWeek: 2,
        ),
      );
      expect(hasFlag(flags, 'Three days a week is the floor'), isTrue);
    });
  });

  group('trained fitness basis', () {
    test('no logs means no adjustment', () {
      expect(trainedFitnessAdjustment(const {}), isNull);
    });

    test('consistently easy weeks count as absorbed training', () {
      final logs = {
        'a': const WeekLog(completed: true, difficulty: 4),
        'b': const WeekLog(completed: true, difficulty: 5),
        'c': const WeekLog(completed: true, difficulty: 5),
      };
      expect(trainedFitnessAdjustment(logs), greaterThan(0));
    });

    test('consistently hard weeks count as below peak', () {
      final logs = {
        'a': const WeekLog(completed: true, difficulty: 8),
        'b': const WeekLog(completed: true, difficulty: 9),
      };
      expect(trainedFitnessAdjustment(logs), lessThan(0));
    });

    test('a middling average says nothing rather than guessing', () {
      final logs = {
        'a': const WeekLog(completed: true, difficulty: 6),
        'b': const WeekLog(completed: true, difficulty: 7),
      };
      expect(trainedFitnessAdjustment(logs), isNull);
    });

    test('incomplete weeks are ignored', () {
      final logs = {
        'a': const WeekLog(difficulty: 9),
        'b': const WeekLog(difficulty: 9),
      };
      expect(trainedFitnessAdjustment(logs), isNull);
    });

    test('weeks with no difficulty are ignored', () {
      final logs = {
        'a': const WeekLog(completed: true),
        'b': const WeekLog(completed: true, sessionsDone: 4),
      };
      expect(trainedFitnessAdjustment(logs), isNull);
    });

    test('the basis is the bare race times when nothing is logged', () {
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      final e = currentExpectation(
        fitness: f,
        distance: RaceDistance.marathon,
      );
      expect(e.basis, 'your race times');
      expect(e.time, f.equivalents[RaceDistance.marathon]);
    });

    test('the basis names the adjustment when one applies', () {
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      final e = currentExpectation(
        fitness: f,
        distance: RaceDistance.marathon,
        weekLogs: {
          'a': const WeekLog(completed: true, difficulty: 9),
          'b': const WeekLog(completed: true, difficulty: 8),
        },
      );
      expect(e.basis, contains('allowing for the weeks that felt hard'));
      // Below the bare projection: a fitter athlete has less ground to cover.
      expect(
        e.time,
        greaterThan(f.equivalents[RaceDistance.marathon]!),
      );
    });

    test('absorbed training makes the expectation quicker', () {
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      final e = currentExpectation(
        fitness: f,
        distance: RaceDistance.marathon,
        weekLogs: {
          'a': const WeekLog(completed: true, difficulty: 4),
          'b': const WeekLog(completed: true, difficulty: 5),
        },
      );
      expect(e.basis, contains('plus the training'));
      expect(
        e.time,
        lessThan(f.equivalents[RaceDistance.marathon]!),
      );
    });

    test('weeks that felt hard can turn a fine goal into a stretch', () {
      // A 45:00 10K implies about a 3:30 marathon, so 3:25 is a comfortable
      // ~2.4% improvement. Nobody is flagging that on the bare race time.
      final g = goal(
        RaceDistance.marathon,
        finishTime: const Duration(hours: 3, minutes: 25),
        inWeeks: 18,
      );
      final plain = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: g,
      );
      expect(
        plain.where((x) => x.title.contains('stretch') || x.title.contains('Beyond')),
        isEmpty,
        reason: 'fine on the bare projection',
      );

      // But if the logged weeks have all felt awful, the runner is plausibly
      // below their PB right now, and the same goal is out of reach.
      final struggling = runValidate(
        races: [raceK10(const Duration(minutes: 45))],
        goal: g,
        weekLogs: {
          'a': const WeekLog(completed: true, difficulty: 9),
          'b': const WeekLog(completed: true, difficulty: 9),
        },
      );
      expect(
        struggling.any((x) =>
            x.title.contains('stretch') || x.title.contains('Beyond')),
        isTrue,
        reason: 'the same goal should now be flagged',
      );
      expect(
        struggling.any((x) => x.detail.contains('allowing for the weeks')),
        isTrue,
      );
    });

    test('logged weeks move the improvement a goal demands', () {
      // The real property, rather than a knife-edge band: a fitter athlete has
      // less ground to cover to a given time, and one who is struggling has
      // more. That is the direction that makes a quietly-unreachable goal
      // get flagged.
      final f = assessFitness([raceK10(const Duration(minutes: 45))], testToday);
      const g = Duration(hours: 3, minutes: 22);

      double improvement(Map<String, WeekLog> logs) {
        final e = currentExpectation(
          fitness: f,
          distance: RaceDistance.marathon,
          weekLogs: logs,
        );
        return (e.time.inSeconds - g.inSeconds) / e.time.inSeconds;
      }

      final plain = improvement(const {});
      final absorbed = improvement({
        'a': const WeekLog(completed: true, difficulty: 4),
        'b': const WeekLog(completed: true, difficulty: 5),
      });
      final struggling = improvement({
        'a': const WeekLog(completed: true, difficulty: 9),
        'b': const WeekLog(completed: true, difficulty: 9),
      });

      expect(absorbed, lessThan(plain));
      expect(struggling, greaterThan(plain));
    });
  });

  test('no goal produces no goal-related flags', () {
    final flags = runValidate(races: [raceK10(const Duration(minutes: 45))]);
    expect(flags.every((f) => f.severity == FlagSeverity.info), isTrue);
  });
}

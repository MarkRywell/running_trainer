import 'package:ai_running_trainer/app/controller.dart';
import 'package:ai_running_trainer/app/storage.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _profile = RunnerProfile(
  name: 'Sam',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 36,
  daysPerWeek: 4,
  estimatedWeeklyKm: 40,
);

Future<TrainerController> controllerWith({
  GoalRace? goal,
  List<RaceResult> races = const [],
  DateTime? start,
}) async {
  SharedPreferences.setMockInitialValues({});
  final c = TrainerController(await TrainerStorage.open());
  await c.completeOnboarding(
    profile: _profile,
    races: races,
    goal: goal,
    startDate: start ?? DateTime.now(),
  );
  return c;
}

/// Recent race data. Without it the runner is routed to the beginner path,
/// which is always 12 weeks long and would make these tests meaningless.
List<RaceResult> _races() => [
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 45),
        date: DateTime.now().subtract(const Duration(days: 30)),
      ),
    ];

GoalRace _goal({int inWeeks = 18, RaceDistance d = RaceDistance.marathon}) =>
    GoalRace(
      distance: d,
      date: DateTime.now().add(Duration(days: inWeeks * 7)),
      finishTimeGoal: const Duration(hours: 3, minutes: 40),
      daysPerWeek: 4,
    );

void main() {
  group('marking weeks', () {
    test('marks and unmarks', () async {
      final c = await controllerWith();
      expect(c.progress!.isComplete(0), isFalse);

      await c.markWeekComplete(0);
      expect(c.progress!.isComplete(0), isTrue);
      expect(c.progress!.completedCount, 1);

      await c.markWeekComplete(0, value: false);
      expect(c.progress!.isComplete(0), isFalse);
      expect(c.progress!.completedCount, 0);
    });

    test('ignores out-of-range weeks', () async {
      final c = await controllerWith();
      final count = c.plan!.weekCount;
      await c.markWeekComplete(-1);
      await c.markWeekComplete(count);
      await c.markWeekComplete(count + 10);
      expect(c.progress!.completedCount, 0);
    });

    test('un-marking a week also clears the ones after it', () async {
      final c = await controllerWith();
      for (var i = 0; i < 4; i++) {
        await c.markWeekComplete(i);
      }
      expect(c.progress!.completedCount, 4);

      // Disowning week 2 invalidates 3 and 4 — you cannot claim to have
      // finished weeks built on one you just disowned.
      await c.markWeekComplete(1, value: false);
      expect(c.progress!.isComplete(0), isTrue);
      expect(c.progress!.isComplete(1), isFalse);
      expect(c.progress!.isComplete(2), isFalse);
      expect(c.progress!.isComplete(3), isFalse);
      expect(c.progress!.completedCount, 1);
    });
  });

  group('persistence', () {
    test('completion survives a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await TrainerStorage.open();
      final first = TrainerController(storage);
      await first.completeOnboarding(
        profile: _profile,
        races: const [],
        startDate: DateTime.now(),
      );
      await first.markWeekComplete(0);
      await first.markWeekComplete(1);

      SharedPreferences.resetStatic();

      final second = TrainerController(await TrainerStorage.open());
      await second.init();
      expect(second.progress!.completedCount, 2);
      expect(second.progress!.isComplete(0), isTrue);
      expect(second.progress!.isComplete(2), isFalse);
    });

    test('completion survives a goal change, keyed on week dates', () async {
      // The whole reason completion is not keyed on week number.
      SharedPreferences.setMockInitialValues({});
      final start = DateTime.now();
      final storage = await TrainerStorage.open();
      final c = TrainerController(storage);
      await c.completeOnboarding(
        profile: _profile,
        races: _races(),
        goal: _goal(),
        startDate: start,
      );
      await c.markWeekComplete(0);
      await c.markWeekComplete(1);

      // Change the goal, which regenerates the plan.
      await c.setGoal(_goal(d: RaceDistance.half, inWeeks: 10));
      expect(c.plan!.goal!.distance, RaceDistance.half);
      expect(
        c.progress!.completedCount,
        2,
        reason: 'completed weeks must survive regeneration',
      );
    });

    test('orphaned keys are dropped when the plan gets shorter', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await TrainerStorage.open();
      final c = TrainerController(storage);
      await c.completeOnboarding(
        profile: _profile,
        goal: _goal(inWeeks: 18),
        races: _races(),
        startDate: DateTime.now(),
      );
      final long = c.plan!.weekCount;
      expect(long, greaterThan(8));
      for (var i = 0; i < long; i++) {
        await c.markWeekComplete(i);
      }
      expect(c.progress!.completedCount, long);

      // The shortest possible block, so the shortening is unambiguous.
      await c.setGoal(_goal(d: RaceDistance.k5, inWeeks: 6));
      expect(c.plan!.weekCount, lessThan(long));
      expect(
        c.progress!.completedCount,
        lessThanOrEqualTo(c.plan!.weekCount),
      );
      expect(c.progress!.completedCount, lessThan(long));
    });

    test('reset clears completion', () async {
      final c = await controllerWith();
      await c.markWeekComplete(0);
      await c.reset();
      expect(c.hasPlan, isFalse);
      expect(c.progress, isNull);
    });
  });

  group('current week', () {
    test('a fresh plan starts at week 1', () async {
      final c = await controllerWith(start: DateTime.now());
      expect(c.currentWeekIndex, 0);
    });

    test('a runner who never logged is put back on their first week',
        () async {
      // The returning-after-a-month trap. Start a plan in the past so the
      // calendar has moved on, but mark nothing done.
      final past = DateTime.now().subtract(const Duration(days: 35));
      final c = await controllerWith(
        goal: _goal(),
        start: past,
      );
      // The calendar would say week 6.
      expect(c.progress!.calendarWeekIndex, greaterThan(3));
      // But the runner is dropped back to week 1.
      expect(c.currentWeekIndex, 0);
      expect(c.progress!.missedWeekCount, greaterThan(3));
    });

    test('a runner who completed week 1 moves on', () async {
      final past = DateTime.now().subtract(const Duration(days: 9));
      final c = await controllerWith(start: past);
      await c.markWeekComplete(0);
      expect(c.currentWeekIndex, 1);
    });

    test('is always a valid index', () async {
      final c = await controllerWith(
        goal: _goal(),
        start: DateTime.now().subtract(const Duration(days: 365)),
      );
      final i = c.currentWeekIndex;
      expect(i, greaterThanOrEqualTo(0));
      expect(i, lessThan(c.plan!.weekCount));
    });
  });

  group('reactive volume curve', () {
    test('logging a missed week holds the next one flat', () async {
      // Regression: logWeek used to record the log without regenerating, so
      // the reactive volume curve silently never fired through the controller.
      final c = await controllerWith(goal: _goal());
      final clean1 = c.plan!.weeks[0].targetVolumeKm;
      final clean2 = c.plan!.weeks[1].targetVolumeKm;
      expect(clean2, greaterThan(clean1));

      await c.logWeek(0, const WeekLog(sessionsDone: 1, difficulty: 9));
      expect(c.plan!.weeks[1].targetVolumeKm, closeTo(clean1, 0.001));
    });

    test('the one-tap done control is authoritative', () async {
      // The quick button sets a clean state rather than merging with whatever
      // partial detail was there, so its effect does not depend on invisible
      // prior state.
      final c = await controllerWith(goal: _goal());
      final clean2 = c.plan!.weeks[1].targetVolumeKm;
      await c.logWeek(0, const WeekLog(sessionsDone: 0, difficulty: 9));
      expect(c.plan!.weeks[1].targetVolumeKm, lessThan(clean2));

      await c.markWeekComplete(0);
      final log = c.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.sessionsDone, isNull, reason: 'stale detail is discarded');
      expect(log.difficulty, isNull);
      expect(c.plan!.weeks[1].targetVolumeKm, closeTo(clean2, 0.001));
    });

    test('completing a week restores the build', () async {
      // The realistic path: the week is logged complete with no partial
      // session data, which is what the log sheet produces.
      final c = await controllerWith(goal: _goal());
      final clean2 = c.plan!.weeks[1].targetVolumeKm;

      await c.logWeek(0, const WeekLog(sessionsDone: 1));
      expect(c.plan!.weeks[1].targetVolumeKm, lessThan(clean2));

      await c.logWeek(0, const WeekLog(completed: true));
      expect(c.plan!.weeks[1].targetVolumeKm, closeTo(clean2, 0.001));
    });

    test('the one-tap done path restores the build', () async {
      final c = await controllerWith(goal: _goal());
      final clean2 = c.plan!.weeks[1].targetVolumeKm;
      await c.logWeek(0, const WeekLog(sessionsDone: 0));
      expect(c.plan!.weeks[1].targetVolumeKm, lessThan(clean2));
      await c.markWeekComplete(0);
      expect(c.plan!.weeks[1].targetVolumeKm, closeTo(clean2, 0.001));
    });

    test('a base plan with no goal also reacts', () async {
      final c = await controllerWith();
      final clean2 = c.plan!.weeks[1].targetVolumeKm;
      await c.logWeek(0, const WeekLog(sessionsDone: 0));
      expect(c.plan!.weeks[1].targetVolumeKm, lessThan(clean2));
    });
  });

  group('per-session logging', () {
    test('logging a session records it against the week', () async {
      final c = await controllerWith(races: _races(), goal: _goal());
      final week = c.plan!.weeks.first;
      final day = week.workouts
          .firstWhere((w) => w.type != WorkoutType.rest)
          .weekday!;

      await c.logSession(0, day, felt: SessionFelt.hard);

      final log = c.progress!.logFor(0);
      expect(log.sessions.single.dayOfWeek, day);
      expect(log.sessions.single.felt, SessionFelt.hard);
      expect(log.hardSessionCount, 1);
    });

    test('logging a session is a record even before the week is marked done',
        () async {
      // Otherwise a week in progress would read as "nothing logged" to every
      // rollup, and the observation would never be possible.
      final c = await controllerWith(races: _races(), goal: _goal());
      final day = c.plan!.weeks.first.workouts
          .firstWhere((w) => w.type != WorkoutType.rest)
          .weekday!;

      await c.logSession(0, day, felt: SessionFelt.hard);

      expect(c.progress!.logFor(0).completed, isFalse);
      expect(c.progress!.logFor(0).sessionsWithEffort, 1);
      expect(c.progress!.isComplete(0), isFalse);
    });

    test('re-logging a day replaces it rather than duplicating', () async {
      final c = await controllerWith(races: _races(), goal: _goal());
      final day = c.plan!.weeks.first.workouts
          .firstWhere((w) => w.type != WorkoutType.rest)
          .weekday!;

      await c.logSession(0, day, felt: SessionFelt.hard);
      await c.logSession(0, day, felt: SessionFelt.easy);

      final sessions = c.progress!.logFor(0).sessions;
      expect(sessions.length, 1);
      expect(sessions.single.felt, SessionFelt.easy);
      expect(c.progress!.logFor(0).hardSessionCount, 0);
    });

    test('clearing a session leaves the rest of the week alone', () async {
      final c = await controllerWith(races: _races(), goal: _goal());
      final days = c.plan!.weeks.first.workouts
          .where((w) => w.type != WorkoutType.rest)
          .map((w) => w.weekday!)
          .toList();
      await c.logSession(0, days.first, felt: SessionFelt.hard);
      await c.logSession(0, days.last, felt: SessionFelt.easy);

      await c.logSession(0, days.first, clearFelt: true);

      final sessions = c.progress!.logFor(0).sessions;
      expect(sessions.where((s) => s.feltHard), isEmpty);
      expect(
        sessions.where((s) => s.felt == SessionFelt.easy).length,
        1,
        reason: 'clearing one day must not take the other with it',
      );
    });

    test('an out-of-range day or week is ignored', () async {
      final c = await controllerWith(races: _races(), goal: _goal());
      await c.logSession(0, 9, felt: SessionFelt.hard);
      await c.logSession(99, 1, felt: SessionFelt.hard);
      expect(c.progress!.logFor(0).sessions, isEmpty);
    });

    test('marking a week done keeps the session records', () async {
      // The one deliberate exception to markWeekComplete being authoritative.
      // A per-session record is what the runner actually did, and it is the
      // most expensive data here to reproduce.
      final c = await controllerWith(races: _races(), goal: _goal());
      final day = c.plan!.weeks.first.workouts
          .firstWhere((w) => w.type != WorkoutType.rest)
          .weekday!;
      await c.logSession(0, day, felt: SessionFelt.hard);

      await c.markWeekComplete(0);

      final log = c.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.sessions.single.felt, SessionFelt.hard,
          reason: 'tapping "done" must not discard what was recorded');
    });

    test('marking a week done still clears the self-reported week fields',
        () async {
      // The half of "authoritative" that still holds: stale self-report goes.
      final c = await controllerWith(races: _races(), goal: _goal());
      await c.logWeek(
        0,
        const WeekLog(
          completed: true,
          difficulty: 9,
          actualKm: 80,
          sessionsDone: 1,
        ),
      );

      await c.markWeekComplete(0);

      final log = c.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.difficulty, isNull);
      expect(log.actualKm, isNull);
      expect(log.sessionsDone, isNull);
    });

    test('un-marking a week clears its sessions too', () async {
      // Disowning the week disowns everything claimed about it.
      final c = await controllerWith(races: _races(), goal: _goal());
      final day = c.plan!.weeks.first.workouts
          .firstWhere((w) => w.type != WorkoutType.rest)
          .weekday!;
      await c.logSession(0, day, felt: SessionFelt.hard);
      await c.markWeekComplete(0);

      await c.markWeekComplete(0, value: false);

      expect(c.progress!.logFor(0).sessions, isEmpty);
      expect(c.progress!.completedCount, 0);
    });

    test('sessions survive an app restart', () async {
      final first = await controllerWith(races: _races(), goal: _goal());
      final day = first.plan!.weeks.first.workouts
          .firstWhere((w) => w.type != WorkoutType.rest)
          .weekday!;
      await first.logSession(0, day, felt: SessionFelt.hard);

      SharedPreferences.resetStatic();

      final second = TrainerController(await TrainerStorage.open());
      await second.init();
      expect(second.progress!.logFor(0).sessions.single.felt, SessionFelt.hard);
    });
  });

  group('editing details and redoing a plan', () {
    test('setProfile rebuilds the plan', () async {
      final c = await controllerWith(races: _races());
      final before = c.plan!.weeks.first.targetVolumeKm;
      // 40 km a week → 8, a big change in the seeding input.
      await c.setProfile(_profile.copyWith(estimatedWeeklyKm: const Optional(8)));
      expect(c.profile!.estimatedWeeklyKm, 8);
      expect(c.plan!.weeks.first.targetVolumeKm, isNot(before));
    });

    test('setProfile keeps the weeks already logged', () async {
      // The start date does not move, so completion is keyed on the same
      // week-start keys and carries over. An edit must not cost a season of logs.
      final c = await controllerWith(races: _races());
      await c.markWeekComplete(0);
      expect(c.progress!.completedCount, 1);

      await c.setProfile(_profile.copyWith(estimatedWeeklyKm: const Optional(55)));
      expect(c.progress!.completedCount, 1, reason: 'an edit keeps progress');
      expect(c.progress!.isComplete(0), isTrue);
    });

    test('setRaces re-derives the paces and keeps progress', () async {
      final c = await controllerWith(races: _races());
      await c.markWeekComplete(0);
      final before = c.plan!.paces.easy;

      await c.setRaces([
        RaceResult(
          distance: RaceDistance.k10,
          time: const Duration(minutes: 38),
          date: DateTime.now().subtract(const Duration(days: 10)),
        ),
      ]);

      expect(c.races.single.time, const Duration(minutes: 38));
      expect(c.plan!.paces.easy.secPerKm, lessThan(before.secPerKm));
      expect(c.progress!.completedCount, 1);
    });

    test('clearing weekly volume falls back to the race-time estimate',
        () async {
      final c = await controllerWith(races: _races());
      await c.setProfile(_profile.copyWith(estimatedWeeklyKm: const Optional(8)));
      final stated = c.plan!.weeks.first.targetVolumeKm;

      await c.setProfile(_profile.cleared(weeklyKm: true));
      expect(c.profile!.estimatedWeeklyKm, isNull);
      expect(
        c.plan!.weeks.first.targetVolumeKm,
        greaterThan(stated),
        reason: 'with no stated volume the guess takes over again',
      );
    });

    test('restartPlan re-anchors forward to a Monday and clears the log',
        () async {
      // Anchored to a Monday in the past, so "moves forward" is observable.
      // With a fresh onboarding the start is already next Monday and a restart
      // is correctly a no-op on the date.
      final oldStart = DateTime.now().subtract(const Duration(days: 56));
      final c = await controllerWith(
        races: _races(),
        goal: _goal(),
        start: oldStart,
      );
      expect(c.startDate!.isBefore(DateTime.now()), isTrue);
      await c.markWeekComplete(0);
      await c.markWeekComplete(1);
      expect(c.progress!.completedCount, 2);

      await c.restartPlan();

      expect(c.startDate!.weekday, DateTime.monday);
      expect(c.startDate!.isAfter(oldStart), isTrue);
      expect(
        c.progress!.completedCount,
        0,
        reason: 'new start dates mean new keys, so old weeks cannot carry over',
      );
    });

    test('restarting a plan that started this week does not move the date',
        () async {
      // Idempotence: snapping to "the next Monday" twice in the same week gives
      // the same day, and pretending otherwise would be a lie about the anchor.
      final c = await controllerWith(races: _races(), goal: _goal());
      final before = c.startDate;
      await c.restartPlan();
      expect(c.startDate, before);
    });

    test('restartPlan keeps the runner, their races and their goal', () async {
      // "Same runner, fresh block" — the opposite of reset.
      final c = await controllerWith(races: _races(), goal: _goal());
      await c.restartPlan();
      expect(c.profile, isNotNull);
      expect(c.races, isNotEmpty);
      expect(c.goal, isNotNull);
      expect(c.hasPlan, isTrue);
    });

    test('restartPlan leaves no coach state behind', () async {
      // An accepted cap or a decline was a judgement about the block that just
      // ended. Carrying it over would silently shape the new one.
      final c = await controllerWith(races: _races(), goal: _goal());
      await c.restartPlan();
      expect(c.coachState.applied, isEmpty);
      expect(c.directive.capVolume, isFalse);
      expect(c.directive.targetDaysPerWeek, isNull);
    });

    test('proposals can still be accepted after a restart', () async {
      // Guards the opposite failure: a restart that wedged the coach layer.
      final c = await controllerWith(races: _races(), goal: _goal());
      await c.restartPlan();
      await c.markWeekComplete(0);
      expect(c.progress!.completedCount, 1);
      expect(c.hasPlan, isTrue);
    });

    test('a restart is a different thing from a reset', () async {
      final restart = await controllerWith(races: _races(), goal: _goal());
      await restart.markWeekComplete(0);
      await restart.restartPlan();

      final reset = await controllerWith(races: _races(), goal: _goal());
      await reset.markWeekComplete(0);
      await reset.reset();

      expect(restart.profile, isNotNull, reason: 'restart keeps the runner');
      expect(reset.profile, isNull);
      expect(reset.hasPlan, isFalse);
    });
  });

  group('week log', () {
    test('records a full log', () async {
      final c = await controllerWith();
      await c.logWeek(0, const WeekLog(
        completed: true,
        actualKm: 41.5,
        sessionsDone: 4,
        difficulty: 8,
        note: 'legs gone',
      ));
      final log = c.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.actualKm, 41.5);
      expect(log.sessionsDone, 4);
      expect(log.difficulty, 8);
      expect(log.note, 'legs gone');
      expect(c.progress!.looksTooHard, isFalse); // one week is not a pattern
    });

    test('an empty log removes the entry', () async {
      final c = await controllerWith();
      await c.logWeek(0, const WeekLog(completed: true));
      expect(c.progress!.hasLog(0), isTrue);
      await c.logWeek(0, const WeekLog());
      expect(c.progress!.hasLog(0), isFalse);
    });

    test('difficulty survives without marking the week done', () async {
      // A runner can record a partial week without claiming to have finished
      // it — that is the point of a log rather than a checkbox.
      final c = await controllerWith();
      await c.logWeek(0, const WeekLog(sessionsDone: 2, difficulty: 9));
      expect(c.progress!.isComplete(0), isFalse);
      expect(c.progress!.logFor(0).difficulty, 9);
      expect(c.progress!.hardWeeks, [0]);
    });

    test('the quick done control discards stale detail', () async {
      // Documented behaviour: the one-tap button is authoritative, not a merge.
      // Use the log sheet to keep the detail alongside "completed".
      final c = await controllerWith();
      await c.logWeek(0, const WeekLog(actualKm: 40, difficulty: 6));
      await c.markWeekComplete(0);
      final log = c.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.actualKm, isNull);
      expect(log.difficulty, isNull);
    });

    test('the log sheet can keep detail alongside completed', () async {
      final c = await controllerWith();
      await c.logWeek(
        0,
        const WeekLog(completed: true, actualKm: 40, difficulty: 6),
      );
      final log = c.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.actualKm, 40);
      expect(log.difficulty, 6);
    });

    test('un-marking a week clears the logs after it', () async {
      final c = await controllerWith();
      await c.logWeek(0, const WeekLog(completed: true, actualKm: 30));
      await c.logWeek(1, const WeekLog(completed: true, actualKm: 34));
      await c.markWeekComplete(1, value: false);
      expect(c.progress!.hasLog(0), isTrue);
      expect(c.progress!.hasLog(1), isFalse);
    });

    test('logs survive a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await TrainerStorage.open();
      final first = TrainerController(storage);
      await first.completeOnboarding(
        profile: _profile,
        races: const [],
        startDate: DateTime.now(),
      );
      await first.logWeek(
        0,
        const WeekLog(completed: true, actualKm: 44, sessionsDone: 4, difficulty: 7),
      );

      SharedPreferences.resetStatic();

      final second = TrainerController(await TrainerStorage.open());
      await second.init();
      final log = second.progress!.logFor(0);
      expect(log.completed, isTrue);
      expect(log.actualKm, 44);
      expect(log.sessionsDone, 4);
      expect(log.difficulty, 7);
    });

    test('a run of hard weeks is detected after a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await TrainerStorage.open();
      final first = TrainerController(storage);
      await first.completeOnboarding(
        profile: _profile,
        races: const [],
        startDate: DateTime.now(),
      );
      for (var i = 0; i < 3; i++) {
        await first.logWeek(
          i,
          WeekLog(completed: true, sessionsDone: 4, difficulty: 8 + i % 2),
        );
      }
      expect(first.progress!.looksTooHard, isTrue);

      SharedPreferences.resetStatic();
      final second = TrainerController(await TrainerStorage.open());
      await second.init();
      expect(second.progress!.looksTooHard, isTrue);
      expect(second.progress!.hardWeeks.length, 3);
    });

    test('migrates the old boolean-only format', () async {
      // The old format stored bare week-start keys. They have to match the
      // plan's real weeks or the rebuild prunes them, so derive them.
      final start = DateTime.now();
      final monday = start.subtract(Duration(days: start.weekday - 1));
      String key(Duration d) {
        final x = monday.add(d);
        final m = x.month.toString().padLeft(2, '0');
        final day = x.day.toString().padLeft(2, '0');
        return '${x.year}-$m-$day';
      }

      SharedPreferences.setMockInitialValues({
        'flutter.profile':
            '{"name":"Legacy","age":30,"gender":"preferNotToSay",'
                '"monthsRunning":30,"daysPerWeek":3}',
        'flutter.startDate': start.toIso8601String(),
        'flutter.completedWeeks': <String>[key(Duration.zero), key(const Duration(days: 7))],
      });
      final c = TrainerController(await TrainerStorage.open());
      await c.init();
      expect(c.hasPlan, isTrue);
      // The two old keys become completed logs rather than being dropped.
      expect(c.progress!.completedCount, 2);
    });
  });

  test('progress is null without a plan', () async {
    SharedPreferences.setMockInitialValues({});
    final c = TrainerController(await TrainerStorage.open());
    await c.init();
    expect(c.progress, isNull);
  });

  test('week logs key on the ISO week-start format', () async {
    SharedPreferences.setMockInitialValues({});
    final start = DateTime(2026, 3, 2);
    final storage = await TrainerStorage.open();
    final c = TrainerController(storage);
    await c.completeOnboarding(
      profile: _profile,
      races: const [],
      startDate: start,
    );
    await c.markWeekComplete(0);

    expect(storage.loadWeekLogs().keys, {'2026-03-02'});
    expect(storage.loadWeekLogs().values.single.completed, isTrue);
  });
}

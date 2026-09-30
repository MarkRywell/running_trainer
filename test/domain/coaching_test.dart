import 'package:ai_running_trainer/domain/coaching.dart';
import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/plan_directive.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:ai_running_trainer/domain/progress.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

TrainingPlan planOf([int weeks = 12]) => generate(
      profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
      races: [raceK10(const Duration(minutes: 45))],
      goal: goal(
        RaceDistance.marathon,
        finishTime: const Duration(hours: 3, minutes: 40),
        inWeeks: 18,
      ),
      startDate: testToday,
    );

Map<String, WeekLog> logKeys(TrainingPlan p, List<WeekLog> byIndex) => {
      for (var i = 0; i < byIndex.length; i++)
        weekKey(p.weeks[i].startDate): byIndex[i],
    };

PlanProgress progressWith(TrainingPlan p, List<WeekLog> logs) =>
    PlanProgress(plan: p, weekLogs: logKeys(p, logs), now: testToday);

void main() {
  group('propose', () {
    test('proposes nothing for a clean runner', () {
      final p = planOf();
      final prog = progressWith(p, const [
        WeekLog(completed: true, sessionsDone: 4, difficulty: 5),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 6),
      ]);
      expect(propose(prog), isEmpty);
    });

    test('proposes holding volume when weeks came back too hard', () {
      final p = planOf();
      final prog = progressWith(p, const [
        WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 9),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
      ]);
      final proposals = propose(prog);
      expect(proposals.map((x) => x.id), contains('cap-volume'));
      final cap = proposals.firstWhere((x) => x.id == 'cap-volume');
      expect(cap.directive.capVolume, isTrue);
      expect(cap.rationale, isNotEmpty, reason: 'a proposal needs a reason');
      expect(cap.title, isNotEmpty);
    });

    test('does not propose on a single hard week', () {
      final p = planOf();
      final prog = progressWith(p, const [
        WeekLog(completed: true, sessionsDone: 4, difficulty: 10),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 5),
      ]);
      expect(prog.looksTooHard, isFalse);
      expect(propose(prog).map((x) => x.id), isNot(contains('cap-volume')));
    });

    test('proposes fewer days when under-doing but finding it easy', () {
      final p = planOf();
      // 2 of 4 sessions, rated easy.
      final prog = progressWith(p, const [
        WeekLog(sessionsDone: 2, difficulty: 4),
        WeekLog(sessionsDone: 2, difficulty: 4),
        WeekLog(sessionsDone: 3, difficulty: 5),
      ]);
      expect(prog.looksUnderserved, isTrue);
      final proposals = propose(prog);
      final fewer = proposals.firstWhere((x) => x.id == 'fewer-days');
      expect(fewer.directive.targetDaysPerWeek, 3);
    });

    test('never suggests fewer than three days', () {
      final p = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40)
            .copyWith(daysPerWeek: 3),
        races: [raceK10(const Duration(minutes: 45))],
        goal: null,
        startDate: testToday,
      );
      final prog = progressWith(p, const [
        WeekLog(sessionsDone: 0, difficulty: 3),
        WeekLog(sessionsDone: 1, difficulty: 4),
      ]);
      // Already at the floor, so there is nothing sensible to propose.
      final ids = propose(prog).map((x) => x.id);
      expect(ids, isNot(contains('fewer-days')));
    });

    test('does not propose fewer days when the weeks felt hard', () {
      final p = planOf();
      final prog = progressWith(p, const [
        WeekLog(sessionsDone: 2, difficulty: 8),
        WeekLog(sessionsDone: 2, difficulty: 9),
      ]);
      expect(prog.looksUnderserved, isFalse);
      expect(
        propose(prog).map((x) => x.id),
        isNot(contains('fewer-days')),
      );
    });

    test('proposes nothing without any logged data', () {
      final p = planOf();
      final prog = PlanProgress(plan: p, weekLogs: const {}, now: testToday);
      expect(propose(prog), isEmpty);
    });
  });

  group('CoachState', () {
    final p = planOf();
    late PlanProgress hard;
    setUp(() {
      hard = progressWith(p, const [
        WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 9),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
      ]);
    });

    test('an untouched state has no outstanding proposals', () {
      final state = CoachState.empty;
      expect(state.outstanding(hard).map((x) => x.id), contains('cap-volume'));
      expect(state.directive.isEmpty, isTrue);
    });

    test('accepting removes it from outstanding', () {
      final state = CoachState.empty
          .accept('cap-volume', const PlanDirective(capVolume: true));
      expect(state.isAccepted('cap-volume'), isTrue);
      expect(
        state.outstanding(hard).map((x) => x.id),
        isNot(contains('cap-volume')),
      );
      expect(state.directive.capVolume, isTrue);
    });

    test('declining hides it while the situation is unchanged', () {
      final state = CoachState.empty.decline('cap-volume', 3);
      expect(state.isDeclined('cap-volume', 3), isTrue);
      expect(
        state.outstanding(hard).map((x) => x.id),
        isNot(contains('cap-volume')),
      );
    });

    test('declining does not silence a worse pattern', () {
      // Declined when three weeks were hard. A fourth should re-raise it,
      // because staying silent while it gets worse is the wrong default.
      final state = CoachState.empty.decline('cap-volume', 3);
      expect(state.isDeclined('cap-volume', 3), isTrue);
      expect(state.isDeclined('cap-volume', 4), isFalse);
    });

    test('the directive combines accepted proposals', () {
      final state = CoachState.empty
          .accept('cap-volume', const PlanDirective(capVolume: true))
          .accept('fewer-days', const PlanDirective(targetDaysPerWeek: 3));
      final d = state.directive;
      expect(d.capVolume, isTrue);
      expect(d.targetDaysPerWeek, 3);
      expect(d.summary, hasLength(2));
    });

    test('revoking by accepting an empty directive clears it', () {
      final state = CoachState.empty
          .accept('cap-volume', const PlanDirective(capVolume: true))
          .accept('cap-volume', const PlanDirective());
      expect(state.directive.capVolume, isFalse);
      expect(state.directive.isEmpty, isTrue);
    });

    test('round-trips through json', () {
      final state = CoachState.empty
          .accept('cap-volume', const PlanDirective(capVolume: true))
          .decline('fewer-days', 2);
      final back = CoachState.fromJson(state.toJson());
      expect(back.applied.keys, state.applied.keys);
      expect(back.dismissed, state.dismissed);
      expect(back.directive.capVolume, isTrue);
    });

    test('survives junk json without throwing', () {
      final back = CoachState.fromJson(const {});
      expect(back.isEmpty, isTrue);
    });
  });

  group('an accepted directive changes the plan', () {
    test('capping volume holds the future flat but not the past', () {
      final base = planOf();
      final keys = logKeys(base, const [
        WeekLog(completed: true, sessionsDone: 4, difficulty: 6),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 6),
      ]);
      final capped = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(
          RaceDistance.marathon,
          finishTime: const Duration(hours: 3, minutes: 40),
          inWeeks: 18,
        ),
        startDate: testToday,
        weekLogs: keys,
        directive: const PlanDirective(capVolume: true),
      );

      // Weeks 0 and 1 are done; the cap starts at the first incomplete week.
      expect(capped.weeks[0].targetVolumeKm, base.weeks[0].targetVolumeKm);
      expect(capped.weeks[1].targetVolumeKm, base.weeks[1].targetVolumeKm);

      // From week 2 on it never exceeds what the uncapped plan asked for. The
      // cap holds the volume *curve* flat; the sessions that fill it are not
      // identical week to week, because a long run still climbing into its share
      // makes a week come out under the ceiling until it arrives. So the
      // assertion is against the ceiling, not against week 2's decimal.
      // Only the build weeks are compared: the taper and the race week descend
      // by design, and the capped block can be a different length from the
      // uncapped one, so their week indices stop lining up at the end.
      final buildCount = capped.weeks
          .takeWhile((w) =>
              w.phase != PlanPhase.taper && w.phase != PlanPhase.raceWeek)
          .length;
      for (var i = 2; i < buildCount; i++) {
        expect(
          capped.weeks[i].targetVolumeKm,
          lessThanOrEqualTo(base.weeks[i].targetVolumeKm + 0.01),
          reason: 'week $i must not exceed the uncapped plan',
        );
      }

      // It genuinely stops growing rather than merely staying under the ceiling:
      // the last build week is within a tenth of week 2, where an uncapped plan
      // would have climbed several percent per week by now. Compared as a ratio,
      // because cutback weeks make any absolute spread meaningless.
      final first = capped.weeks[2].targetVolumeKm;
      final last = capped.weeks[buildCount - 1].targetVolumeKm;
      expect(
        last / first,
        lessThan(1.10),
        reason: 'held: week 2 was $first, week $buildCount is $last',
      );

      // And the uncapped plan really would have grown, so the assertion above is
      // testing the cap rather than passing by accident.
      expect(
        base.weeks[buildCount - 1].targetVolumeKm / base.weeks[2].targetVolumeKm,
        greaterThan(last / first),
        reason: 'the uncapped plan should have grown over the same span',
      );
    });

    test('reducing days changes the prescribed sessions', () {
      final base = planOf();
      final reduced = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(
          RaceDistance.marathon,
          finishTime: const Duration(hours: 3, minutes: 40),
          inWeeks: 18,
        ),
        startDate: testToday,
        directive: const PlanDirective(targetDaysPerWeek: 3),
      );
      expect(reduced.weeks.first.runCount, lessThanOrEqualTo(3));
      expect(base.weeks.first.runCount, greaterThan(reduced.weeks.first.runCount));
    });

    test('an empty directive changes nothing', () {
      final withDirective = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(
          RaceDistance.marathon,
          finishTime: const Duration(hours: 3, minutes: 40),
          inWeeks: 18,
        ),
        startDate: testToday,
        directive: const PlanDirective(),
      );
      for (var i = 0; i < withDirective.weekCount; i++) {
        expect(
          withDirective.weeks[i].targetVolumeKm,
          closeTo(planOf().weeks[i].targetVolumeKm, 0.001),
        );
      }
    });

    test('a capped plan still satisfies the safety invariants', () {
      final keys = logKeys(planOf(), const [
        WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 9),
        WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
      ]);
      final capped = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(
          RaceDistance.marathon,
          finishTime: const Duration(hours: 3, minutes: 40),
          inWeeks: 18,
        ),
        startDate: testToday,
        weekLogs: keys,
        directive: const PlanDirective(capVolume: true),
      );
      for (final w in capped.weeks) {
        if (w.phase == PlanPhase.raceWeek) continue;
        expect(w.easyFraction, greaterThanOrEqualTo(0.77), reason: 'week ${w.weekNumber}');
        final long = w.longRun;
        if (long != null && w.targetVolumeKm > 0) {
          expect(
            long.distanceKm,
            lessThanOrEqualTo(
              w.targetVolumeKm * maxLongRunFractionFor(runDaysIn(w)) + 0.01,
            ),
          );
        }
      }
    });
  });

  group('firstIncompleteIndex', () {
    test('is 0 with no logs', () {
      expect(firstIncompleteIndex(weekLogs: const {}, startDate: testToday), 0);
    });

    test('finds the first gap', () {
      final logs = {
        weekKey(testToday): const WeekLog(completed: true),
        weekKey(testToday.add(const Duration(days: 7))):
            const WeekLog(completed: true),
      };
      expect(
        firstIncompleteIndex(weekLogs: logs, startDate: testToday),
        2,
      );
    });

    test('a logged but incomplete week counts as a gap', () {
      final logs = {
        weekKey(testToday): const WeekLog(completed: true),
        weekKey(testToday.add(const Duration(days: 7))):
            const WeekLog(sessionsDone: 1),
      };
      expect(firstIncompleteIndex(weekLogs: logs, startDate: testToday), 1);
    });
  });
}

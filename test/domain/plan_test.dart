import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:ai_running_trainer/domain/plan/beginner_plan.dart'
    show alignToNextMonday, runWalkRatio;
import 'package:ai_running_trainer/domain/progress.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:ai_running_trainer/domain/plan/race_plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

TrainingPlan beginnerPlan({GoalRace? goal, RunnerProfile? profile, int? days}) =>
    generate(
      profile: profile ?? beginnerProfile(),
      races: const [],
      goal: goal,
      startDate: testToday,
    );

TrainingPlan trainedPlan({GoalRace? goal, RunnerProfile? profile}) =>
    generate(
      profile: profile ?? trainedProfile(),
      races: [raceK10(const Duration(minutes: 45))],
      goal: goal,
      startDate: testToday,
    );

void main() {
  group('beginner path', () {
    final plan = beginnerPlan();

    test('is selected for a new runner', () {
      expect(plan.path, TrainingPath.beginnerBase);
    });

    test('contains no quality sessions at all', () {
      // The single most important safety property of this path: threshold work
      // before a base exists is how beginners get hurt.
      for (final w in plan.weeks) {
        expect(w.qualityCount, 0, reason: 'week ${w.weekNumber}');
        for (final run in w.runs) {
          expect(
            run.type == WorkoutType.tempo ||
                run.type == WorkoutType.intervals ||
                run.type == WorkoutType.race,
            isFalse,
            reason: 'week ${w.weekNumber}: ${run.title}',
          );
        }
      }
    });

    test('stays entirely within easy and recovery', () {
      for (final w in plan.weeks) {
        for (final run in w.runs) {
          expect(run.zone.isEasy || run.type == WorkoutType.race, isTrue,
              reason: 'week ${w.weekNumber}: ${run.title}');
        }
      }
    });

    test('never drops below three runs a week', () {
      for (final w in plan.weeks) {
        expect(w.runCount, greaterThanOrEqualTo(beginnerMinimumRuns),
            reason: 'week ${w.weekNumber}');
      }
    });

    test('every session is at or above the conversational pace floor', () {
      // No matter what goal or race data a beginner brings, easy running must
      // not end up faster than this.
      expect(plan.paces.easy.secPerKm, greaterThanOrEqualTo(420));
    });

    test('is twelve weeks long and starts on a Monday', () {
      expect(plan.weekCount, 12);
      expect(plan.weeks.first.startDate.weekday, DateTime.monday);
    });

    test('run/walk ratio progresses from more walking to more running', () {
      expect(runWalkRatio(0).run, lessThan(runWalkRatio(11).run));
      expect(runWalkRatio(0).walk, greaterThan(runWalkRatio(11).walk));
    });

    test('ends with the race when a goal is set', () {
      final withGoal = beginnerPlan(
        goal: goal(RaceDistance.k5,
            finishTime: const Duration(minutes: 30), inWeeks: 12),
      );
      final last = withGoal.weeks.last;
      expect(last.phase, PlanPhase.raceWeek);
      expect(last.workouts.any((w) => w.type == WorkoutType.race), isTrue);
    });
  });

  group('trained path with a goal', () {
    final goalRace = goal(RaceDistance.marathon,
        finishTime: const Duration(hours: 3, minutes: 40), inWeeks: 18);
    final plan = trainedPlan(goal: goalRace);

    test('is selected for a trained runner', () {
      expect(plan.path, TrainingPath.trainedRace);
    });

    test('runs from week one to race week', () {
      expect(plan.weekCount, greaterThanOrEqualTo(minimumWeeksForFullPlan));
      expect(plan.weeks.last.phase, PlanPhase.raceWeek);
    });

    test('has all four phases in order', () {
      final phases = plan.weeks.map((w) => w.phase).toList();
      final firstBase = phases.indexOf(PlanPhase.base);
      final firstSpecific = phases.indexOf(PlanPhase.specific);
      final firstPeak = phases.indexOf(PlanPhase.peak);
      final firstTaper = phases.indexOf(PlanPhase.taper);
      expect(firstBase, 0);
      expect(firstSpecific, greaterThan(firstBase));
      expect(firstPeak, greaterThan(firstSpecific));
      expect(firstTaper, greaterThan(firstPeak));
    });

    test('never exceeds two quality sessions in a week', () {
      for (final w in plan.weeks) {
        expect(w.qualityCount, lessThanOrEqualTo(2), reason: 'week ${w.weekNumber}');
      }
    });

    test('the taper descends monotonically', () {
      final taper = plan.weeks.where((w) => w.phase == PlanPhase.taper).toList();
      expect(taper.length, greaterThanOrEqualTo(2));
      for (var i = 1; i < taper.length; i++) {
        expect(
          taper[i].targetVolumeKm,
          lessThan(taper[i - 1].targetVolumeKm),
          reason: 'taper week ${taper[i].weekNumber}',
        );
      }
    });

    test('race week is the lightest week', () {
      final peak = plan.weeks
          .where((w) => w.phase != PlanPhase.raceWeek)
          .map((w) => w.targetVolumeKm)
          .reduce((a, b) => a > b ? a : b);
      expect(plan.weeks.last.targetVolumeKm, lessThan(peak));
    });

    test('has cutback weeks', () {
      expect(plan.weeks.any((w) => w.isCutback), isTrue);
    });
  });

  group('safety invariants hold for every generated plan', () {
    final cases = <String, TrainingPlan>{
      'beginner, no goal': beginnerPlan(),
      'beginner, 5K goal': beginnerPlan(
          goal: goal(RaceDistance.k5,
              finishTime: const Duration(minutes: 30), inWeeks: 12)),
      'beginner, marathon goal': beginnerPlan(
        profile: beginnerProfile(monthsRunning: 2),
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 4, minutes: 30), inWeeks: 24),
      ),
      'trained, no goal': trainedPlan(),
      'trained, marathon goal': trainedPlan(
          goal: goal(RaceDistance.marathon,
              finishTime: const Duration(hours: 3, minutes: 40), inWeeks: 18)),
      'trained, half goal': trainedPlan(
          goal: goal(RaceDistance.half,
              finishTime: const Duration(hours: 1, minutes: 40), inWeeks: 12)),
      'trained, 5K goal, 3 days': trainedPlan(
        profile: trainedProfile(daysPerWeek: 3),
        goal: goal(RaceDistance.k5,
            finishTime: const Duration(minutes: 20),
            inWeeks: 10,
            daysPerWeek: 3),
      ),
      'trained, 6 days': trainedPlan(
        profile: trainedProfile(daysPerWeek: 6),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 40),
            inWeeks: 14,
            daysPerWeek: 6),
      ),
      'very short runway': trainedPlan(
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 30), inWeeks: 3),
      ),
      'very long runway': trainedPlan(
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 30), inWeeks: 40),
      ),
    };

    for (final entry in cases.entries) {
      group(entry.key, () {
        final plan = entry.value;

        test('the sessions prescribed add up to the week they belong to', () {
          // The number on the plan screen is what the runner is being asked to
          // do, so it has to be the number its sessions add up to. A peak week
          // once handed out two quality sessions while budgeting for one — 8 km
          // more running than the plan claimed — and a capped long run left the
          // real total 16% under a target nothing reported.
          for (final w in plan.weeks) {
            final prescribed = w.runVolumeKm;
            expect(
              prescribed,
              closeTo(w.targetVolumeKm, 0.01),
              reason: 'week ${w.weekNumber}: ${prescribed.toStringAsFixed(1)} '
                  'prescribed against a ${w.targetVolumeKm.toStringAsFixed(1)} target',
            );
          }
        });

        test('long runs stay inside the share allowed for the day count', () {
          // Day-aware, not a flat 32%. On three days a 32% long run is
          // arithmetically forced to be shorter than an easy day, because the
          // other 68% splits across two days at 34% each.
          for (final w in plan.weeks) {
            final long = w.longRun;
            if (long == null || w.targetVolumeKm == 0) continue;
            expect(
              long.distanceKm,
              lessThanOrEqualTo(
                w.targetVolumeKm * maxLongRunFractionFor(runDaysIn(w)) + 0.01,
              ),
              reason: 'week ${w.weekNumber}: ${long.distanceKm} of ${w.targetVolumeKm}',
            );
          }
        });

        test('the long run is the longest run of its week', () {
          for (final w in plan.weeks) {
            final long = w.longRun;
            if (long == null) continue;
            for (final r in w.workouts) {
              if (r.type == WorkoutType.rest || r == long) continue;
              expect(
                r.distanceKm,
                lessThanOrEqualTo(long.distanceKm + 0.01),
                reason: 'week ${w.weekNumber}: ${r.title} is longer than the long run',
              );
            }
          }
        });

        test('long runs stay under the absolute ceiling', () {
          for (final w in plan.weeks) {
            final long = w.longRun;
            if (long == null) continue;
            expect(long.distanceKm, lessThanOrEqualTo(maxLongRunKm));
            if (long.targetDuration != null) {
              expect(long.targetDuration!, lessThanOrEqualTo(maxLongRunDuration));
            }
          }
        });

        test('long runs grow no faster than the limit', () {
          final longs = plan.weeks
              .where((w) => w.longRun != null && w.phase != PlanPhase.taper)
              .map((w) => w.longRun!.distanceKm)
              .toList();
          final beginner = plan.path == TrainingPath.beginnerBase;
          for (var i = 1; i < longs.length; i++) {
            final delta = longs[i] - longs[i - 1];
            if (delta > 0) {
              expect(
                delta,
                lessThanOrEqualTo(beginner ? beginnerLongRunGrowth + 0.01 : 2.6),
                reason: 'jump $delta at index $i',
              );
            }
          }
        });

        test('at least 80% of volume is at or below easy pace', () {
          for (final w in plan.weeks) {
            if (w.targetVolumeKm == 0) continue;
            // Race weeks are by definition not easy, and a tempo week
            // legitimately dips slightly. Everything else must hold.
            if (w.phase == PlanPhase.raceWeek) continue;
            expect(
              w.easyFraction,
              greaterThanOrEqualTo(easyVolumeTarget - 0.03),
              reason: 'week ${w.weekNumber}: ${w.easyFraction}',
            );
          }
        });

        test('respects the requested days per week', () {
          final requested = plan.goal?.daysPerWeek ?? 4;
          final cap = requested < 3 ? 3 : requested;
          for (final w in plan.weeks) {
            expect(w.runCount, lessThanOrEqualTo(cap + 1),
                reason: 'week ${w.weekNumber}: ${w.runCount} runs');
          }
        });

        test('never has more than 7 days of content', () {
          for (final w in plan.weeks) {
            expect(w.workouts.length, lessThanOrEqualTo(7));
          }
        });

        test('weeks are consecutive and start on a Monday', () {
          for (var i = 0; i < plan.weeks.length; i++) {
            expect(plan.weeks[i].weekNumber, i + 1);
            expect(plan.weeks[i].startDate.weekday, DateTime.monday);
            if (i > 0) {
              expect(
                plan.weeks[i].startDate
                    .difference(plan.weeks[i - 1].startDate)
                    .inDays,
                7,
              );
            }
          }
        });
      });
    }
  });

  group('plan length clamping', () {
    test('a very short runway is clamped up to the minimum', () {
      final plan = trainedPlan(
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 30), inWeeks: 2),
      );
      expect(plan.weekCount, greaterThanOrEqualTo(minimumWeeksForFullPlan));
    });

    test('a very long runway is clamped down and the runner is told', () {
      final plan = trainedPlan(
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 30), inWeeks: 40),
      );
      expect(plan.weekCount, lessThanOrEqualTo(maxPlanWeeks));
      expect(
        plan.flags.any((f) => f.title.contains('capped')),
        isTrue,
      );
    });
  });

  group('phase allocation', () {
    test('produces the requested number of weeks', () {
      for (var n = minimumWeeksForFullPlan; n <= maxPlanWeeks; n++) {
        expect(allocatePhases(n).length, n, reason: '$n weeks');
      }
    });

    test('does not overflow on a very short block', () {
      // Below the minimum the generator clamps, but the allocator itself must
      // not return more weeks than asked for.
      for (var n = 3; n < minimumWeeksForFullPlan; n++) {
        expect(allocatePhases(n).length, n, reason: '$n weeks');
      }
    });

    test('always keeps a taper and a race week', () {
      for (var n = minimumWeeksForFullPlan; n <= maxPlanWeeks; n++) {
        final p = allocatePhases(n);
        expect(p.contains(PlanPhase.raceWeek), isTrue, reason: '$n weeks');
        expect(p.contains(PlanPhase.taper), isTrue, reason: '$n weeks');
        expect(p.contains(PlanPhase.peak), isTrue, reason: '$n weeks');
      }
    });

    test('a longer block gets a longer taper', () {
      expect(
        allocatePhases(20).where((p) => p == PlanPhase.taper).length,
        greaterThan(allocatePhases(8).where((p) => p == PlanPhase.taper).length),
      );
    });

    test('quality sessions are never more than two', () {
      for (final p in PlanPhase.values) {
        for (final days in [3, 4, 5, 6]) {
          expect(qualitySessionsFor(p, days), lessThanOrEqualTo(2),
              reason: '${p.name} at $days days');
        }
      }
    });

    test('a four-day week gets one quality session, not two', () {
      // The count used to be a flat 2 for specific/peak, and the placement
      // guard could not fire below five days — so a 4-day week budgeted two hard
      // sessions out of its volume and then prescribed one. See qualitySlots.
      for (final p in [PlanPhase.specific, PlanPhase.peak]) {
        expect(qualitySessionsFor(p, 3), 1, reason: p.name);
        expect(qualitySessionsFor(p, 4), 1, reason: p.name);
        expect(qualitySessionsFor(p, 5), 2, reason: p.name);
        expect(qualitySessionsFor(p, 6), 2, reason: p.name);
      }
    });

    test('quality slots never collide with the long run or recovery', () {
      for (final days in [3, 4, 5, 6]) {
        for (final count in [1, 2]) {
          if (count > qualitySessionsFor(PlanPhase.peak, days)) continue;
          final slots = qualitySlots(days, count);
          expect(slots.length, count, reason: '$days days, $count');
          expect(slots, isNot(contains(0)), reason: 'recovery day');
          expect(slots, isNot(contains(days - 1)), reason: 'long run day');
          expect(slots.toSet().length, slots.length, reason: 'no duplicates');
        }
      }
    });
  });

  group('the 90% rule reaches the generated plan', () {
    // buildVolumeCurve is tested in isolation in volume_test; this proves the
    // wiring from week logs through generate() to actual week volumes.
    const g = RaceDistance.marathon;
    final clean = generate(
      profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
      races: [raceK10(const Duration(minutes: 45))],
      goal: goal(g, finishTime: const Duration(hours: 3, minutes: 40), inWeeks: 18),
      startDate: testToday,
    );

    Map<String, WeekLog> logsFor(
      TrainingPlan plan,
      Map<int, WeekLog> byIndex,
    ) =>
        {
          for (final e in byIndex.entries)
            weekKey(plan.weeks[e.key].startDate): e.value,
        };

    TrainingPlan withLogs(Map<int, WeekLog> byIndex) => generate(
          profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
          races: [raceK10(const Duration(minutes: 45))],
          goal: goal(g, finishTime: const Duration(hours: 3, minutes: 40), inWeeks: 18),
          startDate: testToday,
          weekLogs: logsFor(clean, byIndex),
        );

    test('a clean plan builds as before', () {
      expect(clean.weeks[3].targetVolumeKm,
          greaterThan(clean.weeks[0].targetVolumeKm));
    });

    test('missing week 1 holds week 2 flat', () {
      final plan = withLogs({0: const WeekLog(sessionsDone: 1, difficulty: 9)});
      expect(plan.weeks[1].targetVolumeKm, plan.weeks[0].targetVolumeKm);
    });

    test('the hold is local — the curve resumes after a good week', () {
      final plan = withLogs({
        0: const WeekLog(sessionsDone: 1),
        1: const WeekLog(completed: true, sessionsDone: 4),
      });
      expect(plan.weeks[1].targetVolumeKm, plan.weeks[0].targetVolumeKm);
      expect(
        plan.weeks[2].targetVolumeKm,
        greaterThan(plan.weeks[1].targetVolumeKm),
      );
    });

    test('completing the week restores the build', () {
      final held = withLogs({0: const WeekLog(sessionsDone: 1)});
      final done = withLogs({0: const WeekLog(completed: true, sessionsDone: 4)});
      expect(
        held.weeks[1].targetVolumeKm,
        lessThan(done.weeks[1].targetVolumeKm),
      );
      // The clean plan matches the fully-completed one.
      expect(
        done.weeks[1].targetVolumeKm,
        closeTo(clean.weeks[1].targetVolumeKm, 0.001),
      );
    });

    test('safety invariants still hold on a held plan', () {
      final plan = withLogs({
        for (var i = 0; i < 4; i++) i: const WeekLog(sessionsDone: 0),
      });
      for (final w in plan.weeks) {
        final long = w.longRun;
        if (long == null || w.targetVolumeKm == 0) continue;
        expect(
          long.distanceKm,
          lessThanOrEqualTo(
            w.targetVolumeKm * maxLongRunFractionFor(runDaysIn(w)) + 0.01,
          ),
          reason: 'week ${w.weekNumber}',
        );
      }
    });

    test('a beginner plan reacts the same way', () {
      final cleanBeginner = generate(
        profile: beginnerProfile(),
        races: const [],
        goal: null,
        startDate: testToday,
      );
      final keys = {
        weekKey(cleanBeginner.weeks[0].startDate):
            const WeekLog(sessionsDone: 0),
      };
      final held = generate(
        profile: beginnerProfile(),
        races: const [],
        goal: null,
        startDate: testToday,
        weekLogs: keys,
      );
      expect(
        held.weeks[1].targetVolumeKm,
        held.weeks[0].targetVolumeKm,
      );
      expect(
        cleanBeginner.weeks[1].targetVolumeKm,
        greaterThan(cleanBeginner.weeks[0].targetVolumeKm),
      );
    });
  });

  group('plan start day', () {
    test('a Monday is used as-is', () {
      expect(alignToNextMonday(testToday).weekday, DateTime.monday);
      expect(alignToNextMonday(testToday), testToday);
    });

    test('mid-week snaps forward to the coming Monday', () {
      for (var offset = 1; offset < 7; offset++) {
        final date = testToday.add(Duration(days: offset));
        final next = alignToNextMonday(date);
        expect(next.weekday, DateTime.monday, reason: 'offset $offset');
        expect(
          next.isAfter(date),
          isTrue,
          reason: 'must move forward, not back',
        );
        expect(next.difference(date).inDays, lessThanOrEqualTo(7));
      }
    });

    test('a plan generated from a mid-week onboarding starts on a Monday',
        () {
      // Wednesday onboarding: the plan must not start half-way through a week,
      // or the runner looks behind before running a step.
      final wednesday = testToday.add(const Duration(days: 2));
      final plan = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: null,
        startDate: alignToNextMonday(wednesday),
      );
      expect(plan.weeks.first.startDate.weekday, DateTime.monday);
      expect(plan.weeks.first.startDate.isAfter(wednesday), isTrue);
    });

    test('weeks are consecutive from the snapped start', () {
      final plan = generate(
        profile: trainedProfile(monthsRunning: 36, weeklyKm: 40),
        races: [raceK10(const Duration(minutes: 45))],
        goal: null,
        startDate: alignToNextMonday(testToday.add(const Duration(days: 3))),
      );
      for (var i = 1; i < plan.weekCount; i++) {
        expect(
          plan.weeks[i].startDate
              .difference(plan.weeks[i - 1].startDate)
              .inDays,
          7,
        );
      }
    });
  });

  test('generation is a pure function of its inputs', () {
    final a = trainedPlan(
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 40), inWeeks: 18));
    final b = trainedPlan(
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 40), inWeeks: 18));
    expect(a.weekCount, b.weekCount);
    for (var i = 0; i < a.weekCount; i++) {
      expect(a.weeks[i].targetVolumeKm, b.weeks[i].targetVolumeKm);
      expect(a.weeks[i].workouts.length, b.weeks[i].workouts.length);
    }
  });
}

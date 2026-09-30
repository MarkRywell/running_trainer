/// The taper: volume down, intensity **kept**.
///
/// Found via a real report. A runner peaking at 59.7 km saw a taper open at
/// 40.2 km of almost entirely easy running, and read it as barely a taper at
/// all. Two separate faults, and the second was the serious one:
///
/// - The drop was a compounding `t *= 0.70` applied per week, so a three-week
///   taper ran 70/49/34% of peak. The *first* taper week therefore sat at ~70%,
///   and 40–50% — Daniels' figure — was only reached in the last week, by
///   accident, on the way past.
/// - `qualitySessionsFor` returned **0** for `PlanPhase.taper`, so the taper
///   dropped volume and sharpness together. That is a deload, not a taper, and
///   it left the runner arriving for their goal race with no hard running in
///   three weeks. `PlanPhase.taper`'s blurb said "Volume down, intensity kept"
///   the entire time, which is a copy/code contradiction — the exact class of bug
///   that ships because the words are right and the code is not.
library;

import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/plan_directive.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

RunnerProfile _runner({double km = 45, int days = 4}) => RunnerProfile(
      name: 'Sam',
      age: 34,
      gender: Gender.preferNotToSay,
      monthsRunning: 36,
      daysPerWeek: days,
      estimatedWeeklyKm: km,
    );

TrainingPlan _plan(RaceDistance distance, int inWeeks, {int days = 4}) =>
    generate(
      profile: _runner(days: days),
      races: [raceK10(const Duration(minutes: 45))],
      goal: goal(distance, finishTime: _target(distance), inWeeks: inWeeks),
      startDate: testToday,
    );

Duration _target(RaceDistance d) => switch (d) {
      RaceDistance.k5 => const Duration(minutes: 24),
      RaceDistance.k10 => const Duration(minutes: 45),
      RaceDistance.half => const Duration(hours: 1, minutes: 45),
      RaceDistance.marathon => const Duration(hours: 3, minutes: 30),
    };

List<PlanWeek> _taperWeeks(TrainingPlan p) =>
    p.weeks.where((w) => w.phase == PlanPhase.taper).toList();

double _peakOf(TrainingPlan p) => p.weeks
    .where((w) => w.phase != PlanPhase.taper && w.phase != PlanPhase.raceWeek)
    .map((w) => w.targetVolumeKm)
    .reduce((a, b) => a > b ? a : b);

void main() {
  group('the schedule is front-loaded and lands in Daniels’ band', () {
    for (final inWeeks in [12, 16, 20]) {
      test('a $inWeeks week block', () {
        final plan = _plan(RaceDistance.marathon, inWeeks);
        final taper = _taperWeeks(plan);
        final peak = _peakOf(plan);

        for (var i = 1; i < taper.length; i++) {
          expect(
            taper[i].targetVolumeKm,
            lessThan(taper[i - 1].targetVolumeKm),
            reason: 'taper week ${taper[i].weekNumber} is not below the one '
                'before it',
          );
        }

        // The final pre-race week is the one the runner actually races in, so
        // that is the week the 40–50% figure is about.
        final finalFraction = taper.last.targetVolumeKm / peak;
        expect(finalFraction, inInclusiveRange(0.40, 0.50),
            reason: 'final taper week is ${(finalFraction * 100).round()}% '
                'of a ${peak.toStringAsFixed(1)} km peak');

        // And the drop must be front-loaded: the first taper week cannot be the
        // biggest one, which is what compounding a rate cannot express.
        expect(taper.first.targetVolumeKm / peak, lessThan(0.70));
      });
    }

    test('the schedule itself is the documented one', () {
      expect(taperSchedule[3]!.last, finalTaperFractionTarget);
      expect(taperSchedule[2]!.last, lessThan(0.50));
      for (final week in taperSchedule[3]!) {
        expect(week, inInclusiveRange(0.40, 0.65));
      }
    });

    test('a base block never tapers at all', () {
      // It opts out with a flat curve, so it must not be handed a schedule.
      final plan = generate(
        profile: _runner(),
        races: [raceK10(const Duration(minutes: 45))],
        goal: null,
        startDate: testToday,
      );
      expect(_taperWeeks(plan), isEmpty);
    });
  });

  group('intensity is kept, not dropped with the volume', () {
    for (final distance in RaceDistance.values) {
      test('a ${distance.label} goal', () {
        final plan = _plan(distance, 16);
        final taper = _taperWeeks(plan);
        final finalWeek = taper.last;

        final hard = finalWeek.workouts
            .where((w) => w.isQuality && w.type != WorkoutType.race)
            .toList();
        expect(hard, hasLength(1),
            reason: 'the final taper week must carry one hard session');

        final session = hard.single;
        // At *goal* pace. Running the reps at anything faster would make the
        // taper a second race week.
        expect(session.zone, IntensityZone.marathon);
        expect(session.repZone, IntensityZone.marathon);
        expect(session.reps, isNotNull);
        expect(session.repDistanceM, isNotNull);
      });
    }

    test('only the final taper week carries hard work', () {
      final taper = _taperWeeks(_plan(RaceDistance.half, 16));
      for (final w in taper.take(taper.length - 1)) {
        expect(
          w.workouts.where((s) => s.isQuality).isEmpty,
          isTrue,
          reason: 'week ${w.weekNumber} should be easy — the final session '
              'belongs 4-5 days out, not three weeks out',
        );
      }
    });

    test('the session is sharp, not big', () {
      // Taper work is sharp, not big. Without a bound a runner on a large week
      // gets a 9 km quality session inside a 25 km week, which is a race
      // rehearsal.
      for (final days in [3, 4, 5, 6]) {
        final plan = _plan(RaceDistance.half, 16, days: days);
        final week = _taperWeeks(plan).last;
        final hard = week.hardVolumeKm;
        expect(
          hard / week.targetVolumeKm,
          lessThan(0.25),
          reason: '${(hard / week.targetVolumeKm * 100).round()}% hard at '
              '$days days',
        );
      }
    });

    test('it is not the longest run of the week', () {
      // A set longer than the long run breaks the invariant that the long run
      // is the longest run, which the runner reads as a broken plan.
      for (final days in [3, 4, 5, 6]) {
        final plan = _plan(RaceDistance.marathon, 16, days: days);
        for (final w in plan.weeks) {
          final long = w.longRun;
          if (long == null) continue;
          for (final s in w.workouts) {
            expect(s.distanceKm, lessThanOrEqualTo(long.distanceKm + 0.01),
                reason: 'week ${w.weekNumber} at $days days: '
                    '${s.title} (${s.distanceKm.toStringAsFixed(1)}) exceeds '
                    'the long run (${long.distanceKm.toStringAsFixed(1)})');
          }
        }
      }
    });

    test('it is never removed by drop-quality', () {
      // `suppressQuality` fires at 3 hard sessions and used to be able to erase
      // the taper's only quality session — at three days a week, that left a
      // runner with no hard running at all in the phase that exists to keep it.
      final plan = generate(
        profile: _runner(days: 3),
        races: [raceK10(const Duration(minutes: 45))],
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 45), inWeeks: 16),
        directive: const PlanDirective(suppressQuality: true),
        startDate: testToday,
      );
      final finalWeek = _taperWeeks(plan).last;
      expect(
        finalWeek.workouts.where((s) => s.isQuality).length,
        1,
        reason: 'the taper is exempt from the directive',
      );
    });
  });

  group('the taper is still a plan like any other', () {
    test('a week is what its own sessions add up to', () {
      for (final days in [3, 4, 5, 6]) {
        final plan = _plan(RaceDistance.marathon, 16, days: days);
        for (final w in plan.weeks) {
          expect(w.targetVolumeKm, closeTo(w.runVolumeKm, 0.01),
              reason: 'week ${w.weekNumber} at $days days');
        }
      }
    });

    test('80/20 still holds through the taper', () {
      for (final days in [3, 4, 5, 6]) {
        final plan = _plan(RaceDistance.half, 16, days: days);
        for (final w in plan.weeks) {
          if (w.phase == PlanPhase.raceWeek) continue;
          expect(w.easyFraction,
              greaterThanOrEqualTo(easyVolumeTarget - 0.03),
              reason: 'week ${w.weekNumber} at $days days');
        }
      }
    });
  });
}

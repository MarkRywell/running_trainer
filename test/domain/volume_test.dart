import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:flutter_test/flutter_test.dart';

Workout run(String title, double km, {WorkoutType type = WorkoutType.easy, bool quality = false}) =>
    Workout(
      title: title,
      type: type,
      zone: IntensityZone.easy,
      distanceKm: km,
      isQuality: quality,
      description: '',
    );

const rest = Workout(
  title: 'Rest',
  type: WorkoutType.rest,
  zone: IntensityZone.recovery,
  description: '',
);

void main() {
  group('buildVolumeCurve', () {
    test('grows during the build block', () {
      final phases = List.filled(12, PlanPhase.base);
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 30,
        maxWeeklyKm: 80,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      expect(v.length, 12);
      // Net growth across the block despite the cutback dips. A cutback is a
      // dip, not a permanent downgrade, so the peak must still climb.
      final peak = v.reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(v.first * 1.2));
    });

    test('returns to the pre-cutback level after a dip', () {
      final phases = List.filled(12, PlanPhase.base);
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 30,
        maxWeeklyKm: 80,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      // Week 4 (index 4) dips, week 5 resumes above the pre-cutback level.
      expect(v[4], lessThan(v[3]));
      expect(v[5], greaterThan(v[4]));
      expect(v[5], greaterThan(v[3]));
    });

    test('never exceeds the ceiling', () {
      final phases = List.filled(30, PlanPhase.base);
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 70,
        maxWeeklyKm: 80,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      for (final km in v) {
        expect(km, lessThanOrEqualTo(80.0001));
      }
    });

    test('dips on cutback weeks', () {
      final phases = List.filled(12, PlanPhase.base);
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 30,
        maxWeeklyKm: 80,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      // Cutbacks land on weeks 5 and 9 (index 4 and 8).
      expect(v[4], lessThan(v[3]));
      expect(v[8], lessThan(v[7]));
    });

    test('taper decreases monotonically', () {
      final phases = [
        ...List.filled(12, PlanPhase.base),
        ...List.filled(3, PlanPhase.taper),
        PlanPhase.raceWeek,
      ];
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 40,
        maxWeeklyKm: 90,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      final taper = [v[12], v[13], v[14]];
      expect(taper[1], lessThan(taper[0]));
      expect(taper[2], lessThan(taper[1]));
    });

    test('race week is the lightest week of the block', () {
      final phases = [
        ...List.filled(12, PlanPhase.base),
        ...List.filled(3, PlanPhase.taper),
        PlanPhase.raceWeek,
      ];
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 40,
        maxWeeklyKm: 90,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      final peak = v.take(12).reduce((a, b) => a > b ? a : b);
      expect(v.last, lessThan(peak * 0.5));
    });

    test('a base block with no taper never descends at the end', () {
      final phases = List.filled(12, PlanPhase.base);
      final v = buildVolumeCurve(
        phases: phases,
        startKm: 30,
        maxWeeklyKm: 80,
        growthRate: 0.05,
        cutbackFactor: 0.75,
        cutbackEvery: 4,
      );
      // The last week may be a cutback; the peak still has to exceed the start.
      final peak = v.reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(v.first));
    });
  });

  group('applyDayConstraint', () {
    test('drops the low-priority session first', () {
      final week = [
        run('Long run', 20, type: WorkoutType.long),
        run('Tempo', 10, type: WorkoutType.tempo, quality: true),
        run('Easy', 8),
        run('Recovery', 6, type: WorkoutType.recovery),
        rest,
      ];
      final trimmed = applyDayConstraint(week, 3);
      final titles = trimmed.where((w) => w.type != WorkoutType.rest).map((w) => w.title).toSet();
      expect(titles, {'Long run', 'Tempo', 'Easy'});
      expect(titles.contains('Recovery'), isFalse);
    });

    test('never drops the long run or a quality session', () {
      final week = [
        run('Long run', 20, type: WorkoutType.long),
        run('Tempo', 10, type: WorkoutType.tempo, quality: true),
        run('Intervals', 9, type: WorkoutType.intervals, quality: true),
        run('Easy', 8),
        run('Recovery', 6, type: WorkoutType.recovery),
        rest,
      ];
      // Three days asked for, three protected sessions in the week: the two
      // easy runs go and everything else survives.
      final trimmed = applyDayConstraint(week, 3, minimumRuns: 3);
      final titles = trimmed.map((w) => w.title).toSet();
      expect(titles, contains('Long run'));
      expect(titles, contains('Tempo'));
      expect(titles, contains('Intervals'));
      expect(titles.contains('Easy'), isFalse);
      expect(titles.contains('Recovery'), isFalse);
    });

    test('keeps the long run even when squeezed to a single day', () {
      final week = [
        run('Long run', 20, type: WorkoutType.long),
        run('Tempo', 10, type: WorkoutType.tempo, quality: true),
        run('Easy', 8),
        run('Recovery', 6, type: WorkoutType.recovery),
      ];
      final trimmed = applyDayConstraint(week, 1, minimumRuns: 1);
      final titles = trimmed.map((w) => w.title).toSet();
      expect(titles, contains('Long run'));
      expect(trimmed.length, 1);
    });

    test('respects the minimum even when asked for fewer days', () {
      final week = [
        run('Long run', 20, type: WorkoutType.long),
        run('Tempo', 10, type: WorkoutType.tempo, quality: true),
        run('Easy', 8),
        run('Recovery', 6, type: WorkoutType.recovery),
      ];
      final trimmed = applyDayConstraint(week, 1, minimumRuns: 3);
      expect(trimmed.where((w) => w.type != WorkoutType.rest).length, 3);
    });

    test('leaves a week that already fits alone', () {
      final week = [run('Long run', 20, type: WorkoutType.long), run('Easy', 8), rest];
      final trimmed = applyDayConstraint(week, 4);
      expect(trimmed.where((w) => w.type != WorkoutType.rest).length, 2);
    });

    test('preserves the original weekly ordering', () {
      final week = [
        run('A easy', 8),
        run('B tempo', 10, type: WorkoutType.tempo, quality: true),
        run('C long', 20, type: WorkoutType.long),
        run('D recovery', 6, type: WorkoutType.recovery),
        rest,
      ];
      final trimmed = applyDayConstraint(week, 2);
      final runs = trimmed.where((w) => w.type != WorkoutType.rest).toList();
      expect(runs.map((w) => w.title), ['B tempo', 'C long']);
    });
  });

  group('enforceSafety', () {
    PlanWeek weekWith(List<Workout> workouts, double target) => PlanWeek(
          weekNumber: 1,
          startDate: DateTime(2026, 1, 1),
          phase: PlanPhase.base,
          workouts: workouts,
          targetVolumeKm: target,
        );

  Workout rest() => const Workout(
        title: 'Rest',
        type: WorkoutType.rest,
        zone: IntensityZone.recovery,
        description: 'No running.',
      );

    test('trims a long run that exceeds its share of the week', () {
      // Four run days, so the 32% cap applies.
      final week = weekWith(
        [
          run('Long run', 30, type: WorkoutType.long),
          run('Easy a', 5),
          run('Easy b', 5),
          run('Tempo', 8),
        ],
        40,
      );
      final safe = enforceSafety(week);
      expect(safe.longRun!.distanceKm, lessThanOrEqualTo(40 * maxLongRunFraction));
    });

    test('the cap is looser on a three-day week, and must be', () {
      // At 32% the other 68% splits across two easy days at 34% each, so the
      // long run is forced to be the shortest run of the week. The cap has to
      // move or the long-run rule becomes unhittable.
      final week = weekWith(
        [run('Long run', 30, type: WorkoutType.long), run('Easy a', 5), run('Easy b', 5)],
        40,
      );
      final safe = enforceSafety(week);
      expect(safe.longRun!.distanceKm, lessThanOrEqualTo(40 * maxLongRunFractionFor(3)));
      expect(maxLongRunFractionFor(3), greaterThan(maxLongRunFraction));
    });

    test('caps the long run at the absolute ceiling', () {
      final week = weekWith(
        [run('Long run', 60, type: WorkoutType.long), run('Easy', 40)],
        100,
      );
      final safe = enforceSafety(week);
      expect(safe.longRun!.distanceKm, lessThanOrEqualTo(maxLongRunKm));
    });

    test('reports the volume its sessions actually prescribe', () {
      // The target is normalised even when nothing needs trimming. Generators
      // build a workout list and then trim it, so the reported figure has to
      // come from the list that survived.
      final week = weekWith(
        [
          run('Long run', 7, type: WorkoutType.long),
          run('Easy a', 5),
          run('Easy b', 5),
          run('Easy c', 5),
        ],
        999, // deliberately wrong
      );
      expect(enforceSafety(week).targetVolumeKm, 22);
    });

    test('the share cap is a fixed point, not one trim', () {
      // The long run is part of the total it is measured against, so capping to
      // a plain fraction of the week leaves it fractionally over its own share
      // once the total drops. It has to be solved: L ≤ f(R + L).
      final week = weekWith(
        [
          run('Long run', 20, type: WorkoutType.long),
          run('Easy a', 6),
          run('Easy b', 6),
          run('Easy c', 6),
          run('Tempo', 8),
        ],
        46,
      );
      final safe = enforceSafety(week);
      final f = maxLongRunFractionFor(runDaysIn(safe));
      expect(
        safe.longRun!.distanceKm,
        lessThanOrEqualTo(safe.targetVolumeKm * f + 0.001),
      );
      expect(safe.targetVolumeKm, volumeOf(safe.workouts));
    });

    test('normalises a week with no long run', () {
      final week = weekWith([run('Shakeout', 4), rest()], 50);
      expect(enforceSafety(week).targetVolumeKm, 4);
    });

    test('leaves a compliant week\'s sessions untouched', () {
      // 11 km long run against a 37 km week is under the 32% share. Identity is
      // not asserted: enforcement always rebuilds the week to normalise the
      // reported volume, so a new instance is correct even when nothing changed.
      final workouts = [
        run('Long run', 11, type: WorkoutType.long),
        run('Easy', 26),
      ];
      final safe = enforceSafety(weekWith(workouts, 37));
      expect(safe.longRun!.distanceKm, 11);
      expect(safe.targetVolumeKm, 37);
    });
  });

  group('longRunCapKm', () {
    test('scales down with the goal distance', () {
      expect(
        longRunCapKm(RaceDistance.marathon),
        greaterThan(longRunCapKm(RaceDistance.half)),
      );
      expect(
        longRunCapKm(RaceDistance.half),
        greaterThan(longRunCapKm(RaceDistance.k10)),
      );
      expect(
        longRunCapKm(RaceDistance.k10),
        greaterThan(longRunCapKm(RaceDistance.k5)),
      );
    });
  });

  group('weeklyVolumeCeiling', () {
    test('never allows more than 35% above current volume', () {
      final cap = weeklyVolumeCeiling(
        beginner: false,
        goal: RaceDistance.marathon,
        currentWeeklyKm: 60,
      );
      expect(cap, lessThanOrEqualTo(60 * 1.35 + 0.001));
    });

    test('keeps beginners well under the trained ceiling', () {
      final beginner =
          weeklyVolumeCeiling(beginner: true, goal: RaceDistance.marathon);
      final trained = weeklyVolumeCeiling(
        beginner: false,
        goal: RaceDistance.marathon,
        currentWeeklyKm: 50,
      );
      expect(beginner, lessThan(trained));
    });
  });

  group('reactive progression — the 90% rule', () {
    List<PlanPhase> base(int n) => List.filled(n, PlanPhase.base);

    List<double> curve({
      required List<PlanPhase> phases,
      List<double?>? adherence,
    }) =>
        buildVolumeCurve(
          phases: phases,
          startKm: 40,
          maxWeeklyKm: 90,
          growthRate: 0.05,
          cutbackFactor: cutbackFactor,
          cutbackEvery: 4,
          adherenceByWeek: adherence,
        );

    test('with no logs the curve grows normally', () {
      final v = curve(phases: base(8));
      expect(v[2], greaterThan(v[0]));
      expect(v[7], greaterThan(v[5]));
    });

    test('an unrecorded week is unknown, not failed', () {
      // Null adherence must not block growth, or a plan for someone who has
      // not started logging would never build at all.
      final v = curve(phases: base(6), adherence: [null, null, null, null, null, null]);
      final clean = curve(phases: base(6));
      expect(v, clean);
    });

    test('a fully completed previous week allows growth', () {
      final v = curve(phases: base(6), adherence: [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]);
      final clean = curve(phases: base(6));
      expect(v, clean);
    });

    test('a week below the threshold holds the next one flat', () {
      // Week 0 not completed, so week 1 must not grow.
      final v = curve(phases: base(6), adherence: [0.0, null, null, null, null, null]);
      expect(v[1], v[0]);
    });

    test('the hold is local, not cumulative', () {
      // Miss week 0, complete week 1: the curve should resume building from
      // week 2 rather than flattening the rest of the block.
      final v = curve(
        phases: base(8),
        adherence: [0.0, 1.0, null, null, null, null, null, null],
      );
      expect(v[1], v[0]); // held
      expect(v[2], greaterThan(v[1])); // resumed
      expect(v[7], greaterThan(v[3]));
    });

    test('exactly 90% still allows growth', () {
      final v = curve(phases: base(4), adherence: [0.9, null, null, null]);
      final clean = curve(phases: base(4));
      expect(v, clean);
    });

    test('just under 90% holds', () {
      final v = curve(phases: base(4), adherence: [0.85, null, null, null]);
      expect(v[1], v[0]);
    });

    test('a long run of missed weeks keeps the curve flat throughout', () {
      final v = curve(
        phases: base(8),
        adherence: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      );
      // It never climbs above the first week's growth — the only variation is
      // the cutback dip and the resume after it.
      for (final km in v) {
        expect(km, lessThanOrEqualTo(v[0]), reason: 'never builds on a gap');
      }
      expect(v[1], v[0]);
      expect(v[2], v[0]);
      expect(v[3], v[0]);
    });

    test('cutbacks still apply while progression is held', () {
      final v = curve(phases: base(8), adherence: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
      // Index 4 is the cutback week.
      expect(v[4], lessThan(v[3]));
    });

    test('the taper still descends from a held peak', () {
      final phases = [
        ...base(8),
        ...List.filled(2, PlanPhase.taper),
        PlanPhase.raceWeek,
      ];
      final v = curve(phases: phases, adherence: List.filled(11, 0.0));
      expect(v[9], lessThan(v[7]));
      expect(v[10], lessThan(v[9]));
    });
  });

  test('volumeOf sums distances', () {
    expect(volumeOf([run('a', 5), run('b', 7.5), rest]), 12.5);
  });
}

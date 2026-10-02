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

  group('the volume ceiling is disclosed, not silently applied', () {
    // A runner at 45 km/week gets a ceiling of 45 x 1.35 = 60.75, reaches it,
    // and then watches their volume sit flat for weeks with nothing on screen
    // saying why. The plan is behaving correctly; the runner is not told. This
    // is the same disclosure `_impliedVolume` already makes about guessing
    // mileage, for the opposite case.
    test('binds when two or more weeks sit at the ceiling', () {
      expect(
        volumeCeilingBinds(volumes: [40, 50, 60.75, 60.75, 60.75], ceiling: 60.75),
        isTrue,
      );
    });

    test('does not bind on a curve that never reaches the ceiling', () {
      expect(
        volumeCeilingBinds(volumes: [40, 44, 48, 52], ceiling: 60.75),
        isFalse,
      );
    });

    test('a single week at the ceiling is not a runner who has maxed out', () {
      // Touching the cap and turning around is not the same as being held there.
      // Without this the flag would fire on any block that happened to graze its
      // ceiling in its peak week.
      expect(
        volumeCeilingBinds(volumes: [40, 50, 60.75, 55], ceiling: 60.75),
        isFalse,
      );
    });

    test('a cutback dip between ceiling weeks is not a hold', () {
      // The first version of this counted *any* two weeks at the ceiling, so
      // reaching it, dipping for a cutback and returning looked identical to
      // being held there. It is not: the dip is a cutback resuming, and the
      // runner has not watched their volume sit still.
      expect(
        volumeCeilingBinds(volumes: [60.75, 45.5, 60.75], ceiling: 60.75),
        isFalse,
        reason: 'reaching the ceiling, dipping, and returning is not a hold',
      );
    });

    test('consecutive weeks at the ceiling bind even when a cutback precedes', () {
      expect(
        volumeCeilingBinds(volumes: [60.75, 45.5, 60.75, 60.75], ceiling: 60.75),
        isTrue,
        reason: 'the last two weeks really are held at the ceiling',
      );
    });

    test('an empty curve never binds', () {
      expect(volumeCeilingBinds(volumes: [], ceiling: 60), isFalse);
    });

    test('a zero or negative ceiling never binds', () {
      expect(volumeCeilingBinds(volumes: [10, 10], ceiling: 0), isFalse);
    });

    test('floating point drift does not hide the bind', () {
      // The curve is built by repeated multiplication, so a clamped week lands
      // fractionally *below* the cap rather than exactly on it. An `==`
      // comparison would miss this and the disclosure would never appear, which
      // is why the tolerance exists and why this test exists.
      final drifted = 60.75 - 1e-9;
      expect(
        volumeCeilingBinds(volumes: [50, drifted, drifted], ceiling: 60.75),
        isTrue,
      );
    });

    test('the flag names the ceiling and the arithmetic behind it', () {
      final flags = volumeCeilingFlags(
        volumes: [50, 60.75, 60.75],
        ceiling: 60.75,
        currentWeeklyKm: 45,
      );
      expect(flags, hasLength(1));
      expect(flags.first.severity, FlagSeverity.info);
      expect(flags.first.title, contains('reached the volume'));
      expect(flags.first.detail, contains('45'));
      expect(flags.first.detail, contains('61'));
    });

    test('no flag when the ceiling is not what stopped the curve', () {
      expect(
        volumeCeilingFlags(
          volumes: [40, 44, 48],
          ceiling: 60.75,
          currentWeeklyKm: 45,
        ),
        isEmpty,
      );
    });

    test('the disclosure reports the plan, not the curve that built it', () {
      // A regression that only appears on large-volume runners, and it is the
      // third instance of this repo's "budget says one thing, the plan does
      // another" fault. The curve for a 70 km/week runner runs toward 94.5, but
      // `enforceSafety` holds the reported weeks at 75.0 — the long-run cap and
      // 80/20 bind first. Judged on the raw curve the runner is told they have
      // maxed out when they have not, which is worse than saying nothing.
      // The raw curve for a 70 km/week runner: it climbs to the cap and is held
      // there, because nothing else in the curve knows about the long-run cap or
      // 80/20. Two weeks at the ceiling, so this is a genuine bind.
      final rawCurve = [70.0, 80.0, 88.0, 94.5, 94.5, 94.5];

      // What `enforceSafety` actually prescribes. The long-run cap and 80/20
      // bind first and hold the weeks at 75, so the ceiling was never reached by
      // anything the runner can see.
      final actuallyPrescribed = [70.0, 72.0, 74.0, 75.0, 75.0, 75.0];

      // The ceiling genuinely stopped the curve...
      expect(
        volumeCeilingBinds(volumes: rawCurve, ceiling: 94.5),
        isTrue,
      );
      // ...but the plan the runner is handed never reached it, so there is
      // nothing to disclose.
      expect(
        volumeCeilingBinds(volumes: actuallyPrescribed, ceiling: 94.5),
        isFalse,
        reason: 'the reported weeks top out at 75, well under a 94.5 ceiling',
      );
    });

    test('the ceiling is unchanged by any of this', () {
      // The disclosure explains the number; it does not get to move it. Changing
      // the progression ceiling is a methodology decision, and this is the
      // assertion that keeps the two from being quietly merged.
      expect(volumeProgressionFactor, 1.35);
      expect(
        weeklyVolumeCeiling(beginner: false, goal: null, currentWeeklyKm: 45),
        closeTo(60.75, 0.001),
      );
    });
  });
}

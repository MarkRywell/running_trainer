/// The beginner path: a 12-week base block.
///
/// ## Why this is a different product
///
/// The brief was a race plan, but the brief also said the plan must never be
/// too hard to follow. For a runner with under a year of experience those two
/// things collide, and the second one wins. Threshold work before an aerobic
/// base exists is the most reliable way to turn a new runner into a dropout
/// or an injury case.
///
/// So this plan contains **no quality sessions at all**. Everything is easy or
/// recovery, the progression is gentle, and the only goal is that the runner
/// is still running in twelve weeks. A race, if there is one, is treated as an
/// A-effort — the point is to finish it and enjoy it.
library;

import '../models/goal.dart';
import '../models/plan.dart';
import '../models/profile.dart';
import '../models/week_log.dart';
import '../units.dart';
import '../engine/volume.dart';
import 'generate.dart' show adherenceByWeek;

/// Length of a beginner base block, in weeks.
const int beginnerPlanWeeks = 12;

/// Seeds the first week of a beginner plan.
///
/// Without a real number, estimate from days run: roughly 4 km per easy day
/// is a defensible starting point for someone whose only anchor is frequency.
double seedBeginnerWeeklyKm(RunnerProfile profile) {
  final stated = profile.estimatedWeeklyKm;
  if (stated != null && stated >= 6) {
    return stated > 30 ? 30.0 : stated;
  }
  final days = profile.daysPerWeek.clampI(2, 6);
  final seed = days * 4.0;
  return seed.clampD(10.0, 30.0);
}

/// Run/walk ratio in seconds, progressing from 1:2 to 3:1 across the block.
///
/// Walk time shrinks and run time grows. By the end the runner is running
/// three minutes to their one minute of walk, which is a normal run with a
/// built-in recovery rather than a workout.
({int run, int walk}) runWalkRatio(int weekIndex) {
  final t = weekIndex.clampI(0, beginnerPlanWeeks - 1) / (beginnerPlanWeeks - 1);
  return (run: (60 + 120 * t).round(), walk: (120 - 60 * t).round());
}

TrainingPlan buildBeginnerPlan({
  required RunnerProfile profile,
  required TrainingPaces paces,
  required DateTime startDate,
  required GoalRace? goal,
  required int daysPerWeek,
  Map<String, WeekLog> weekLogs = const {},
  int? holdFromWeekIndex,
  List<PlanFlag> flags = const [],
}) {
  final monday = alignToMonday(startDate);
  final totalWeeks = beginnerPlanWeeks;
  final seed = seedBeginnerWeeklyKm(profile);
  final ceiling = weeklyVolumeCeiling(beginner: true, goal: goal?.distance);

  final phases = List<PlanPhase>.filled(totalWeeks, PlanPhase.baseBlock);
  final dayCount = daysPerWeek.clampI(beginnerMinimumRuns, 6);

  final volumes = buildVolumeCurve(
    phases: phases,
    startKm: seed,
    maxWeeklyKm: ceiling,
    growthRate: beginnerGrowthRate,
    cutbackFactor: cutbackFactor,
    cutbackEvery: cutbackEveryBeginner,
    adherenceByWeek: adherenceByWeek(
      weekLogs: weekLogs,
      weekCount: totalWeeks,
      prescribedSessions: dayCount,
      weekStartFor: (i) => monday.add(Duration(days: 7 * i)),
    ),
    holdFromWeekIndex: holdFromWeekIndex,
  );

  // The long run grows from about 25 minutes to an hour, in km at easy pace.
  //
  // It starts at 5 km rather than 3 because a three-day week splits the
  // remainder across two easy days, and a 3 km long run against a ~5 km easy
  // day is a plan that reads as broken even when it is not. The long run has to
  // look like the longest run of the week, because it is.
  final longStartKm = 5.0;
  final longCapKm = goal == null ? 12.0 : longRunCapKm(goal.distance) * 0.55;
  final longShare = longRunShare(dayCount);

  final weeks = <PlanWeek>[];
  // Zero, not [longStartKm]: week 1 is not growing out of a previous week, and
  // seeding it with a made-up predecessor made the growth cap shave week 1 and
  // leave the whole week short of its target.
  var previousLongKm = 0.0;

  for (var i = 0; i < totalWeeks; i++) {
    final weekStart = monday.add(Duration(days: 7 * i));
    final isLast = i == totalWeeks - 1;

    // The race, if there is one, lands in the final week. Bound to a local so
    // it promotes to non-null wherever `raceWeek` is true.
    final raceWeek = isLast ? goal : null;
    final hasGoal = raceWeek != null;
    final cutback =
        !hasGoal && isCutbackWeek(phases, i, cutbackEveryBeginner);

    final volume = raceWeek != null
        ? raceWeek.distance.metres / 1000 + 6
        : volumes[i].clampD(10.0, ceiling);

    // The long run is the week's share, floored by the block's own ramp.
    //
    // Interpolating it *independently* of the volume — as this once did — is
    // what put a 5 km long run inside a 30 km week and left the easy runs
    // longer than the long run. The ramp stays as a floor so a small week still
    // starts gently, and as a ceiling so a big one does not leap.
    final rampKm =
        longStartKm + (longCapKm - longStartKm) * (i / (totalWeeks - 1));
    var longKm = (volume * longShare).clampD(rampKm, longCapKm);
    if (cutback) longKm = previousLongKm * 0.8;
    longKm = capLongRunGrowth(previousLongKm, longKm, beginner: true);
    longKm = longKm.clampD(0.0, longCapKm);

    final pattern = weeklyDayPattern(dayCount);
    final ratio = runWalkRatio(i);

    final workouts = <Workout>[];
    final longDay = pattern.last;

    for (final d in pattern) {
      if (d == longDay && !hasGoal) {
        workouts.add(_longRun(i, longKm, paces, ratio));
      } else {
        workouts.add(_easyRun(pattern.indexOf(d), longDay, dayCount, volume, longKm, paces, ratio));
      }
    }

    for (var d = 1; d <= 7; d++) {
      if (!pattern.contains(d)) {
        workouts.add(const Workout(
          title: 'Rest',
          type: WorkoutType.rest,
          zone: IntensityZone.recovery,
          description: 'No running. Sleep, eat, let the training land.',
        ));
      }
    }

    // Stamp before the race is appended. The race occupies the long run's slot
    // in the week, so it goes on afterwards with that day attached directly.
    final stamped = attachWeekdays(workouts, pattern);
    if (raceWeek != null) {
      stamped.add(Workout(
        title: raceWeek.distance.label,
        type: WorkoutType.race,
        zone: IntensityZone.marathon,
        distanceKm: raceWeek.distance.metres / 1000,
        targetDuration: raceWeek.finishTimeGoal,
        isQuality: true,
        // The race sits where the long run would have been.
        weekday: longDay,
        description:
            'Your goal race. Run it at the effort you trained for — easy and '
            'controlled, and take it from the start. Finishing is the goal.',
      ));
    }

    stamped.sort((a, b) => a.title.compareTo(b.title));

    // Constrain first, then measure. Deriving the target from the pre-trim list
    // reported a volume the week could no longer reach — the day constraint had
    // already dropped sessions by the time the runner read the number.
    final constrained =
        applyDayConstraint(stamped, dayCount, minimumRuns: beginnerMinimumRuns);

    var week = enforceSafety(PlanWeek(
      weekNumber: i + 1,
      startDate: weekStart,
      phase: hasGoal ? PlanPhase.raceWeek : PlanPhase.baseBlock,
      workouts: constrained,
      targetVolumeKm: volumeOf(constrained),
      isCutback: cutback,
    ));
    // Baseline is the enforced distance, so the growth cap reflects what the
    // runner actually runs rather than what was asked for.
    final enforced = week.longRun?.distanceKm;
    if (enforced != null) previousLongKm = enforced;
    weeks.add(week);
  }

  return TrainingPlan(
    path: TrainingPath.beginnerBase,
    weeks: weeks,
    paces: paces,
    weeklyVolumeKm: seed,
    startDate: monday,
    goal: goal,
    flags: flags,
  );
}

Workout _longRun(
  int weekIndex,
  double longKm,
  TrainingPaces paces,
  ({int run, int walk}) ratio,
) {
  final duration = paces.easy.overDistance(longKm * 1000);
  return Workout(
    title: 'Long run',
    type: WorkoutType.long,
    zone: IntensityZone.easy,
    distanceKm: longKm,
    targetDuration: duration,
    description:
        'The most important run of your week, and it is an EASY one. '
        '${ratio.run}s running, ${ratio.walk}s walking, repeated. Conversational '
        'the whole way — if you cannot talk in short sentences, slow down.',
  );
}

Workout _easyRun(
  int position,
  int longDay,
  int dayCount,
  double volume,
  double longKm,
  TrainingPaces paces,
  ({int run, int walk}) ratio,
) {
  final otherDays = dayCount - 1;
  final share = otherDays <= 0 ? 0.0 : (volume - longKm) / otherDays;
  // Never longer than the long run. On a three-day week the leftover volume
  // splits across two easy days, and without this ceiling the "easy" runs come
  // out longer than the long run — which is the bug that started all this.
  final km = share <= 1 ? 4.0 : share.clampD(3.0, easyRunCapKm(longKm));

  // Day before the long run is deliberately the easiest — it sets up the
  // quality of the long run rather than compromising it.
  final isDayBeforeLong = longDay - 1 == _weekdayOf(position, dayCount, longDay);

  return Workout(
    title: isDayBeforeLong ? 'Easy run + strides' : 'Easy run',
    type: isDayBeforeLong ? WorkoutType.strides : WorkoutType.easy,
    zone: IntensityZone.easy,
    distanceKm: km,
    targetDuration: paces.easy.overDistance(km * 1000),
    description: isDayBeforeLong
        ? 'Easy, then 4–6 x 20s strides with 2 min jog recovery. '
            'Loose and springy, not sprinting.'
        : '${ratio.run}s running, ${ratio.walk}s walking, repeated. Easy and '
            'conversational throughout.',
  );
}

int _weekdayOf(int position, int dayCount, int longDay) =>
    weeklyDayPattern(dayCount)[position];

/// Which weekdays a given number of run days falls on. 1 = Monday.
List<int> weeklyDayPattern(int days) => switch (days.clampI(2, 7)) {
      2 => const [3, 6],
      3 => const [1, 3, 6],
      4 => const [1, 3, 5, 7],
      5 => const [1, 2, 4, 6, 7],
      6 => const [1, 2, 3, 4, 6, 7],
      _ => const [1, 2, 3, 4, 5, 6, 7],
    };

/// Snaps a date back to the Monday of its week.
DateTime alignToMonday(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.subtract(Duration(days: d.weekday - 1));
}

/// The next Monday on or after [date].
///
/// Plans are meant to start fresh on a Monday. Snapping *forward* avoids a
/// half-gone first week, and — more importantly — stops a runner who finishes
/// onboarding on a Wednesday from looking behind from day one, because the
/// completion data would show week 1 already part-elapsed.
///
/// Today being a Monday is used as-is: someone onboarding on a Monday can
/// start on it.
DateTime alignToNextMonday(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.add(Duration(days: (DateTime.monday - d.weekday + 7) % 7));
}

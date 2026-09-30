/// The trained path: a periodized block built backwards from race day.
///
/// Unlike the beginner base block, this one is not a fixed length. The shape
/// comes from how much runway there actually is, and the phases are sized to
/// fit rather than being hardcoded.
library;

import 'beginner_plan.dart';
import 'generate.dart';
import '../models/goal.dart';
import '../models/plan.dart';
import '../models/plan_directive.dart';
import '../models/profile.dart';
import '../models/week_log.dart';
import '../units.dart';
import '../engine/volume.dart';

/// Longest block we will generate. Beyond this the extra weeks are a plateau,/// not progress, and a 20-week plan is already a serious commitment.
const int maxPlanWeeks = 20;

class RacePlanResult {
  const RacePlanResult({
    required this.plan,
    required this.weeksGenerated,
    required this.weeksAvailable,
  });

  final TrainingPlan plan;

  /// Weeks actually generated.
  final int weeksGenerated;

  /// Weeks the runner had before we capped it. Larger than [weeksGenerated]
  /// means the plan was truncated and the runner should be told.
  final int weeksAvailable;
}

/// Allocates phases across [totalWeeks] of runway.
///
/// Sizing is proportional rather than fixed so a 10-week plan and a 20-week
/// plan both keep their shape instead of the short one losing its base phase
/// entirely.
List<PlanPhase> allocatePhases(int totalWeeks) {
  // Very short blocks still need a taper and a race week, but not a big one.
  // Without this the fixed minimums below would overflow the requested length.
  if (totalWeeks < 6) {
    return [
      ...List.filled((totalWeeks - 2).clampI(1, 99), PlanPhase.base),
      PlanPhase.taper,
      PlanPhase.raceWeek,
    ];
  }

  // A very short block still needs a taper, just a shorter one.
  final taperWeeks = totalWeeks >= 12 ? 3 : 2;
  var build = totalWeeks - taperWeeks - 1; // one race week
  if (build < 3) build = 3;

  var base = (build * 0.40).round();
  var specific = (build * 0.35).round();
  var peak = build - base - specific;
  if (peak < 1) {
    // Borrow from specific, then base, so peak is never empty.
    final deficit = 1 - peak;
    specific -= deficit;
    peak = 1;
  }
  if (base < 1) base = 1;

  return [
    ...List.filled(base, PlanPhase.base),
    ...List.filled(specific, PlanPhase.specific),
    ...List.filled(peak.clampI(1, 99), PlanPhase.peak),
    ...List.filled(taperWeeks, PlanPhase.taper),
    PlanPhase.raceWeek,
  ];
}

/// Quality sessions per week, by phase. Never more than two — more than that
/// is how periodization turns into overtraining.
int qualitySessionsFor(PlanPhase phase) => switch (phase) {
      PlanPhase.base => 1,
      PlanPhase.specific => 2,
      PlanPhase.peak => 2,
      PlanPhase.taper => 0,
      PlanPhase.raceWeek => 0,
      PlanPhase.baseBlock => 0,
    };

RacePlanResult buildRacePlan({
  required RunnerProfile profile,
  required TrainingPaces paces,
  required DateTime startDate,
  required GoalRace goal,
  required double currentWeeklyKm,
  Map<String, WeekLog> weekLogs = const {},
  int? holdFromWeekIndex,
  int? overrideDaysPerWeek,
  PlanDirective directive = const PlanDirective(),
  List<PlanFlag> flags = const [],
}) {
  final monday = alignToMonday(startDate);
  final available = goal.weeksUntilFrom(monday);
  final totalWeeks = available.clampI(minimumWeeksForFullPlan, maxPlanWeeks);

  final phases = allocatePhases(totalWeeks);
  final ceiling = weeklyVolumeCeiling(
    beginner: false,
    goal: goal.distance,
    currentWeeklyKm: currentWeeklyKm,
  );
  final seed = currentWeeklyKm > 0
      ? currentWeeklyKm.clampD(15.0, ceiling)
      : (ceiling * 0.45);

  final dayCount = (overrideDaysPerWeek ?? goal.daysPerWeek).clampI(3, 6);
  final pattern = weeklyDayPattern(dayCount);
  final capKm = longRunCapKm(goal.distance);

  final volumes = buildVolumeCurve(
    phases: phases,
    startKm: seed,
    maxWeeklyKm: ceiling,
    growthRate: trainedGrowthRate,
    cutbackFactor: cutbackFactor,
    cutbackEvery: cutbackEveryTrained,
    adherenceByWeek: adherenceByWeek(
      weekLogs: weekLogs,
      weekCount: totalWeeks,
      prescribedSessions: pattern.length,
      weekStartFor: (i) => monday.add(Duration(days: 7 * i)),
    ),
    holdFromWeekIndex: holdFromWeekIndex,
  );

  final weeks = <PlanWeek>[];
  var previousLongKm = 0.0;

  final buildWeeks = buildWeekCount(phases);

  for (var i = 0; i < phases.length; i++) {
    final phase = phases[i];
    final weekStart = monday.add(Duration(days: 7 * i));
    final isRaceWeek = phase == PlanPhase.raceWeek;
    final isCutback =
        !isRaceWeek && isCutbackWeek(i, cutbackEveryTrained, buildWeeks);

    if (isRaceWeek) {
      // Through enforcement like every other week, so the reported volume is
      // the shakeout plus the race rather than an estimate of them. The race
      // and shakeout place themselves, since a race week is not laid out by the
      // day pattern.
      weeks.add(enforceSafety(_raceWeek(i, weekStart, goal, paces, pattern)));
      continue;
    }

    // Long run tracks the week's volume, which means cutbacks and the taper
    // pull it down automatically instead of needing separate rules.
    // The 6 km floor is a floor for a normal week, not an override: on a
    // three-day week at low volume it would prescribe more than the runner
    // does in total. It is capped by the week's own share instead.
    final share = longRunShare(pattern.length);
    final floor = 6.0.clampD(0.0, volumes[i] * share);
    var longKm = volumes[i] * share;
    if (isCutback) longKm *= 0.9;
    longKm = longKm.clampD(floor, capKm);
    longKm = capLongRunGrowth(previousLongKm, longKm, beginner: false)
        .clampD(floor, capKm);

    final workouts = _buildWeek(
      phase: phase,
      pattern: pattern,
      longKm: longKm,
      targetVolume: volumes[i],
      paces: paces,
      weekIndex: i,
      isCutback: isCutback,
      suppressQuality: directive.suppressQuality,
    );

    var week = PlanWeek(
      weekNumber: i + 1,
      startDate: weekStart,
      phase: phase,
      workouts: workouts,
      targetVolumeKm: volumes[i],
      isCutback: isCutback,
    );
    week = enforceSafety(week);
    // Baseline for the next week's growth cap is the distance the runner will
    // *actually* cover, which enforcement may have trimmed. Using the
    // pre-enforcement figure let growth exceed the cap after a cutback.
    final enforced = week.longRun?.distanceKm;
    if (enforced != null) previousLongKm = enforced;
    weeks.add(week);
  }

  final allFlags = <PlanFlag>[
    if (available > maxPlanWeeks)
      PlanFlag(
        severity: FlagSeverity.info,
        title: 'Plan capped at $maxPlanWeeks weeks',
        detail:
            'You have $available weeks until race day. Plans longer than '
            '$maxPlanWeeks weeks stop making progress — the extra time is a '
            'plateau, not a build. This plan covers the final $maxPlanWeeks '
            'weeks, which is the part that matters. Use the time before it to '
            'build a base.',
      ),
    ...flags,
  ];

  return RacePlanResult(
    plan: TrainingPlan(
      path: TrainingPath.trainedRace,
      weeks: weeks,
      paces: paces,
      weeklyVolumeKm: seed,
      startDate: monday,
      goal: goal,
      flags: allFlags,
    ),
    weeksGenerated: totalWeeks,
    weeksAvailable: available,
  );
}

PlanWeek _raceWeek(
  int index,
  DateTime weekStart,
  GoalRace goal,
  TrainingPaces paces,
  List<int> pattern,
) {
  final raceKm = goal.distance.metres / 1000;
  // The race takes the plan's last run day, the shakeout its first, and the
  // rest whatever day falls between them. A session log needs all three placed.
  final raceDay = pattern.isEmpty ? 7 : pattern.last;
  final shakeoutDay = pattern.length > 1 ? pattern.first : 1;
  final restDay = shakeoutDay < raceDay ? shakeoutDay + 1 : 1;
  return PlanWeek(
    weekNumber: index + 1,
    startDate: weekStart,
    phase: PlanPhase.raceWeek,
    targetVolumeKm: raceKm + 5,
    workouts: [
      Workout(
        title: 'Shakeout + strides',
        type: WorkoutType.strides,
        zone: IntensityZone.recovery,
        distanceKm: 4,
        targetDuration: Duration(minutes: 30),
        weekday: shakeoutDay,
        description:
            '4 km very easy with 4 x 20s strides. Nothing more. You want to '
            'arrive on Sunday rested, not tired.',
      ),
      const Workout(
        title: 'Rest',
        type: WorkoutType.rest,
        zone: IntensityZone.recovery,
        description: 'No running today.',
      ).withWeekday(restDay),
      Workout(
        title: goal.distance.label,
        type: WorkoutType.race,
        zone: IntensityZone.marathon,
        distanceKm: raceKm,
        targetDuration: goal.finishTimeGoal,
        isQuality: true,
        weekday: raceDay,
        description:
            'Your goal race. Start controlled — the first 5 km slower than '
            'feels right — and move up only when the pace is effortless.',
      ),
    ],
  );
}

List<Workout> _buildWeek({
  required PlanPhase phase,
  required List<int> pattern,
  required double longKm,
  required double targetVolume,
  required TrainingPaces paces,
  required int weekIndex,
  required bool isCutback,
  required bool suppressQuality,
}) {
  // `suppressQuality` turns hard sessions into easy ones rather than dropping
  // days, so the week keeps its mileage and its shape. The beginner base block
  // is a proven zero-quality plan, so the resulting shape is known to be valid.
  final qualityCount =
      isCutback || suppressQuality ? 0 : qualitySessionsFor(phase);
  final days = pattern.length;
  final workouts = <Workout>[];

  // Assign roles to days. The day after the long run is recovery, quality
  // goes early in the week with a rest day behind it, and the last day of
  // the pattern is the long run.
  final longIndex = days - 1;

  // Quality sessions are prescribed by their own sensible length rather than
  // inheriting an easy-day share. A tempo is not a long run: making it as long
  // as the easy days is what pushed the week past 80% easy.
  final qualityKm =
      capQualityAgainstLong(qualityDistanceKm(targetVolume), longKm);
  final easyDays = (days - 1 - qualityCount).clampI(1, 99);
  // Every quality session has to come out of the easy budget, not just the
  // first. Subtracting one while prescribing two handed the runner an extra
  // 9–15 km in every peak week — a week of up to 82 km built to a 74 km target.
  final qualityTotalKm = qualityKm * qualityCount;
  final easyKm =
      _easyShare(targetVolume - qualityTotalKm, longKm, easyDays);

  for (var i = 0; i < days; i++) {
    if (i == longIndex) {
      workouts.add(_longRun(phase, longKm, paces, weekIndex));
      continue;
    }
    if (i == 0) {
      // Straight after the weekend long run.
      workouts.add(Workout(
        title: 'Recovery run',
        type: WorkoutType.recovery,
        zone: IntensityZone.recovery,
        distanceKm: easyKm,
        targetDuration: paces.recovery.overDistance(easyKm * 1000),
        description: 'Deliberately slow. Absorb the long run, do not add to it.',
      ));
      continue;
    }
    if (qualityCount > 0 && i == 1) {
      workouts.add(_quality(phase, paces, weekIndex, qualityKm));
      continue;
    }
    if (qualityCount > 1 && i == 3 && days > 4) {
      workouts.add(_secondQuality(phase, paces, qualityKm));
      continue;
    }
    workouts.add(_easy(easyKm, paces));
  }

  for (var d = 1; d <= 7; d++) {
    if (!pattern.contains(d)) {
      workouts.add(const Workout(
        title: 'Rest',
        type: WorkoutType.rest,
        zone: IntensityZone.recovery,
        description: 'No running. This is where the training actually happens.',
      ));
    }
  }

  return attachWeekdays(workouts, pattern);
}

/// Reps in an interval session, and the shape of each.
///
/// Derived from the distance rather than fixed, so a scaled-down session on a
/// small week comes with a rep count that adds up instead of a set that
/// overruns the week it was prescribed for.
const Duration intervalRep = Duration(minutes: 3);
const Duration intervalRecovery = Duration(minutes: 3);

int intervalReps(TrainingPaces paces, double km) {
  final hard = paces.interval.overDistance(km * 1000 * intervalHardFraction);
  final cycle = intervalRep + intervalRecovery;
  return (hard.inSeconds / cycle.inSeconds).round().clampI(4, 8);
}

double _easyShare(double total, double longKm, int easyDays) {
  if (easyDays <= 0) return 0;
  final remaining = total - longKm;
  if (remaining <= 0) return 5;
  final share = remaining / easyDays;
  return share.clampD(3.0, easyRunCapKm(longKm));
}

Workout _easy(double km, TrainingPaces paces) => Workout(
      title: 'Easy run',
      type: WorkoutType.easy,
      zone: IntensityZone.easy,
      distanceKm: km,
      targetDuration: paces.easy.overDistance(km * 1000),
      description:
          'Conversational throughout. This is most of your training, and it is '
          'the part that makes you faster. If it feels too easy, it is right.',
    );

Workout _longRun(PlanPhase phase, double km, TrainingPaces paces, int weekIndex) {
  final duration = paces.easy.overDistance(km * 1000);
  final (title, description) = switch (phase) {
    PlanPhase.base => (
        'Long run',
        'Easy, all the way. This is the foundation — do not add pace to it. '
            'Finish feeling like you could have gone further.'
      ),
    PlanPhase.specific => (
        'Long run + goal-pace block',
        'Easy for the first two thirds, then ${(km * 0.33).round()} km at '
            'marathon pace. The goal-pace block should feel controlled — like '
            'you could hold it, not like you are racing it.'
      ),
    PlanPhase.peak => (
        'Long run + race-pace finish',
        'Easy, then 3 km at marathon pace, then 2 km at goal pace. Practise '
            'the last 5 km of your race: tired legs, even effort, strong finish.'
      ),
    PlanPhase.taper => (
        'Long run (short)',
        'Shorter than you want, and that is the point. Keep it easy. You are '
            'absorbing training, not adding it.'
      ),
    _ => ('Long run', 'Easy, conversational.'),
  };

  return Workout(
    title: title,
    type: WorkoutType.long,
    zone: IntensityZone.easy,
    distanceKm: km,
    targetDuration: duration,
    description: description,
  );
}

Workout _quality(PlanPhase phase, TrainingPaces paces, int weekIndex, double km) {
  // Base phase builds the engine with tempo; later phases add sharpness.
  final interval = phase == PlanPhase.specific && weekIndex.isOdd;
  if (interval) return _secondQuality(phase, paces, km);

  // The prescribed time follows from the prescribed distance, so the copy and
  // the number can never drift apart on a scaled-down week.
  final hard =
      paces.threshold.overDistance(km * 1000 * tempoHardFraction).inMinutes;

  return Workout(
    title: 'Tempo',
    type: WorkoutType.tempo,
    zone: IntensityZone.threshold,
    distanceKm: km,
    targetDuration: paces.easy.overDistance(km * 1000),
    isQuality: true,
    hardFractionOfDistance: tempoHardFraction,
    description:
        '10 min easy warm-up, then $hard min steady at '
        '${paces.threshold.format()}/km — comfortably hard, controlled, roughly '
        '"I could go a little faster". 5 min cool down.',
  );
}

Workout _secondQuality(PlanPhase phase, TrainingPaces paces, double km) {
  final isPeak = phase == PlanPhase.peak;
  final reps = intervalReps(paces, km);
  final hard =
      paces.interval.overDistance(km * 1000 * intervalHardFraction).inMinutes;
  return Workout(
    title: isPeak ? 'Sharpening intervals' : '5K-effort intervals',
    type: WorkoutType.intervals,
    zone: IntensityZone.interval,
    distanceKm: km,
    targetDuration: paces.easy.overDistance(km * 1000),
    isQuality: true,
    hardFractionOfDistance: intervalHardFraction,
    description:
        '10 min warm-up, then $reps x 3 min at ${paces.interval.format()}/km '
        'with 3 min easy jog recovery — about $hard min of hard running — then '
        'cool down. The recovery is as important as the reps: if you are '
        'running them all out, do fewer of them.',
  );
}

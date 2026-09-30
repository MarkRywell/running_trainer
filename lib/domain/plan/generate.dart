/// Plan generation: the single entry point.
///
/// The plan is a pure function of (profile, races, goal, startDate). That is
/// what makes it testable, and it is also the source of this file's one
/// significant limitation — see `TrainingPlan` regeneration in the README of
/// the plan: with no completion data, regenerating always rebuilds from week
/// zero.
library;

import '../engine/fitness.dart';
import '../engine/validation.dart';
import '../engine/volume.dart';
import '../engine/zones.dart';
import '../models/goal.dart';
import '../models/plan.dart';
import '../models/plan_directive.dart';
import '../models/profile.dart';
import '../models/race.dart';
import '../models/week_log.dart';
import '../progress.dart';
import '../units.dart';
import 'beginner_plan.dart';
import 'race_plan.dart';

/// No race data at all and no goal to anchor on: assume a modest, genuinely
/// beginner aerobic base. Only the easy and recovery zones are ever used on
/// this path, but the whole set is derived from one anchor for consistency.
const int defaultBeginnerMarathonEquivalentSecPerKm = 321; // 5:21/km

/// Conversational easy pace should never be faster than this, whatever the
/// goal says. A beginner who sets an ambitious goal time should not end up
/// being told to run their easy miles at 6:00/km.
const int beginnerEasyPaceFloorSecPerKm = 420; // 7:00/km

/// Per-week adherence, as a ratio of prescribed sessions actually run.
///
/// `null` for a week with no record. Prescribed sessions come from the day's
/// day-count rather than the generated plan, because the volume curve has to be
/// built *before* the weeks exist — reading run counts off a plan that does not
/// exist yet would be circular.
///
/// [weekStartFor] yields the start date of week [i], which is stable regardless
/// of what the curve decides, since the week *structure* depends only on the
/// goal and the start date.
List<double?>? adherenceByWeek({
  required Map<String, WeekLog> weekLogs,
  required int weekCount,
  required int prescribedSessions,
  required DateTime Function(int i) weekStartFor,
}) {
  if (weekLogs.isEmpty) return null;
  return List<double?>.generate(weekCount, (i) {
    final log = weekLogs[weekKey(weekStartFor(i))];
    if (log == null || !log.hasData) return null;
    final done = log.sessionsDone;
    if (done != null) {
      if (prescribedSessions <= 0) return null;
      return done / prescribedSessions;
    }
    return log.completed ? 1.0 : 0.0;
  });
}

TrainingPlan generate({
  required RunnerProfile profile,
  required List<RaceResult> races,
  required GoalRace? goal,
  required DateTime startDate,
  Map<String, WeekLog> weekLogs = const {},
  PlanDirective directive = const PlanDirective(),
}) {
  final fitness = assessFitness(races, startDate);
  final beginner = isBeginnerPath(profile, fitness);

  // The week *structure* is known before any week is built: it depends only on
  // the goal and the start date. That is what lets the observed-intensity check
  // run inside `validate` without a generated plan to hand.
  final monday = alignToMonday(startDate);
  final totalWeeks = beginner
      ? beginnerPlanWeeks
      : (goal == null
          ? trainedBaseWeeks
          : (goal.weeksUntilFrom(monday)
              .clampI(minimumWeeksForFullPlan, maxPlanWeeks)));

  final flags = validate(
    profile: profile,
    fitness: fitness,
    goal: goal,
    today: startDate,
    weekLogs: weekLogs,
    weekCount: totalWeeks,
    weekStartFor: (i) => monday.add(Duration(days: 7 * i)),
  );

  final paces = derivePaces(fitness: fitness, goal: goal, beginner: beginner);

  // The volume cap starts at the first incomplete week, so weeks the runner
  // has already done keep the shape they were built with. The past is not
  // rewritten.
  final holdFrom = directive.capVolume
      ? firstIncompleteIndex(weekLogs: weekLogs, startDate: startDate)
      : null;

  final days = directive.targetDaysPerWeek;

  if (beginner) {
    return buildBeginnerPlan(
      profile: profile,
      paces: paces,
      startDate: startDate,
      goal: goal,
      daysPerWeek: days ?? profile.daysPerWeek,
      weekLogs: weekLogs,
      holdFromWeekIndex: holdFrom,
      flags: flags,
    );
  }

  if (goal != null) {
    final result = buildRacePlan(
      profile: profile,
      paces: paces,
      startDate: startDate,
      goal: goal,
      currentWeeklyKm: profile.estimatedWeeklyKm ?? _impliedVolume(fitness),
      weekLogs: weekLogs,
      holdFromWeekIndex: holdFrom,
      overrideDaysPerWeek: days,
      directive: directive,
      flags: flags,
    );
    return result.plan;
  }

  return buildTrainedBasePlan(
    profile: profile,
    paces: paces,
    startDate: startDate,
    daysPerWeek: days ?? profile.daysPerWeek,
    currentWeeklyKm: profile.estimatedWeeklyKm ?? _impliedVolume(fitness),
    weekLogs: weekLogs,
    holdFromWeekIndex: holdFrom,
    directive: directive,
    flags: flags,
  );
}

/// Index of the first plan week with no completed log.
///
/// Computed from the start date alone, before any plan exists — the week
/// structure depends only on the goal and the start date, so this is stable
/// and does not need a generated plan to answer.
int firstIncompleteIndex({
  required Map<String, WeekLog> weekLogs,
  required DateTime startDate,
  int weekCount = 64,
}) {
  if (weekLogs.isEmpty) return 0;
  final monday = startDate.subtract(Duration(days: startDate.weekday - 1));
  for (var i = 0; i < weekCount; i++) {
    final key = weekKey(monday.add(Duration(days: 7 * i)));
    final log = weekLogs[key];
    if (log == null || !log.completed) return i;
  }
  return 0;
}

/// Builds the five training paces.
///
/// The anchor is the **goal race pace** when a goal is set — training
/// relative to the race being prepared for, not to a current-fitness
/// prediction the runner never asked for. Current fitness is what validates
/// the goal, not what the paces are built from.
TrainingPaces derivePaces({
  required FitnessAssessment fitness,
  required GoalRace? goal,
  required bool beginner,
}) {
  if (beginner) {
    return _beginnerPaces(fitness: fitness, goal: goal);
  }

  final anchor = zoneAnchorPace(
    goalDistance: goal?.distance,
    goalFinishTime: goal?.finishTimeGoal,
    equivalentMarathonTime: fitness.equivalentTo(RaceDistance.marathon),
    anchorRaceDistance: fitness.anchor?.distance,
    anchorRaceTime: fitness.anchor?.time,
  );
  return pacesFromMarathonPace(anchor);
}

TrainingPaces _beginnerPaces({
  required FitnessAssessment fitness,
  required GoalRace? goal,
}) {
  // A runner with no race result has no demonstrated fitness, and **a goal is
  // not a substitute for one**. This used to be `goal == null && !hasData`,
  // because the goal race supplied the anchor; now that it does not, a beginner
  // who set a goal would fall through and throw. The assumed base below is the
  // honest answer: we do not know what this runner can do yet, and a goal is
  // what they intend rather than what they have shown.
  if (!fitness.hasData) {
    return applyBeginnerPaceFloor(
      pacesFromMarathonPace(const Pace(defaultBeginnerMarathonEquivalentSecPerKm)),
    );
  }

  final anchor = zoneAnchorPace(
    goalDistance: goal?.distance,
    goalFinishTime: goal?.finishTimeGoal,
    equivalentMarathonTime: fitness.equivalentTo(RaceDistance.marathon),
    anchorRaceDistance: fitness.anchor?.distance,
    anchorRaceTime: fitness.anchor?.time,
  );
  var paces = pacesFromMarathonPace(anchor);
  paces = applyBeginnerPaceFloor(paces);
  return paces;
}

/// Shifts the whole pace set so that easy running is at least conversational.
///
/// Applied as a shift rather than a clamp on the easy pace alone, so the
/// relationship between zones survives — otherwise recovery could end up
/// faster than easy.
TrainingPaces applyBeginnerPaceFloor(TrainingPaces paces) {
  if (paces.easy.secPerKm >= beginnerEasyPaceFloorSecPerKm) return paces;

  final shift = beginnerEasyPaceFloorSecPerKm - paces.easy.secPerKm;
  final mp = paces.marathon.secPerKm + shift;
  return pacesFromMarathonPace(Pace(mp));
}

/// A weekly volume inferred from race data, used when the runner did not
/// state one. Marathon-pace training volume is a crude but workable proxy:
/// someone who can run a 4:00 marathon is sustaining real mileage.
double _impliedVolume(FitnessAssessment fitness) {
  final marathon = fitness.equivalentTo(RaceDistance.marathon);
  if (marathon == null) return 30;
  final hours = marathon.inMinutes / 60;
  // Roughly 6–9 hours a week of running for a trained athlete.
  return (hours * 7.5).clampD(25.0, 75.0);
}

/// Seeds a plan for an experienced runner with no goal race set.
///
/// Not the same as the periodized race block: no taper, no peak, one quality
/// session a week, and volume built on general durability.
TrainingPlan buildTrainedBasePlan({
  required RunnerProfile profile,
  required TrainingPaces paces,
  required DateTime startDate,
  required int daysPerWeek,
  required double currentWeeklyKm,
  Map<String, WeekLog> weekLogs = const {},
  int? holdFromWeekIndex,
  PlanDirective directive = const PlanDirective(),
  List<PlanFlag> flags = const [],
}) {
  const totalWeeks = trainedBaseWeeks;
  final monday = alignToMonday(startDate);
  final ceiling = weeklyVolumeCeiling(beginner: false, goal: null, currentWeeklyKm: currentWeeklyKm);
  final seed = currentWeeklyKm.clampD(15.0, ceiling);

  final phases = List<PlanPhase>.filled(totalWeeks, PlanPhase.base);
  final dayCount = daysPerWeek.clampI(3, 6);
  final volumes = buildVolumeCurve(
    phases: phases,
    startKm: seed,
    maxWeeklyKm: ceiling,
    growthRate: trainedGrowthRate,
    cutbackFactor: cutbackFactor,
    cutbackEvery: cutbackEveryTrained,
    // No taper in a base block, so the curve never enters one.
    taperDrop: 1.0,
    adherenceByWeek: adherenceByWeek(
      weekLogs: weekLogs,
      weekCount: totalWeeks,
      prescribedSessions: dayCount,
      weekStartFor: (i) => monday.add(Duration(days: 7 * i)),
    ),
    holdFromWeekIndex: holdFromWeekIndex,
  );

  final pattern = weeklyDayPattern(dayCount);
  final capKm = longRunCapKm(RaceDistance.marathon) * 0.85;

  final weeks = <PlanWeek>[];
  var previousLongKm = 0.0;

  final buildWeeks = buildWeekCount(phases);

  for (var i = 0; i < totalWeeks; i++) {
    final weekStart = monday.add(Duration(days: 7 * i));
    final isCutback = isCutbackWeek(i, cutbackEveryTrained, buildWeeks);

    // The 6 km floor is a floor for a normal week, not an override: on a
    // three-day week at low volume it would prescribe more than the runner
    // does in total. It is capped by the week's own share instead.
    final floor = 6.0.clampD(0.0, volumes[i] * longRunShare(pattern.length));
    var longKm = (volumes[i] * longRunShare(pattern.length)).clampD(floor, capKm);
    if (isCutback) longKm *= 0.9;
    longKm = longKm.clampD(floor, capKm);
    longKm = capLongRunGrowth(previousLongKm, longKm, beginner: false)
        .clampD(floor, capKm);

    var week = PlanWeek(
      weekNumber: i + 1,
      startDate: weekStart,
      phase: PlanPhase.base,
      targetVolumeKm: volumes[i],
      isCutback: isCutback,
      workouts: _baseWeek(
        pattern: pattern,
        longKm: longKm,
        targetVolume: volumes[i],
        paces: paces,
        weekIndex: i,
        isCutback: isCutback,
        suppressQuality: directive.suppressQuality,
      ),
    );
    week = enforceSafety(week);
    final enforced = week.longRun?.distanceKm;
    if (enforced != null) previousLongKm = enforced;
    weeks.add(week);
  }

  return TrainingPlan(
    path: TrainingPath.trainedRace,
    weeks: weeks,
    paces: paces,
    weeklyVolumeKm: seed,
    startDate: monday,
    goal: null,
    flags: [
      const PlanFlag(
        severity: FlagSeverity.info,
        title: 'No goal race set',
        detail:
            'This is a general base block: build durability, one quality session '
            'a week, no taper. Set a goal race when you have one and we will '
            'rebuild this as a periodized block aimed at it.',
      ),
      ...flags,
    ],
  );
}

List<Workout> _baseWeek({
  required List<int> pattern,
  required double longKm,
  required double targetVolume,
  required TrainingPaces paces,
  required int weekIndex,
  required bool isCutback,
  required bool suppressQuality,
}) {
  final days = pattern.length;
  final workouts = <Workout>[];
  final longIndex = days - 1;
  final tempoKm = suppressQuality
      ? 0.0
      : capQualityAgainstLong(qualityDistanceKm(targetVolume), longKm);
  final easyDays = days - 1 - (isCutback || suppressQuality ? 0 : 1);
  final easyKm =
      ((targetVolume - tempoKm - longKm) / easyDays.clampI(1, 99))
          .clampD(3.0, easyRunCapKm(longKm));

  for (var i = 0; i < days; i++) {
    if (i == longIndex) {
      workouts.add(Workout(
        title: 'Long run',
        type: WorkoutType.long,
        zone: IntensityZone.easy,
        distanceKm: longKm,
        targetDuration: paces.easy.overDistance(longKm * 1000),
        description: 'Easy throughout. The base is built here, not in the '
            'workouts that feel hard.',
      ));
    } else if (i == 0) {
      workouts.add(Workout(
        title: 'Recovery run',
        type: WorkoutType.recovery,
        zone: IntensityZone.recovery,
        distanceKm: easyKm,
        targetDuration: paces.recovery.overDistance(easyKm * 1000),
        description: 'Deliberately slow.',
      ));
    } else if (i == 1 && !isCutback && !suppressQuality) {
      workouts.add(Workout(
        title: 'Tempo',
        type: WorkoutType.tempo,
        zone: IntensityZone.threshold,
        distanceKm: tempoKm,
        targetDuration: paces.easy.overDistance(tempoKm * 1000),
        isQuality: true,
        hardFractionOfDistance: tempoHardFraction,
        description:
            '10 min warm-up, then ${paces.threshold.overDistance(tempoKm * 1000 * tempoHardFraction).inMinutes}'
            ' min at ${paces.threshold.format()}/km — comfortably hard. '
            '5 min cool down.',
      ));
    } else {
      workouts.add(Workout(
        title: 'Easy run',
        type: WorkoutType.easy,
        zone: IntensityZone.easy,
        distanceKm: easyKm,
        targetDuration: paces.easy.overDistance(easyKm * 1000),
        description: 'Conversational. Most of your training, and the part that '
            'makes you faster.',
      ));
    }
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

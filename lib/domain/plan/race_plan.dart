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
import '../models/race.dart';
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

/// Quality sessions per week, by phase and day count. Never more than two —
/// more than that is how periodization turns into overtraining.
///
/// **The day count is not a safety limit bolted on afterwards, it is part of the
/// prescription.** A four-day week cannot host two quality sessions: with a
/// recovery day, a long run and two hard days there is no true easy day left,
/// which is the "never too hard" premise the whole product rests on.
///
/// This used to be decided the other way round and it failed quietly.
/// [qualitySessionsFor] returned 2 for a four-day specific week, [_buildWeek]
/// budgeted `qualityKm * 2` out of the week's volume, and then the placement
/// guard — `i == 3 && days > 4` — could never fire, because on
/// `weeklyDayPattern(4) == [1,3,5,7]` index 3 *is* the long run. The second
/// session fell through to the easy branch. The week still summed to its target
/// and every invariant still passed, so nothing reported a problem; the runner
/// just quietly got one tempo and one easy run where the plan's own arithmetic
/// had budgeted two hard sessions.
///
/// So the count and the placement are now derived from the same number, and a
/// test asserts the count of quality sessions rather than merely that one exists.
int qualitySessionsFor(PlanPhase phase, int runDays) => switch (phase) {
      PlanPhase.base => 1,
      PlanPhase.specific || PlanPhase.peak => runDays >= 5 ? 2 : 1,
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

    // Only the *last* taper week carries quality. Daniels puts the final hard
    // session 4–5 days out; anything earlier and the runner spends the taper
    // accumulating fatigue, which is the opposite of tapering.
    final isFinalTaperWeek = phase == PlanPhase.taper &&
        i + 1 == phases.length - 1 &&
        phases[i + 1] == PlanPhase.raceWeek;

    final workouts = _buildWeek(
      phase: phase,
      pattern: pattern,
      longKm: longKm,
      targetVolume: volumes[i],
      paces: paces,
      weekIndex: i,
      isCutback: isCutback,
      suppressQuality: directive.suppressQuality,
      weekInPhase: weekIndexWithinPhase(phases, i),
      goal: goal,
      isFinalTaperWeek: isFinalTaperWeek,
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

/// Which day positions in a run week carry quality work.
///
/// Derived from [runDays] rather than hardcoded to index 3, because index 3 *is*
/// the long run on a four-day week: `weeklyDayPattern(4) == [1,3,5,7]`, so
/// `longIndex == 3`. The old `i == 3 && days > 4` guard therefore could never
/// fire below five days — it was not a safety limit, it was an index collision.
///
/// Order is deliberate. Quality goes early in the week with a rest day behind it,
/// and the day straight after the long run is reserved for recovery.
List<int> qualitySlots(int runDays, int count) {
  final taken = <int>{0, runDays - 1};
  final slots = <int>[];
  for (final candidate in [1, 3, 2, 4, 5, 6]) {
    if (slots.length == count) break;
    if (!taken.contains(candidate)) slots.add(candidate);
  }
  return slots;
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
  int weekInPhase = 0,
  GoalRace? goal,
  bool isFinalTaperWeek = false,
}) {
  // `suppressQuality` turns hard sessions into easy ones rather than dropping
  // days, so the week keeps its mileage and its shape. The beginner base block
  // is a proven zero-quality plan, so the resulting shape is known to be valid.
  //
  // The taper is deliberately exempt. Its single quality session is the whole
  // point of the phase, and at three days a week `suppressQuality` would
  // otherwise erase the one hard session the runner is tapering toward.
  final taperQuality = isFinalTaperWeek && goal != null;
  final qualityCount = isCutback
      ? 0
      : taperQuality || !suppressQuality
          ? taperQuality
              ? 1
              : qualitySessionsFor(phase, pattern.length)
          : 0;
  final days = pattern.length;
  final workouts = <Workout>[];

  // Assign roles to days. The day after the long run is recovery, quality
  // goes early in the week with a rest day behind it, and the last day of
  // the pattern is the long run.
  final longIndex = days - 1;

  // Quality sessions are prescribed by their own sensible length rather than
  // inheriting an easy-day share. A tempo is not a long run: making it as long
  // as the easy days is what pushed the week past 80% easy. The 22% is the
  // *week's* quality budget, shared between the sessions it carries.
  final qualityKm = capQualityAgainstLong(
      qualityKmPerSession(targetVolume, qualityCount), longKm);

  // The sessions are built *before* the easy days are budgeted, because a
  // solved rep set is not `qualityKm` — it is the largest set that fits inside
  // it, so it lands at or under. Budgeting the easy days from the intent rather
  // than from the built sessions is how a week ends up reporting a target its
  // own workouts do not add up to.
  final slots = qualitySlots(days, qualityCount);
  final quality = <Workout>[
    if (taperQuality)
      _taperSharpening(goal, paces, longKm)
    else
      ..._qualitySessionsFor(phase, paces, weekInPhase, qualityKm, targetVolume,
          qualityCount),
  ];

  final qualityTotalKm = quality.fold<double>(0, (sum, w) => sum + w.distanceKm);
  final easyDays = (days - 1 - qualityCount).clampI(1, 99);
  // Every quality session has to come out of the easy budget, not just the
  // first. Subtracting one while prescribing two handed the runner an extra
  // 9–15 km in every peak week — a week of up to 82 km built to a 74 km target.
  final easyKm = _easyShare(
    targetVolume - qualityTotalKm,
    longKm,
    easyDays,
    floorKm: phase == PlanPhase.taper ? taperEasyRunFloorKm : 3.0,
  );

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
    if (slots.contains(i)) {
      workouts.add(quality[slots.indexOf(i)]);
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

/// A set that has been sized to fit a week: how many reps, and how much of the
/// session is actually hard.
///
/// The rep count is solved rather than fixed, which is the only way a 400m set
/// and a 2km set can share one quality-distance budget without one of them
/// either overrunning its week or wasting it. A 400m set at 4:00/km with 90s
/// recovery fits thirteen reps inside a 9 km budget; the same 9 km holds only
/// three 2km reps. Fixing the count would mean the session's distance had to
/// come from somewhere else, and then the week would no longer add up.
class SolvedSet {
  const SolvedSet({
    required this.format,
    required this.reps,
    required this.distanceKm,
    required this.hardFraction,
  });

  final RepFormat format;
  final int reps;

  /// Total session distance, warm-up and cool-down included.
  final double distanceKm;

  /// Share of [distanceKm] run at rep pace.
  final double hardFraction;

  /// Distance actually run at rep pace.
  double get hardKm => distanceKm * hardFraction;
}

/// How long one rep of [format] takes, in seconds.
double _repSeconds(RepFormat format, TrainingPaces paces) {
  final m = format.distanceM;
  if (m != null) {
    return paces
        .forZone(format.zone)
        .overDistance(m.toDouble())
        .inSeconds
        .toDouble();
  }
  return (format.work ?? intervalRep).inSeconds.toDouble();
}

/// Total distance of a [reps]-rep set of [format], warm-up and cool-down in.
double setDistanceKm(RepFormat format, int reps, TrainingPaces paces) {
  final easySeconds = (repWarmUpMinutes + repCoolDownMinutes) * 60 +
      format.recovery.inSeconds * (reps - 1).clampI(0, 99);
  final hardKm = _repSeconds(format, paces) * reps / paces.forZone(format.zone).secPerKm;
  return hardKm + easySeconds / paces.easy.secPerKm;
}

/// The most reps of [format] that fit inside [budgetKm], within the format's
/// own bounds.
///
/// Returns null when the format cannot reach [RepFormat.minReps] inside the
/// budget — the caller steps down to a shorter rep rather than prescribing a
/// set of two and calling it a set.
SolvedSet? solveSet(
  RepFormat format,
  double budgetKm,
  TrainingPaces paces,
) {
  var best = -1;
  for (var n = format.minReps; n <= format.maxReps; n++) {
    if (setDistanceKm(format, n, paces) > budgetKm) break;
    best = n;
  }
  if (best < 0) return null;

  return SolvedSet(
    format: format,
    reps: best,
    distanceKm: setDistanceKm(format, best, paces),
    hardFraction: hardFractionForReps(
      reps: best,
      repDistanceM: format.distanceM,
      repWork: format.work,
      recovery: format.recovery,
      repPaceSecondsPerKm: paces.forZone(format.zone).secPerKm.toDouble(),
      easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
    ),
  );
}

/// The distance-based rep formats, shortest rep first.
///
/// Ordered so that [solveFormatSet] walks *down* the list when a week is too
/// small for the format asked for. The order is the point: a 25 km week cannot
/// absorb ten 400m reps, and the correct adaptation is a **shorter rep**, not
/// cutting the set in half. Two 400s is not a set of 400s.
const List<RepFormat> _repLadder = [
  RepFormat(
      distanceM: 400,
      recovery: Duration(seconds: 90),
      zone: IntensityZone.interval,
      maxReps: 12),
  RepFormat(
      distanceM: 800,
      recovery: Duration(seconds: 90),
      zone: IntensityZone.interval,
      maxReps: 10),
  RepFormat(
      distanceM: 1000,
      recovery: Duration(seconds: 90),
      zone: IntensityZone.interval,
      maxReps: 8),
  // Long reps are threshold work, not interval work. Running 2km at interval
  // pace is a different and much more damaging session than the name implies,
  // which is why the zone travels with the distance.
  RepFormat(
      distanceM: 2000,
      recovery: Duration(seconds: 90),
      zone: IntensityZone.threshold,
      maxReps: 5),
];

/// Solve the first format in [_repLadder] that fits [budgetKm].
///
/// The 400m set is the sharpest thing this app can prescribe, so it is only
/// reached when the week is genuinely big — see [minVolumeForSharpReps].
SolvedSet? solveFormatSet(double budgetKm, TrainingPaces paces, {int from = 0}) {
  for (var i = from; i < _repLadder.length; i++) {
    final solved = solveSet(_repLadder[i], budgetKm, paces);
    if (solved != null) return solved;
  }
  return null;
}

/// Weekly volume below which the 400m set is not prescribed.
///
/// The premise of this product is "never too hard", and 400m repetitions at
/// interval pace are the most demanding session it can hand out. Gating them on
/// volume is the same reasoning as [longRunShare] being day-aware: a per-session
/// choice has to be checked against the smallest week that can contain it.
/// Above this the runner gets the full ladder; below it, peak weeks get 800m.
const double minVolumeForSharpReps = 40;

double _easyShare(double total, double longKm, int easyDays, {double floorKm = 3.0}) {
  if (easyDays <= 0) return 0;
  final remaining = total - longKm;
  if (remaining <= 0) return 5;
  final share = remaining / easyDays;
  return share.clampD(floorKm, easyRunCapKm(longKm));
}

/// Shortest an easy day may be during the taper.
///
/// The 3 km floor exists so a squeezed week does not prescribe a 1.5 km "run".
/// Applied to the taper it *inverted the taper*: the final taper week's volume
/// budget fell below `3 x easyDays`, the floor took over, and the week came out
/// **larger** than the one before it — 22.7 km against 19.1 km, which failed the
/// "taper descends monotonically" assertion. A shorter run in the taper is not
/// a defect, it is the taper, so the floor has to come down with it.
const double taperEasyRunFloorKm = 2.0;

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

/// The quality sessions of a week, in day order.
///
/// Returns **exactly** [count] sessions, and nothing at all for a count of zero.
/// The zero case is not a formality: a taper or cutback week builds no quality
/// work, and an early version of this returned a tempo for `count == 0` because
/// it tested `count <= 1`. The week then subtracted 5.9 km of tempo from its easy
/// budget and never placed the session, so every taper week came out ~6 km short
/// of its target and the taper stopped descending.
///
/// **At most one rep set per week**, and that is a hard rule rather than a
/// preference. Two sets in a week pushed `easyFraction` to 0.75 where the floor
/// is 0.77. A double-quality week is tempo plus set, which is also the more
/// useful pairing — the set teaches speed, the tempo teaches the pace that has
/// to hold it.
///
/// Which session is the set depends on the phase and on the week *within* that
/// phase. That is not a detail: the alternation used to be on the absolute plan
/// week, so the number of set sessions in the whole block depended on where the
/// base/specific boundary happened to land after rounding. Change the block
/// length by one week and the count moved for no reason the runner could see.
List<Workout> _qualitySessionsFor(
  PlanPhase phase,
  TrainingPaces paces,
  int weekInPhase,
  double km,
  double weeklyKm,
  int count,
) {
  final wantsSet = switch (phase) {
    PlanPhase.base => false,
    PlanPhase.specific => weekInPhase.isOdd,
    PlanPhase.peak => true,
    _ => false,
  };

  Workout set() => repSetSession(phase, paces, km, weeklyKm, weekInPhase);

  if (count == 0) return const [];
  if (count == 1) return [if (wantsSet) set() else _tempo(paces, km)];
  return [
    if (wantsSet) set() else _tempo(paces, km),
    if (wantsSet) _tempo(paces, km) else set(),
  ];
}

/// A steady threshold session: one continuous block, no reps.
///
/// The prescribed time follows from the prescribed distance, so the copy and
/// the number can never drift apart on a scaled-down week.
Workout _tempo(TrainingPaces paces, double km) {
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

/// How many weeks into its phase a plan week is.
///
/// Kept as one function because the specific phase's tempo/interval alternation
/// depends on it, and getting it wrong is invisible: a block still generates,
/// still passes every volume invariant, and simply has a different number of
/// interval sessions than intended.
int weekIndexWithinPhase(List<PlanPhase> phases, int weekIndex) {
  final phase = phases[weekIndex];
  var start = weekIndex;
  while (start > 0 && phases[start - 1] == phase) {
    start--;
  }
  return weekIndex - start;
}

/// A repetition set: the second quality session, or the first in peak.
///
/// The format is chosen from the phase and solved to fit the week's quality
/// budget, so the rep count is whatever the room allows rather than a constant.
/// A 400m set and a 2km set in the same block are genuinely different sessions —
/// different distance, different pace, different hard fraction — rather than one
/// session with a different number in the description.
Workout repSetSession(
  PlanPhase phase,
  TrainingPaces paces,
  double km,
  double weeklyKm,
  int weekInPhase, {
  int? ladderFrom,
}) {
  final isPeak = phase == PlanPhase.peak;
  final set = _setFor(phase, paces, km, weeklyKm, weekInPhase,
      ladderFrom: ladderFrom);
  if (set == null) return _tempo(paces, km);

  return Workout(
    title: _setTitle(set, isPeak),
    type: WorkoutType.intervals,
    zone: set.format.zone,
    distanceKm: set.distanceKm,
    targetDuration: paces.easy.overDistance(set.distanceKm * 1000),
    isQuality: true,
    hardFractionOfDistance: set.hardFraction,
    reps: set.reps,
    repDistanceM: set.format.distanceM,
    repRecovery: set.format.recovery,
    repZone: set.format.zone,
    description: _setDescription(set, paces),
  );
}

/// The goal-pace set a runner does in the final taper week.
///
/// **This session is the reason the taper exists.** Volume drops through the
/// taper; intensity does not. The app previously prescribed *zero* quality
/// sessions in every taper week — [qualitySessionsFor] returned 0 for
/// `PlanPhase.taper` — so its taper dropped volume and sharpness together, which
/// is a deload, not a taper. The runner arrived for their goal race having not
/// raced at that pace in three weeks.
///
/// The shape adapts to the goal distance, because "race pace" is meaningless
/// without one and because the session has to fit the week it lands in. A 5K
/// goal gets the sharpest short version; a marathon gets the same 2km reps held
/// at *marathon* pace rather than goal pace, which is both the honest
/// prescription and the safer one for a distance that is mostly aerobic.
const Map<RaceDistance, RepFormat> _taperFormats = {
  RaceDistance.k5: RepFormat(
    distanceM: 800,
    recovery: Duration(seconds: 120),
    zone: IntensityZone.marathon,
    minReps: 3,
    maxReps: 4,
  ),
  RaceDistance.k10: RepFormat(
    distanceM: 1200,
    recovery: Duration(seconds: 120),
    zone: IntensityZone.marathon,
    minReps: 3,
    maxReps: 3,
  ),
  RaceDistance.half: RepFormat(
    distanceM: 2000,
    recovery: Duration(seconds: 180),
    zone: IntensityZone.marathon,
    minReps: 2,
    maxReps: 2,
  ),
  RaceDistance.marathon: RepFormat(
    distanceM: 2000,
    recovery: Duration(seconds: 180),
    zone: IntensityZone.marathon,
    minReps: 2,
    maxReps: 2,
  ),
};

/// The final taper week's goal-pace session.
Workout _taperSharpening(GoalRace goal, TrainingPaces paces, double longKm) {
  final format = _taperFormats[goal.distance]!;

  // Budgeted against the **long run**, not the week. A taper week is the
  // smallest of the block, so a 9 km quality session inside a 25 km week is a
  // race rehearsal rather than a taper session — and, more concretely, a set
  // that outlasts the long run breaks the invariant that the long run is the
  // longest run of its week. That is not a style preference: the runner reads
  // "long run: 6.8 km" above "goal-pace reps: 7.1 km" and the plan stops making
  // sense to them.
  final budget =
      capQualityAgainstLong(longKm.clampD(0.0, maxTaperSessionKm), longKm);
  final set = solveSet(format, budget, paces);

  if (set != null) return _taperWorkout(goal, paces, format, set.reps);

  // The week is too small for the goal-distance format. Step down to a shorter
  // rep rather than dropping the session — the final hard session before a goal
  // race is the entire point of the phase, and quietly removing it is the exact
  // failure this change exists to fix. A set of one is still a session; it just
  // stops pretending to be a set of two.
  for (final shorter in _taperFormats.values) {
    if (identical(shorter, format)) continue;
    final fallback = solveSet(shorter, budget, paces);
    if (fallback != null) return _taperWorkout(goal, paces, shorter, fallback.reps);
  }

  final single = solveSet(
    RepFormat(
      distanceM: format.distanceM,
      recovery: format.recovery,
      zone: format.zone,
      minReps: 1,
      maxReps: 1,
    ),
    budget,
    paces,
  );
  return _taperWorkout(goal, paces, format, single?.reps ?? 1);
}

Workout _taperWorkout(
  GoalRace goal,
  TrainingPaces paces,
  RepFormat format,
  int reps,
) {
  final hardFraction = hardFractionForReps(
    reps: reps,
    repDistanceM: format.distanceM,
    repWork: format.work,
    recovery: format.recovery,
    repPaceSecondsPerKm: paces.marathon.secPerKm.toDouble(),
    easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
  );
  final distanceKm = setDistanceKm(format, reps, paces);

  return Workout(
    title: 'Goal-pace ${_formatDistance(format.distanceM!)} reps',
    type: WorkoutType.intervals,
    zone: IntensityZone.marathon,
    distanceKm: distanceKm,
    targetDuration: paces.easy.overDistance(distanceKm * 1000),
    isQuality: true,
    hardFractionOfDistance: hardFraction,
    reps: reps,
    repDistanceM: format.distanceM,
    repRecovery: format.recovery,
    repZone: format.zone,
    description:
        'The last hard running you do before ${goal.distance.label}. '
        '$repWarmUpMinutes min warm-up, then $reps x ${_formatDistance(format.distanceM!)} at '
        '${paces.marathon.format()}/km — your goal pace — with '
        '${_formatRecovery(format.recovery)} easy jog. Hold it, do not sprint '
        'it. Then $repCoolDownMinutes min cool down, and nothing hard again '
        'until race day.',
  );
}

/// Longest the taper's quality session may be, in km.
const double maxTaperSessionKm = 8.0;

/// The set format a phase prescribes, walked down [_repLadder] as needed.
///
/// The ladder is the whole adaptation mechanism: a week too small for the format
/// asked for gets a **shorter rep**, never a truncated set.
///
/// Which rung a phase *starts* from is the periodization. The specific phase
/// starts on 800m and moves to longer reps as the phase progresses — a long rep
/// is the race-specific work, and a short one is the sharpening work, so the
/// phase that prepares an athlete to hold a pace is the phase whose reps get
/// longer. Peak goes the other way and starts at the 400m rung, but only on a
/// week big enough to absorb it — see [minVolumeForSharpReps].
SolvedSet? _setFor(
  PlanPhase phase,
  TrainingPaces paces,
  double budgetKm,
  double weeklyKm,
  int weekInPhase, {
  int? ladderFrom,
}) {
  final requested = ladderFrom ??
      switch (phase) {
        PlanPhase.peak => 0,
        PlanPhase.specific => 1 + (weekInPhase ~/ 2).clampI(0, 2),
        _ => 1,
      };
  // The 400m rung is gated on volume **wherever it is reached from**, not only
  // in peak. Applying it per-caller let the base block's ladder walk straight
  // past the gate and hand a 27 km week ten 400m reps.
  final from = weeklyKm >= minVolumeForSharpReps ? requested : requested.clampI(1, 99);
  return solveFormatSet(budgetKm, paces, from: from);
}

String _setTitle(SolvedSet set, bool isPeak) {
  final distance = set.format.distanceM;
  if (distance == null) {
    return isPeak ? 'Sharpening intervals' : 'Aerobic intervals';
  }
  return isPeak
      ? 'Sharpening: ${_formatDistance(distance)} reps'
      : '${_formatDistance(distance)} reps';
}

String _setDescription(SolvedSet set, TrainingPaces paces) {
  final pace = paces.forZone(set.format.zone).format();
  final recovery = _formatRecovery(set.format.recovery);
  final set_ = set.format.distanceM == null
      ? '${set.reps} x ${_formatWork(set.format.work ?? intervalRep)}'
      : '${set.reps} x ${_formatDistance(set.format.distanceM!)}';
  return '$repWarmUpMinutes min warm-up, then $set_ at $pace/km with '
      '$recovery recovery — about ${set.hardKm.toStringAsFixed(1)} km of hard '
      'running in total — then $repCoolDownMinutes min cool down. The recovery is '
      'as important as the reps: if you are running them all out, do fewer of '
      'them.';
}

String _formatDistance(int m) => m >= 1000 ? '${m ~/ 1000} km' : '$m m';

String _formatWork(Duration d) =>
    d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';

String _formatRecovery(Duration d) {
  final s = d.inSeconds;
  return s % 60 == 0 ? '${s ~/ 60} min' : '$s s';
}

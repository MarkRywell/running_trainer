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
List<PlanPhase> allocatePhases(int totalWeeks, {required RaceDistance goal}) {
  // Very short blocks still need a taper and a race week, but not a big one.
  // Without this the fixed minimums below would overflow the requested length.
  if (totalWeeks < 6) {
    return [
      ...List.filled((totalWeeks - 2).clampI(1, 99), PlanPhase.base),
      PlanPhase.taper,
      PlanPhase.raceWeek,
    ];
  }

  // Taper length follows the **race distance**, not the block length.
  //
  // It used to be `totalWeeks >= 12 ? 3 : 2`, which asked the same question of a
  // 10K and a marathon. They are not the same question. A 10K needs one week:
  // there is no glycogen to deplete at that distance, so there is nothing a
  // second taper week buys, and a runner on a 9-week block cannot spare it. A
  // marathon is a different sport — 42 km of fuelling and 3 hours of glycogen
  // debt are what a taper exists to clear — so it gets two, or three when the
  // block is long enough to have earned them.
  final taperWeeks = taperWeeksFor(totalWeeks: totalWeeks, goal: goal);
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

/// How many taper weeks a block of [totalWeeks] gets for [goal].
///
/// Short races taper for one week, long races for two, and a long block for a
/// long race for three. See [allocatePhases] for why this keys on distance
/// rather than on block length.
int taperWeeksFor({required int totalWeeks, required RaceDistance goal}) {
  if (goal.isShort) return 1;
  if (goal == RaceDistance.marathon && totalWeeks >= longBlockWeeks) return 3;
  return 2;
}

/// Block length at which a marathon earns a third taper week.
///
/// A third taper week only pays for itself if there is enough build to have
/// accumulated the fatigue it exists to clear. Fourteen weeks is a medium block,
/// not a long one, and handing it the marathon taper cost two weeks of build: a
/// 14-week half marathon block came out as base 4 / specific 4 / **peak 2** /
/// taper 3, and one of those two peak weeks was a deload — so the phase whose
/// whole job is sharpening had a single quality week in it.
const int longBlockWeeks = 18;

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

  final phases = allocatePhases(totalWeeks, goal: goal.distance);
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

  for (var i = 0; i < phases.length; i++) {
    final phase = phases[i];
    final weekStart = monday.add(Duration(days: 7 * i));
    final isRaceWeek = phase == PlanPhase.raceWeek;
    final isCutback =
        !isRaceWeek && isCutbackWeek(phases, i, cutbackEveryTrained);

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
    // A short race tapers without a long run at all.
    //
    // At 5K and 10K there is no glycogen debt and no race-specific durability to
    // build, so the long run's only remaining job in the taper week is to be the
    // biggest thing in it — which is the opposite of the point. The week's volume
    // goes into short easy runs and one sharp race-pace session instead.
    final dropLongRun = phase == PlanPhase.taper && goal.distance.isShort;

    final share = longRunShare(pattern.length);
    final floor = 6.0.clampD(0.0, volumes[i] * share);
    var longKm = volumes[i] * share;
    if (isCutback) longKm *= 0.9;
    longKm = longKm.clampD(floor, capKm);
    longKm = capLongRunGrowth(previousLongKm, longKm, beginner: false)
        .clampD(floor, capKm);
    if (dropLongRun) longKm = 0;

    // The final taper week carries the race-pace set. A taper's *earlier* weeks
    // carry a quality session too, but only for the long races that have a week
    // of them — see [taperWeeksFor]. A one-week taper is that week.
    final isFinalTaperWeek = phase == PlanPhase.taper &&
        i + 1 == phases.length - 1 &&
        phases[i + 1] == PlanPhase.raceWeek;
    // **A cutback is 100% easy, in every phase.** That is what a deload is for:
    // absorbing the weeks before it and recovering. There was a period here
    // where specific and peak were exempted so a short phase could not lose its
    // only set week to a cutback — but that made cutbacks do two contradictory
    // things at once, and "keep the hard work" is not a deload under any reading
    // of the word.
    //
    // The risk it was papering over is real and is now visible instead: on a
    // short block, `allocatePhases` splits by percentage and `isCutbackWeek` then
    // lands wherever it lands, so a two-week specific phase can hand its only rep
    // week to a cutback. The honest fix for that is to place the cutback, not to
    // quietly exempt a phase from deloading.

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
      // A non-final taper week of a long race keeps its hard work, one session
      // at four days and two at five. Without this a 2-week taper was half its
      // length at zero intensity, which reads as a deload wearing a taper's name.
      taperMidWeekQuality: phase == PlanPhase.taper &&
          !isFinalTaperWeek &&
          !goal.distance.isShort,
      hasLongRun: !dropLongRun,
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
    // Read from the **built weeks**, not from the raw curve.
    //
    // `enforceSafety` trims a week to what its sessions actually prescribe, and
    // on a large block that trimming is what decides the real maximum — a 70
    // km/week runner curves toward 94.5 and is held at 75.0 by the long-run cap
    // and 80/20 long before the ceiling is in play. Judging the disclosure on
    // the curve would then tell that runner they had maxed out when they had
    // not, which is the "budget says one thing, the plan does another" fault
    // this codebase has hit three times.
    ...volumeCeilingFlags(
      volumes: weeks.map((w) => w.targetVolumeKm).toList(),
      ceiling: ceiling,
      currentWeeklyKm: currentWeeklyKm,
    ),
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
  final goalPace = Pace.fromDuration(goal.finishTimeGoal, goal.distance.metres);
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
        zone: IntensityZone.marathon,
        distanceKm: raceKm,
        targetDuration: goal.finishTimeGoal,
        isQuality: true,
        weekday: raceDay,
        // The card used to show the marathon-pace number for a race the runner
        // is entering at their goal pace — 40 s/km out for a 10K goal, on the one
        // session where the number actually matters. Same fault as the taper
        // set: a pace inferred from a zone rather than stated.
        prescribedPace: goalPace,
        type: WorkoutType.race,
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
/// **Every returned index is inside the week.** The first version of this walked
/// a fixed candidate list and did not check it against `runDays`, so
/// `qualitySlots(2, 1)` returned `[3]` for a week whose only positions are 0 and
/// 1. The caller built the session, subtracted its distance from the easy budget
/// and then had no loop iteration that could place it — the same silent
/// budget-then-drop fault as the four-day case, at the other end of the range.
///
/// Returns **fewer** than [count] when the week has no room, which the caller
/// treats as authoritative: a three-day week holds exactly one quality session,
/// and a two-day week would hold none rather than pretend.
///
/// Order is deliberate. Quality goes early in the week with a rest day behind it,
/// and the day straight after the long run is reserved for recovery.
List<int> qualitySlots(int runDays, int count) {
  if (runDays < 3 || count <= 0) return const [];
  final taken = <int>{0, runDays - 1};
  return [
    for (final candidate in [1, 3, 2, 4, 5, 6])
      if (candidate < runDays && !taken.contains(candidate))
        candidate,
  ].take(count).toList();
}

/// Whether the long run is followed immediately by another run.
///
/// This is what decides whether the first run of the week is a recovery day, and
/// it is a question about the **pattern**, not about how many days there are.
///
/// At three days a week the long run is Saturday (`[1,3,6]`) and Sunday is
/// already free, so Monday is the second day after it — a recovery prescription
/// there absorbs nothing, and the card even said so: *"Absorb the long run, do
/// not add to it"*, on the Monday **before** it. At four days and up the long run
/// is Sunday (`[1,3,5,7]`, `[1,2,4,6,7]`, `[1,2,3,4,6,7]`) and Monday is the very
/// next day, so there the recovery day is earned.
///
/// Keyed on the pattern so a future change to [weeklyDayPattern] moves it.
bool longRunFollowsImmediately(List<int> pattern) {
  if (pattern.isEmpty) return false;
  final longDay = pattern.last;
  final next = longDay == 7 ? 1 : longDay + 1;
  return pattern.contains(next);
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
  bool taperMidWeekQuality = false,
  bool hasLongRun = true,
}) {
  // `suppressQuality` turns hard sessions into easy ones rather than dropping
  // days, so the week keeps its mileage and its shape. The beginner base block
  // is a proven zero-quality plan, so the resulting shape is known to be valid.
  //
  // The taper is deliberately exempt. Its quality session is the whole point of
  // the phase, and at three days a week `suppressQuality` would otherwise erase
  // the one hard session the runner is tapering toward.
  final taperQuality = isFinalTaperWeek && goal != null;
  final taperMid = taperMidWeekQuality && goal != null;
  final days = pattern.length;
  final unsuppressed = qualitySessionsFor(phase, days);
  // `drop-quality` has two shapes, and which one applies is structural rather
  // than a matter of taste.
  //
  // With **two** quality sessions in the week, removing them is proportionate:
  // the runner still has a week of running, it is simply an easy one, and that is
  // a legitimate response to two sessions coming back harder than planned.
  //
  // With **one** — three and four days a week — removal is all-or-nothing on a
  // single session, and the runner has no middle option between "my hard session"
  // and "no hard running at all". So the session is kept and shortened instead.
  // The proposal's own copy says "you lose the part that is not working", and on
  // a one-session week that would be the whole of it.
  final singleQualityWeek = unsuppressed <= 1;
  final shortenOnly = suppressQuality && !isCutback && singleQualityWeek &&
      !taperQuality && !taperMid;

  // What the week would *like*, before it knows where those sessions can go.
  final wanted = isCutback
      ? 0
      : taperQuality || taperMid || !suppressQuality || shortenOnly
          ? taperQuality
              ? 1
              : taperMid
                  ? (days >= 5 ? 2 : 1)
                  : unsuppressed
          : 0;

  // What it can *actually place*. The slot list is authoritative, so a week can
  // never budget a hard session it has no day for — the fault that produced a
  // two-day week with a session subtracted from its easy budget and never
  // written down.
  final slots = qualitySlots(days, wanted);
  final qualityCount = slots.length;
  final workouts = <Workout>[];

  // Assign roles to days. The day after the long run is recovery, quality
  // goes early in the week with a rest day behind it, and the last day of
  // the pattern is the long run.
  final longIndex = days - 1;

  // Quality sessions are prescribed by their own sensible length rather than
  // inheriting an easy-day share. A tempo is not a long run: making it as long
  // as the easy days is what pushed the week past 80% easy. The 22% is the
  // *week's* quality budget, shared between the sessions it carries.
  //
  // `drop-quality` on a one-session week scales that budget down rather than
  // deleting the session. One knob, and both shapes respond correctly: a tempo
  // simply gets shorter, and a set gets fewer reps, because `solveSet` solves to
  // whatever room it is given. The freed distance returns to the easy days, so
  // the week still sums to its target.
  final qualityBudget =
      qualityKmPerSession(targetVolume, qualityCount) *
          (shortenOnly ? suppressedQualityScale : 1.0);
  final qualityKm = hasLongRun
      ? capQualityAgainstLong(qualityBudget, longKm)
      : qualityBudget;

  // The sessions are built *before* the easy days are budgeted, because a
  // solved rep set is not `qualityKm` — it is the largest set that fits inside
  // it, so it lands at or under. Budgeting the easy days from the intent rather
  // than from the built sessions is how a week ends up reporting a target its
  // own workouts do not add up to.
  final quality = <Workout>[
    for (var k = 0; k < slots.length; k++)
      if (taperQuality)
        _taperSharpening(goal, paces, longKm, targetVolume)
      else if (taperMid)
        // A mid-taper week keeps its hard work, but it is *threshold* work
        // seven days out — not a second race-pace set. The race-pace session
        // belongs to the final week only; running it twice spends the one
        // session the runner should be arriving fresh for.
        _tempo(paces, qualityKm)
      else
        _qualitySessionsFor(phase, paces, weekInPhase, qualityKm, targetVolume,
            qualityCount)[k],
  ];

  final qualityTotalKm = quality.fold<double>(0, (sum, w) => sum + w.distanceKm);
  // A week with no long run has one *more* easy day, not one fewer: the long
  // run was the day that is not easy, so removing it returns a day to the pool.
  final easyDays = (days - (hasLongRun ? 1 : 0) - qualityCount).clampI(1, 99);
  // Every quality session has to come out of the easy budget, not just the
  // first. Subtracting one while prescribing two handed the runner an extra
  // 9–15 km in every peak week — a week of up to 82 km built to a 74 km target.
  var easyKm = _easyShare(
    targetVolume - qualityTotalKm,
    longKm,
    easyDays,
    floorKm: phase == PlanPhase.taper ? taperEasyRunFloorKm : 3.0,
    // With no long run to stay under, an easy day has no ceiling of its own. The
    // short runs are the reason this week has no long run.
    capKm: hasLongRun ? easyRunCapKm(longKm) : maxTaperEasyRunKm,
  );

  for (var i = 0; i < days; i++) {
    if (hasLongRun && i == longIndex) {
      workouts.add(_longRun(phase, longKm, paces, weekIndex));
      continue;
    }
    if (i == 0) {
      // Recovery only when the long run is *immediately* before this day.
      //
      // At three days a week the long run is Saturday and Sunday is already
      // free, so this Monday is the second day after it — a recovery day there
      // absorbs nothing, and the card used to say exactly that on the wrong side
      // of the long run. It also cost a third of the week's runnable days spent
      // *below* easy, which is the one pace that does not build anything.
      //
      // The swap is zone-only: same distance, same cap, and both recovery and
      // easy are `isEasy`, so 80/20 and the long-run share do not move.
      workouts.add(longRunFollowsImmediately(pattern)
          ? Workout(
              title: 'Recovery run',
              type: WorkoutType.recovery,
              zone: IntensityZone.recovery,
              distanceKm: easyKm,
              targetDuration: paces.recovery.overDistance(easyKm * 1000),
              description: 'Deliberately slow. Absorb the long run, do not add '
                  'to it.',
            )
          : _easy(easyKm, paces));
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

/// The pace a taper's race-pace reps are run at.
///
/// The goal's own finish time, floored at the fastest pace the app will prescribe
/// anywhere.
///
/// The description said "your goal pace" while reading `paces.marathon`, which is
/// the **fitness** anchor from a marathon equivalent. For a marathon goal the two
/// nearly coincide, so it was invisible. For a 10K they are 40 s/km apart: a
/// runner with a 51:00 goal was told to run their final sharpening reps at
/// 5:46/km and call it their goal pace.
///
/// The floor is the *repetition* pace, not the marathon one, and that is a
/// deliberate reversal of the usual rule. Every other zone in this app is
/// anchored on fitness rather than the goal, because a stretch goal shifted the
/// whole ladder and produced threshold 12 s/km faster than the athlete could hold
/// (`zone_anchor_regression_test.dart`). This session is different: rehearsing
/// the race pace *is* the prescription, it happens once, 4–5 days out, and the
/// goal has already been checked for plausibility by `validate` — which is where
/// an unreachable goal belongs. The floor still exists, and it is the sharpest
/// pace the app is willing to hand out at all, so a fantasy goal cannot produce
/// a session faster than anything the athlete has been asked to run.
Pace taperRepPace(TrainingPaces paces, GoalRace goal) {
  final goalPace = Pace.fromDuration(goal.finishTimeGoal, goal.distance.metres);
  return goalPace.secPerKm < paces.repetition.secPerKm
      ? paces.repetition
      : goalPace;
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
      maxReps: 6),
  RepFormat(
      distanceM: 1000,
      recovery: Duration(seconds: 90),
      zone: IntensityZone.interval,
      maxReps: 5),
  // Long reps are threshold work, not interval work. Running 2km at interval
  // pace is a different and much more damaging session than the name implies,
  // which is why the zone travels with the distance. [repZoneForPhase] overrides
  // it anyway for the phases that prescribe threshold.
  RepFormat(
      distanceM: 2000,
      recovery: Duration(seconds: 90),
      zone: IntensityZone.threshold,
      maxReps: 3),
];

/// The zone a phase's reps are run at.
///
/// **Race-specific work is threshold work, and only peak is allowed to be fast.**
/// The zone used to be baked into the rep format, which meant a 10K athlete's
/// race-specific phase prescribed 800m at interval pace — *faster* than both
/// their threshold and their goal pace. That is 5K-effort work sitting in the
/// phase that is supposed to be preparing them for a 10K, and it left peak as the
/// only place with anything sharper.
///
/// Peak is the exception because sharpening is the point of peaking. A stretch
/// goal still cannot reach interval pace here: paces are anchored on fitness
/// (see `zoneAnchorPace`), so interval is always something the athlete has
/// demonstrated.
IntensityZone repZoneForPhase(PlanPhase phase) => switch (phase) {
      PlanPhase.peak => IntensityZone.interval,
      _ => IntensityZone.threshold,
    };

/// The same format with the zone a phase actually prescribes.
RepFormat _formatForPhase(RepFormat format, PlanPhase phase) => RepFormat(
      distanceM: format.distanceM,
      work: format.work,
      recovery: format.recovery,
      zone: repZoneForPhase(phase),
      minReps: format.minReps,
      maxReps: format.maxReps,
    );

/// The rep format the ladder prescribes for a given rep distance, or null.
RepFormat? repFormatFor(int distanceM) {
  for (final f in _repLadder) {
    if (f.distanceM == distanceM) return f;
  }
  return null;
}

/// Solve the first format in [_repLadder] that fits [budgetKm].
///
/// The 400m set is the sharpest thing this app can prescribe, so it is only
/// reached when the week is genuinely big — see [minVolumeForSharpReps].
///
/// Rep counts are bounded by [RepFormat.maxReps] and the volume budget can only
/// ever *shorten* a set. It used to work the other way: reps were added until the
/// budget filled, so a big week produced a 9 x 800m set because 22% of 54 km
/// happened to be 12 km. A rep count is a training decision — how many reps you
/// should run — and filling a volume space is not one.
SolvedSet? solveFormatSet(
  double budgetKm,
  TrainingPaces paces, {
  int from = 0,
  PlanPhase phase = PlanPhase.specific,
}) {
  for (var i = from; i < _repLadder.length; i++) {
    final solved = solveSet(_formatForPhase(_repLadder[i], phase), budgetKm, paces);
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

double _easyShare(
  double total,
  double longKm,
  int easyDays, {
  double floorKm = 3.0,
  double? capKm,
}) {
  if (easyDays <= 0) return 0;
  final remaining = total - longKm;
  if (remaining <= 0) return 5;
  final share = remaining / easyDays;
  return share.clampD(floorKm, capKm ?? easyRunCapKm(longKm));
}

/// Longest an easy day may be in a taper week that has no long run.
///
/// Normally an easy day is capped by the long run it has to stay under, so with
/// no long run there is nothing to stop the volume collapsing onto one 12 km
/// "recovery" run — which would be the longest run of the week by accident,
/// undoing the reason the long run was removed. This is a flat ceiling, and it
/// is short on purpose.
const double maxTaperEasyRunKm = 8.0;

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
    // The goal-pace block is hard running and has to be counted as such.
    //
    // It reported zero, so `hardVolumeKm` — and therefore the 80/20 invariant
    // the whole plan is built to satisfy — was being computed on a plan that hid
    // its own race-specific work. A 15.6 km specific long run with 5 km at
    // marathon pace is 32% hard, and the app was calling it 0%.
    hardFractionOfDistance: longRunHardFraction(phase, km),
    description: description,
  );
}

/// Share of a long run run above easy pace, by phase.
///
/// The specific phase holds a third of it at marathon pace; peak holds a fixed
/// 5 km (3 at MP, 2 at goal pace) and will not hold that on a short run, so it is
/// capped rather than allowed to exceed the run. Base and taper are genuinely
/// all-easy and stay at zero.
double longRunHardFraction(PlanPhase phase, double km) {
  if (km <= 0) return 0;
  final hardKm = switch (phase) {
    PlanPhase.specific => km * 0.33,
    PlanPhase.peak => 5.0,
    PlanPhase.base ||
    PlanPhase.taper ||
    PlanPhase.raceWeek ||
    PlanPhase.baseBlock =>
      0.0,
  };
  return hardKm.clampD(0.0, km) / km;
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
/// **The warm-up and cool-down are named in distance, not minutes**, because the
/// session is budgeted in distance: the easy legs are whatever
/// `1 - tempoHardFraction` of [km] works out to. The copy used to say "10 min
/// warm-up ... 5 min cool down" while the arithmetic produced ~27 minutes of easy
/// running, so every tempo in the app was about 12 minutes longer than it
/// advertised. A runner reading the card could not tell they were being asked for
/// more than the card said, and "it feels like too much" is not a report anyone
/// files — it just becomes a reason to stop running the session.
Workout _tempo(TrainingPaces paces, double km) {
  final hardKm = km * tempoHardFraction;
  final easyKm = km - hardKm;
  final hardMin = paces.threshold.overDistance(hardKm * 1000).inMinutes;
  final warmUpKm = easyKm / 2;

  return Workout(
    title: 'Tempo',
    type: WorkoutType.tempo,
    zone: IntensityZone.threshold,
    distanceKm: km,
    targetDuration: paces.easy.overDistance(km * 1000),
    isQuality: true,
    hardFractionOfDistance: tempoHardFraction,
    description:
        'Easy for ${_formatDistance(warmUpKm)}, then $hardMin min steady at '
        '${paces.threshold.format()}/km — comfortably hard, controlled, roughly '
        '"I could go a little faster". Easy for ${_formatDistance(easyKm - warmUpKm)} '
        'to finish.',
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
///
/// [longKm] is the week's long run, or 0 in a short-race taper that has none.
Workout _taperSharpening(
  GoalRace goal,
  TrainingPaces paces,
  double longKm,
  double weekVolumeKm,
) {
  final format = _taperFormats[goal.distance]!;

  // Budgeted against the **long run** where there is one. A taper week is the
  // smallest of the block, so a 9 km quality session inside a 25 km week is a
  // race rehearsal rather than a taper session — and, more concretely, a set
  // that outlasts the long run breaks the invariant that the long run is the
  // longest run of its week. That is not a style preference: the runner reads
  // "long run: 6.8 km" above "goal-pace reps: 7.1 km" and the plan stops making
  // sense to them.
  //
  // With no long run there is nothing to size it against, and budgeting from a
  // long run of zero silently collapsed the session to a single rep — the taper's
  // one hard session reduced to a token, which is the opposite of the point. So
  // it is sized as a share of the week instead, with the same 8 km ceiling.
  final budget = longKm > 0
      ? capQualityAgainstLong(longKm.clampD(0.0, maxTaperSessionKm), longKm)
      : (weekVolumeKm * maxTaperSessionShare)
          .clampD(0.0, maxTaperSessionKm);
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
  final pace = taperRepPace(paces, goal);
  // Whether the floor actually bound. The copy has to say which of the two it is
  // prescribing, because a runner told "your goal pace" and then handed their
  // marathon pace has been told something false — and this is the last session
  // before the race, so it is the one place that matters most.
  final atGoalPace =
      pace.secPerKm <= (goal.finishTimeGoal.inSeconds /
              (goal.distance.metres / 1000))
          .round();
  final hardFraction = hardFractionForReps(
    reps: reps,
    repDistanceM: format.distanceM,
    repWork: format.work,
    recovery: format.recovery,
    repPaceSecondsPerKm: pace.secPerKm.toDouble(),
    easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
  );
  final distanceKm = setDistanceKm(format, reps, paces);
  final hardKm = distanceKm * hardFraction;
  final easyKm = distanceKm - hardKm;
  final warmUpKm = easyKm / 2;

  return Workout(
    title: 'Goal-pace ${_formatRepDistance(format.distanceM!)} reps',
    type: WorkoutType.intervals,
    // The zone describes the *effort*, so it is the nearest rung to the pace
    // actually being run rather than the one the format was authored with. For a
    // 10K goal at 5:06/km that is threshold, not marathon — labelling the hardest
    // session of the taper as `marathon` painted it as the easiest thing in the
    // week, on a card that also says 5:06 in its own description.
    zone: paces.nearestZone(pace),
    prescribedPace: pace,
    distanceKm: distanceKm,
    targetDuration: paces.easy.overDistance(distanceKm * 1000),
    isQuality: true,
    hardFractionOfDistance: hardFraction,
    reps: reps,
    repDistanceM: format.distanceM,
    repRecovery: format.recovery,
    // Same reasoning as `zone`: the reps are run at the prescribed pace, so the
    // rung that classifies them is the nearest one, not the rung the format
    // happens to be authored with.
    repZone: paces.nearestZone(pace),
    description: [
      'The last hard running you do before ${goal.distance.label}.',
      'Easy for ${_formatDistance(warmUpKm)}, then $reps x '
          '${_formatRepDistance(format.distanceM!)} at ${pace.format()}/km'
          '${atGoalPace ? ' — your goal pace' : ' — your current marathon pace, '
              'which is the most this pace can be without asking for something '
              'you have not run'}'
          ', with ${_formatRecovery(format.recovery)} easy jog.',
      'Hold it, do not sprint it. Easy for ${_formatDistance(easyKm - warmUpKm)} '
          'to finish, and nothing hard again until race day.',
    ].join(' '),
  );
}

/// Longest the taper's quality session may be, in km.
const double maxTaperSessionKm = 8.0;

/// The taper's quality session, as a share of the week, in a week with no long
/// run to size it against.
const double maxTaperSessionShare = 0.35;

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
  return solveFormatSet(budgetKm, paces, from: from, phase: phase);
}

String _setTitle(SolvedSet set, bool isPeak) {
  final distance = set.format.distanceM;
  if (distance == null) {
    return isPeak ? 'Sharpening intervals' : 'Aerobic intervals';
  }
  return isPeak
      ? 'Sharpening: ${_formatRepDistance(distance)} reps'
      : '${_formatRepDistance(distance)} reps';
}

String _setDescription(SolvedSet set, TrainingPaces paces) {
  final pace = paces.forZone(set.format.zone).format();
  final recovery = _formatRecovery(set.format.recovery);
  final set_ = set.format.distanceM == null
      ? '${set.reps} x ${_formatWork(set.format.work ?? intervalRep)}'
      : '${set.reps} x ${_formatRepDistance(set.format.distanceM!)}';
  // Named in distance, not minutes, for the same reason the tempo is: the easy
  // legs are whatever the solved set left over, and describing them in time
  // overstated them by about seven minutes a session. A runner told "10 min
  // warm-up" and then handed 22 minutes of easy has no way to know they are being
  // asked for more than the card says.
  final easyKm = set.distanceKm - set.hardKm;
  final warmUpKm = easyKm / 2;
  return 'Easy for ${_formatDistance(warmUpKm)}, then $set_ at $pace/km with '
      '$recovery recovery — about ${set.hardKm.toStringAsFixed(1)} km of hard '
      'running in total — then easy for '
      '${_formatDistance(easyKm - warmUpKm)} to finish. The recovery is as '
      'important as the reps: if you are running them all out, do fewer of them.';
}

/// Formats a rep distance given in **metres**.
String _formatRepDistance(int m) => m >= 1000 ? '${m ~/ 1000} km' : '$m m';

/// Formats a running distance given in **kilometres**, to a tenth below 10.
///
/// The tenth matters for warm-ups: "easy for 1.6 km" is a runnable instruction
/// and "easy for 1.63 km" is not, but "easy for 0.2 km" is too coarse to be
/// either.
String _formatDistance(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}

String _formatWork(Duration d) =>
    d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';

String _formatRecovery(Duration d) {
  final s = d.inSeconds;
  return s % 60 == 0 ? '${s ~/ 60} min' : '$s s';
}

/// Volume progression, cutbacks, taper, and the day-constraint drop order.
///
/// Everything in this file exists to serve one product requirement: the plan
/// must never be too hard to follow. The numbers here are the levers, and the
/// functions that use them are constrained so that a caller cannot ask for
/// something unsafe and get it.
library;

import '../models/plan.dart';
import '../models/race.dart';
import '../units.dart';



/// The share of weekly volume the long run should take.
///
/// 30% works from four run days up. Below that it is **arithmetically
/// impossible** for the long run to be the longest session: on a three-day week
/// the remaining 70% splits across two days at 35% each, so a 30% "long run"
/// comes out shorter than an easy run. A real report hit exactly this — two
/// years' running, three days a week, and a plan whose long run was 3 km while
/// its easy runs were 4.9 km. The long run has to be the longest run of the
/// week; that is the entire meaning of the word.
///
/// So the share rises as days fall, until the long run genuinely dominates its
/// own week.
double longRunShare(int runDays) => switch (runDays) {
      <= 2 => 0.60,
      3 => 0.45,
      _ => 0.30,
    };

/// Share of a tempo session's distance spent at threshold.
///
/// 10 min warm-up, 25 min at threshold, 5 min cool down — the hard part is
/// under two-thirds of it even though it is the part that feels like the run.
const double tempoHardFraction = 0.60;

/// Share of an interval session's distance spent at interval pace. The
/// recoveries and the warm-up are easy jogging.
const double intervalHardFraction = 0.32;

/// A quality session's length, in km. Defined **once**, shared by both
/// generators — they had drifted into carrying separate copies of a flat 9 km
/// floor, which is the same bug twice.
///
/// The floor scales with the week rather than being absolute. A flat 9 km was
/// 57% of a 15 km week, which made the tempo the single biggest thing in the
/// plan and left it *longer than the long run* on a three-day week. A tempo is
/// meant to be the hardest session of the week, not the longest.
double qualityDistanceKm(double targetVolume) {
  final base = targetVolume * 0.22;
  return base.clampD(base.clampD(5.0, 9.0), 15.0);
}

/// Longest a quality session may be relative to the long run.
///
/// A quality session is a workout, not a long run. Where the arithmetic would
/// let it overtake the long run, the long run still wins — the runner reads
/// these numbers before they read our reasoning, and "long run: 7 km" next to
/// "tempo: 9 km" is the kind of thing that stops somebody trusting the plan.
double capQualityAgainstLong(double qualityKm, double longKm) =>
    qualityKm.clampD(0.0, longKm * 0.9);

/// Longest an easy or recovery day may be.
///
/// Never longer than the long run. Two things break without this. On a
/// three-day week the leftover volume lands on the single easy day, and when
/// the long run has hit its own distance cap — 14 km for a 5K goal — that
/// leftover is large enough to produce an 18 km **recovery run**, which is not a
/// recovery run and is longer than the long run it is supposed to follow.
double easyRunCapKm(double longKm) => longKm.clampD(3.0, 18.0);

/// Longest a single long run may be, as a fraction of the week's total volume.
const double maxLongRunFraction = 0.32;

/// The hard ceiling on a long run's share, for a given number of run days.
///
/// This must always sit **above** [longRunShare] for the same day count. When it
/// did not, enforcement silently undid the generator: a three-day week targeted
/// 45% and was trimmed straight back to 32% by [enforceSafety], which is how
/// the long run ended up shorter than the easy runs in the first place.
double maxLongRunFractionFor(int runDays) => switch (runDays) {
      <= 2 => 0.65,
      3 => 0.50,
      _ => maxLongRunFraction,
    };

/// Absolute ceiling on a single long run.
const double maxLongRunKm = 35;
const Duration maxLongRunDuration = Duration(hours: 3, minutes: 30);

/// Target share of weekly volume at or below easy pace.
const double easyVolumeTarget = 0.80;

/// Weekly growth for trained runners.
const double trainedGrowthRate = 0.05;

/// Weekly growth for beginners. Deliberately slower: the base they are
/// building is aerobic, and tendons and bone adapt far more slowly than
/// aerobic fitness does.
const double beginnerGrowthRate = 0.06;

/// A cutback week is this fraction of the week before it.
const double cutbackFactor = 0.75;

/// Cutback cadence, in weeks.
const int cutbackEveryTrained = 4;
const int cutbackEveryBeginner = 4;

/// Longest a beginner long run grows, per week, in km.
const double beginnerLongRunGrowth = 2.0;

/// A beginner plan never drops below this many runs per week — going lower
/// breaks the habit the plan exists to build.
const int beginnerMinimumRuns = 3;

/// The closest a race can be and still be worth generating a full plan for.
const int minimumWeeksForFullPlan = 6;

/// Long-run ceiling by goal distance. Preparing for a 10K and grinding out
/// 32 km long runs serves nothing.
double longRunCapKm(RaceDistance goal) => switch (goal) {
      RaceDistance.marathon => 32,
      RaceDistance.half => 24,
      RaceDistance.k10 => 18,
      RaceDistance.k5 => 14,
    };

/// A sensible ceiling on weekly volume for a given athlete, in km.
///
/// Used to stop the progression running away on a big-volume plan.
double weeklyVolumeCeiling({
  required bool beginner,
  required RaceDistance? goal,
  double? currentWeeklyKm,
}) {
  if (beginner) return 55; // capping around 5 days is plenty
  if (currentWeeklyKm != null && currentWeeklyKm > 0) {
    // Never more than ~35% above what they are already doing.
    final cap = currentWeeklyKm * 1.35;
    return cap < 120 ? cap : 120;
  }
  return switch (goal) {
    RaceDistance.marathon => 80,
    RaceDistance.half => 65,
    RaceDistance.k10 => 55,
    RaceDistance.k5 => 45,
    null => 60,
  };
}

/// The single definition of a cutback week, shared by the volume curve and
/// both generators.
///
/// These three call sites drifted apart once — the curve cut at `i % 4 == 3`
/// while the generators cut the long run at `i % 4 == 0` — which produced long
/// runs that jumped 4 km the week after a cutback. One definition, one
/// behaviour.
bool isCutbackWeek(int weekIndex, int cutbackEvery, int buildWeeks) =>
    cutbackEvery > 0 &&
    weekIndex > 0 &&
    weekIndex % cutbackEvery == 0 &&
    weekIndex < buildWeeks - 1;

/// Number of leading build weeks before the taper begins.
int buildWeekCount(List<PlanPhase> phases) {
  for (var i = 0; i < phases.length; i++) {
    if (phases[i] == PlanPhase.taper || phases[i] == PlanPhase.raceWeek) {
      return i;
    }
  }
  return phases.length;
}

/// A week must be at least this complete before the next one is allowed to
/// build on it.
///
/// Applies to weeks that have actually been logged. A week with no record is
/// treated as unknown rather than failed — otherwise a plan generated for
/// someone who has not started logging would never grow at all, which would
/// be a much worse answer than the ambitious default.
const double minimumAdherenceToProgress = 0.9;

/// Builds a weekly volume curve across [phases].
///
/// [adherenceByWeek] is the runner's recorded adherence per week index, with
/// `null` meaning "not recorded". Where the previous week is known and fell
/// short, this week's volume is **held flat** rather than increased: the plan
/// maintains instead of building on a gap.
///
/// The hold is deliberately *local* — each week depends only on its immediate
/// predecessor, not on a running total. Missing one week and then doing the
/// next lets the curve resume from there, rather than flattening the entire
/// remaining block because of a single bad week.
List<double> buildVolumeCurve({
  required List<PlanPhase> phases,
  required double startKm,
  required double maxWeeklyKm,
  required double growthRate,
  required double cutbackFactor,
  required int cutbackEvery,
  List<double?>? adherenceByWeek,
  int? holdFromWeekIndex,
  double taperDrop = 0.70,
}) {
  final n = phases.length;
  final volumes = List<double>.filled(n, 0);
  if (n == 0) return volumes;

  // Find the build block (everything before the taper begins).
  var taperStart = n;
  for (var i = 0; i < n; i++) {
    if (phases[i] == PlanPhase.taper || phases[i] == PlanPhase.raceWeek) {
      taperStart = i;
      break;
    }
  }

  var running = startKm;
  var peak = startKm;

  // Set when a cutback week is entered, holding the volume to return to. A
  // cutback is a dip, not a downgrade: without this, every cutback shaves
  // 25% off the plan permanently and a 12-week block ends up *smaller* than
  // it started.
  double? resumeAt;

  for (var i = 0; i < taperStart; i++) {
    final isCutback = isCutbackWeek(i, cutbackEvery, taperStart);

    if (isCutback) {
      resumeAt = running;
      volumes[i] = running * cutbackFactor;
    } else {
      if (resumeAt case final resume?) {
        running = resume;
        resumeAt = null;
      }
      // Hold flat unless the previous week justifies building on it. A week
      // with no record is unknown, not failed — see
      // [minimumAdherenceToProgress]. An explicit cap from an accepted coach
      // proposal overrides that entirely.
      final double? previous = (i > 0 &&
              adherenceByWeek != null &&
              i - 1 < adherenceByWeek.length)
          ? adherenceByWeek[i - 1]
          : null;
      final capped = holdFromWeekIndex != null && i >= holdFromWeekIndex;
      if (!capped &&
          (previous == null || previous >= minimumAdherenceToProgress)) {
        running *= (1 + growthRate);
        if (running > maxWeeklyKm) running = maxWeeklyKm;
      }
      volumes[i] = running;
    }
    if (running > peak) peak = running;
  }

  // Race week before the taper (possible for a very long block) tracks the
  // build curve so it is never below what came before.
  for (var i = taperStart; i < n; i++) {
    if (phases[i] == PlanPhase.raceWeek) {
      volumes[i] = running > 0 ? running * 0.5 : peak * 0.5;
    }
  }

  // Taper: strictly descending, never dipping below zero.
  final taperWeeks = <int>[];
  for (var i = taperStart; i < n; i++) {
    if (phases[i] == PlanPhase.taper) taperWeeks.add(i);
  }
  var t = peak;
  for (var k = 0; k < taperWeeks.length; k++) {
    t *= taperDrop;
    volumes[taperWeeks[k]] = t;
  }

  // A race week is the lightest week of the block apart from the taper tail.
  for (var i = taperStart; i < n; i++) {
    if (phases[i] == PlanPhase.raceWeek) {
      volumes[i] = volumes[i] < peak * 0.4 ? volumes[i] : peak * 0.4;
    }
  }

  return volumes;
}

/// Which workout types are considered quality work.
bool isQualityType(WorkoutType t) =>
    t == WorkoutType.tempo || t == WorkoutType.intervals || t == WorkoutType.race;

/// Keep-priority when a week has to be trimmed to fit [daysPerWeek].
///
/// The long run and quality sessions are never dropped. That is the whole
/// point of the drop order: when someone says they can only run four days,
/// the four days must be the four that matter, not four undifferentiated
/// easy runs.
int _keepPriority(WorkoutType t) => switch (t) {
      WorkoutType.race => 100,
      WorkoutType.long => 90,
      WorkoutType.tempo => 80,
      WorkoutType.intervals => 75,
      WorkoutType.walkRun => 50,
      WorkoutType.strides => 40,
      WorkoutType.easy => 30,
      WorkoutType.recovery => 20,
      WorkoutType.rest => 10,
    };

/// Trims a week's workouts down to [daysPerWeek] run days.
///
/// Drops the lowest-priority sessions first. Never drops the long run, a
/// quality session, or the race. Never drops below [minimumRuns] runs even
/// if that overshoots the requested day count — asking for two days when a
/// plan needs three is a case for warning the user, not for handing them an
/// unbuildable plan.
List<Workout> applyDayConstraint(
  List<Workout> workouts,
  int daysPerWeek, {
  int minimumRuns = 2,
}) {
  final runs = workouts.where((w) => w.type != WorkoutType.rest).toList();
  if (runs.length <= daysPerWeek) return workouts;

  // The floor wins over the request. If a runner says they can only do two
  // days and the plan needs three, the plan still ships three and the
  // validation layer warns them — handing back an unbuildable two-day plan
  // would be worse.
  final floor = minimumRuns;
  final keep = [...runs];

  // Sort by priority ascending, breaking ties toward the shorter session so
  // the least mileage goes first.
  keep.sort((a, b) {
    final byPriority = _keepPriority(a.type).compareTo(_keepPriority(b.type));
    if (byPriority != 0) return byPriority;
    return a.distanceKm.compareTo(b.distanceKm);
  });

  while (keep.length > daysPerWeek && keep.length > floor) {
    keep.removeAt(0);
  }

  final restDays = workouts.where((w) => w.type == WorkoutType.rest).length;
  final kept = [...keep]..sort((a, b) {
        // Preserve the original weekly ordering.
        return workouts.indexOf(a).compareTo(workouts.indexOf(b));
      });

  return [
    ...kept,
    ...List.generate(restDays, (_) => _restWorkout()),
  ];
}

Workout _restWorkout() => const Workout(
      title: 'Rest',
      type: WorkoutType.rest,
      zone: IntensityZone.recovery,
      description: 'No running. Sleep, eat, let the training land.',
      // Re-added by [applyDayConstraint] without a day; a dropped session's
      // weekday is restored by the caller if it matters.
    );

/// Stamps each workout with the weekday it is prescribed for.
///
/// [runs] must be the generator's output: run-day sessions in [pattern] order,
/// followed by rest days. Stamps only — it never adds or removes a session, so
/// it cannot change a week's mileage or its day count.
///
/// Rest days are stamped from the days the pattern omits, so a runner who logs
/// a hard Sunday has it land on a day the plan actually placed something.
///
/// Done here rather than in each workout factory so a new session type cannot
/// forget to attach its own day. That failure would be silent, surfacing only as
/// a session log that never matches a session.
List<Workout> attachWeekdays(List<Workout> runs, List<int> pattern) {
  final restDays = [
    for (var d = 1; d <= 7; d++)
      if (!pattern.contains(d)) d,
  ];
  var run = 0;
  var rest = 0;
  return [
    for (final w in runs)
      if (w.type == WorkoutType.rest)
        if (rest < restDays.length) _withWeekday(w, restDays[rest++]) else w
      else if (run < pattern.length)
        _withWeekday(w, pattern[run++])
      else
        w,
  ];
}

Workout _withWeekday(Workout w, int weekday) => weekday == 0
    ? w
    : Workout(
        title: w.title,
        type: w.type,
        zone: w.zone,
        description: w.description,
        distanceKm: w.distanceKm,
        targetDuration: w.targetDuration,
        isQuality: w.isQuality,
        hardFractionOfDistance: w.hardFractionOfDistance,
        weekday: weekday,
      );

/// How many run days a week actually prescribes.
///
/// Counted from the week rather than taken as a parameter, because
/// [enforceSafety] is handed a finished week and has to judge it on its own
/// contents — a cap derived from the generator's intent rather than the week
/// that exists is how the two drifted apart in the first place.
int runDaysIn(PlanWeek week) =>
    week.workouts.where((w) => w.type != WorkoutType.rest).length;

/// Applies the safety invariants to a finished week.
///
/// Adjusts rather than rejects: the generators aim to produce conforming
/// weeks, and this is the backstop that guarantees it.
PlanWeek enforceSafety(PlanWeek week) {
  // Normalise the reported target first, and unconditionally. The generators
  // compute it from a workout list that is then trimmed — by
  // [applyDayConstraint], by the race-week shakeout, by the distance cap — so
  // a week could report a target its own sessions did not add up to. It is also
  // why this cannot early-return for a week with no long run: race weeks and
  // heavily-trimmed weeks are exactly the ones that were out by the most.
  final long = week.longRun;
  if (long == null) {
    return week.copyWith(targetVolumeKm: volumeOf(week.workouts));
  }

  // The cap is solved, not iterated, because the reported target is the sum of
  // the sessions *including* the long run — so "long run ≤ f · week" is a fixed
  // point, not a single comparison.
  //
  // With the rest of the week at R and the long run at L, the requirement is
  // L ≤ f(R + L), i.e. L ≤ f·R / (1 − f). Capping to f·(R + L) instead — the
  // obvious reading — sets L' = f·(R + L), which then *fails* the very cap it
  // was enforcing, because trimming the long run lowers the total it is measured
  // against. That is why the long run sat fractionally over its share in a
  // handful of weeks.
  final fraction = maxLongRunFractionFor(runDaysIn(week));
  final restKm = volumeOf(week.workouts) - long.distanceKm;
  final capFraction = fraction * restKm / (1 - fraction);
  var cappedDistance = long.distanceKm;
  var cappedDuration = long.targetDuration;

  if (cappedDistance > maxLongRunKm) {
    cappedDistance = maxLongRunKm;
    cappedDuration = null;
  }
  if (cappedDistance > capFraction && capFraction > 0) {
    cappedDistance = capFraction;
    cappedDuration = null;
  }
  if (cappedDuration != null && cappedDuration > maxLongRunDuration) {
    cappedDuration = maxLongRunDuration;
    cappedDistance = 0;
  }

  final adjusted = [
    for (final w in week.workouts)
      if (w == long && cappedDistance != w.distanceKm)
        // `weekday` has to survive the rebuild, or capping a long run silently
        // detaches it from the day a session log would refer to.
        _withWeekday(
          Workout(
            title: w.title,
            type: w.type,
            zone: w.zone,
            description: w.description,
            distanceKm: cappedDistance,
            // A capped distance invalidates a duration derived from the old one.
            targetDuration: cappedDistance == 0 ? w.targetDuration : null,
            isQuality: w.isQuality,
            hardFractionOfDistance: w.hardFractionOfDistance,
          ),
          w.weekday ?? 0,
        )
      else
        w,
  ];

  // The reported target is always what the week actually prescribes, capped or
  // not.
  //
  // A week is a budget, and a target that disagrees with the sessions under it is
  // a budget nobody can meet. Two things used to cause that: two quality sessions
  // were prescribed while only one was subtracted from the easy budget, and a
  // long run that had hit its distance cap stranded the leftover volume on a
  // single easy day. Both are legitimate outcomes — a floor and a cap are real
  // constraints — and the point is that they now show up in the number the
  // runner is shown rather than hiding behind it.
  return week.copyWith(
    workouts: adjusted,
    targetVolumeKm: volumeOf(adjusted),
  );
}

/// Recomputes a week's volume from its actual workouts.
double volumeOf(List<Workout> workouts) =>
    workouts.fold(0.0, (sum, w) => sum + w.distanceKm);

/// True if the week satisfies the 80/20 intensity rule, allowing a little
/// slack for rounding.
bool satisfiesEasyRule(PlanWeek week) =>
    week.runVolumeKm <= 0 || week.easyFraction >= easyVolumeTarget - 0.02;

/// Whether a proposed long run grows faster than the limit allows.
///
/// Deliberately does *not* return true for a flat or reduced long run: the
/// cutback logic relies on being able to shorten a long run, and an earlier
/// version conflated "no growth needed" with "growth too large" — which meant
/// the cutback was immediately undone on the same line.
bool exceedsLongRunGrowth(
  double previousKm,
  double targetKm, {
  required bool beginner,
}) {
  final allowed = beginner ? beginnerLongRunGrowth : 2.5;
  return targetKm - previousKm > allowed;
}

/// Caps a proposed long run at the growth limit.
double capLongRunGrowth(
  double previousKm,
  double targetKm, {
  required bool beginner,
}) {
  if (previousKm <= 0) return targetKm;
  if (!exceedsLongRunGrowth(previousKm, targetKm, beginner: beginner)) {
    return targetKm;
  }
  return previousKm + (beginner ? beginnerLongRunGrowth : 2.5);
}

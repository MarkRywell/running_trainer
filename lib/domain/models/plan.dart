/// Plan structure: phases, weeks, and individual workouts.
library;

import 'goal.dart';
import 'race.dart';
import '../units.dart';

/// The five Daniels intensity zones, ordered fastest to slowest.
enum IntensityZone {
  repetition('R', 'Repetition', 'Very fast, short reps — economy and turnover'),
  interval('I', 'Interval', 'Hard, 3–5 min reps — aerobic capacity'),
  threshold('T', 'Threshold', 'Comfortably hard, ~25 min — lactate threshold'),
  marathon('M', 'Marathon', 'Steady at goal race pace — endurance specific'),
  easy('E', 'Easy', 'Conversational — the bulk of your volume'),
  recovery('Rc', 'Recovery', 'Very easy — absorbing, or after a hard day');

  const IntensityZone(this.code, this.label, this.purpose);

  final String code;
  final String label;
  final String purpose;

  /// Zanes at or below [this] count as "easy" for the 80/20 check.
  bool get isEasy => this == easy || this == recovery;

  /// The reverse ordering, slowest first — how the plan reads top to bottom.
  static List<IntensityZone> get slowestFirst => const [
        recovery,
        easy,
        marathon,
        threshold,
        interval,
        repetition,
      ];
}

enum WorkoutType { easy, recovery, long, tempo, intervals, strides, walkRun, race, rest }

enum PlanPhase { base, specific, peak, taper, raceWeek, baseBlock }

extension PlanPhaseLabel on PlanPhase {
  String get label => switch (this) {
        PlanPhase.base => 'Base',
        PlanPhase.specific => 'Race-specific',
        PlanPhase.peak => 'Peak',
        PlanPhase.taper => 'Taper',
        PlanPhase.raceWeek => 'Race week',
        PlanPhase.baseBlock => 'Base building',
      };

  String get blurb => switch (this) {
        PlanPhase.base => 'Build volume. One or two hard sessions a week.',
        PlanPhase.specific => 'Goal-pace long runs, and sharpening work.',
        PlanPhase.peak => 'The biggest weeks, and the hardest.',
        PlanPhase.taper => 'Volume down, intensity kept. Arrive fresh.',
        PlanPhase.raceWeek => 'Race day. Everything before it is recovery.',
        PlanPhase.baseBlock => 'All easy. Build the habit before the fitness.',
      };
}

class Workout {
  const Workout({
    required this.title,
    required this.type,
    required this.zone,
    required this.description,
    this.distanceKm = 0,
    this.targetDuration,
    this.isQuality = false,
    this.hardFractionOfDistance = 0,
    this.weekday,
    this.reps,
    this.repDistanceM,
    this.repRecovery,
    this.repZone,
    this.prescribedPace,
  });

  final String title;
  final WorkoutType type;
  final IntensityZone zone;

  /// Human-readable purpose. Shown on the session card so the runner knows
  /// *why* the session exists, not just what it is.
  final String description;

  /// Target distance, in km. Zero for pure-duration sessions.
  final double distanceKm;

  /// Target duration, for sessions prescribed by time rather than distance.
  final Duration? targetDuration;

  /// True for the 1–2 hard sessions per week.
  final bool isQuality;

  /// Share of this session's distance actually run above easy pace.
  ///
  /// A tempo session is not a hard run from end to end — it is a warm-up, 25
  /// minutes at threshold, and a cool down, and most of its distance is easy.
  /// Without this the 80/20 rule becomes arithmetically unreachable for
  /// anyone on a three-day schedule, because one quality session would count
  /// as a third of the week entirely at threshold.
  final double hardFractionOfDistance;

  /// Day of the week this session is prescribed for, 1 = Monday.
  ///
  /// Null for rest days and for anything not built from a day pattern. It exists
  /// so a [SessionLog] — which records a *day*, not a timestamp — can be matched
  /// back to the session it refers to. Without it "the tempo was hard" cannot be
  /// told apart from "the long run was hard", which are opposite problems.
  ///
  /// Anything that rebuilds a [Workout] must carry this across, or capping a
  /// long run silently detaches it from the day it belongs to.
  final int? weekday;

  /// Repetitions in a set session, and the shape of each.
  ///
  /// Null for every session that is not a set — tempos, long runs, races. They
  /// used to be the *only* interval shape the app could express, because the
  /// set lived in a description string built from two hardcoded constants. The
  /// runner asked for 400m x 10 and 800m x 5 and neither was representable.
  ///
  /// These are separate fields rather than a formatted string for the same
  /// reason [weekday] is: anything that rebuilds a [Workout] must carry them
  /// across, and a lost [reps] renders a set-structured session as a shapeless
  /// one **without any error**. [enforceSafety] rebuilds the long run, so this
  /// is a live trap rather than a theoretical one.
  final int? reps;

  /// Length of one repetition, in metres. Null unless [reps] is set.
  ///
  /// This is what makes a rep format a *format*. Rep distance picks the pace a
  /// rep is run at — short reps at interval effort, long ones at threshold — so
  /// 400m x 10 and 2km x 3 are genuinely different sessions, not one session
  /// with a different number typed into the description.
  final int? repDistanceM;

  /// Recovery between repetitions, after the first. Null unless [reps] is set.
  final Duration? repRecovery;

  /// The zone the repetitions themselves are run at.
  ///
  /// Distinct from [zone] because a set session's headline zone and its rep pace
  /// are not always the same thing. Every rep here is run at one pace, and the
  /// warm-up, recoveries and cool-down are easy — so this is what the hard
  /// fraction is measured against.
  final IntensityZone? repZone;

  /// The exact pace this session is to be run at, when it is not a zone's pace.
  ///
  /// The session card used to derive its number from [zone] alone, which is a
  /// five-rung classification of a continuum. Real prescriptions do not land on
  /// the rungs: a 10K goal of 51:00 is 5:06/km, and for the athlete who set it
  /// the ladder had threshold at 5:09 and interval at 4:53 — **nothing at 5:06**.
  /// So the card said one number and the session's own description said another,
  /// and the card is the one a runner reads first.
  ///
  /// This is the number. [zone] stays a classification and keeps driving colour
  /// and the 80/20 check; it is no longer asked to be a measurement.
  final Pace? prescribedPace;

  /// The pace to show on the card.
  ///
  /// Falls back to the zone's pace for every session that is prescribed *at* a
  /// zone, which is almost all of them. Only the sessions that are prescribed at
  /// something off-ladder — the taper's race-pace set, the goal race itself —
  /// carry an explicit pace.
  Pace displayPace(TrainingPaces paces) =>
      prescribedPace ?? paces.forZone(zone);

  /// A copy placed on [day]. Used where a workout is built by hand rather than
  /// by a day pattern, and must not lose the other fields doing so.
  Workout withWeekday(int day) => Workout(
        title: title,
        type: type,
        zone: zone,
        description: description,
        distanceKm: distanceKm,
        targetDuration: targetDuration,
        isQuality: isQuality,
        hardFractionOfDistance: hardFractionOfDistance,
        weekday: day,
        reps: reps,
        repDistanceM: repDistanceM,
        repRecovery: repRecovery,
        repZone: repZone,
        prescribedPace: prescribedPace,
      );

  @override
  String toString() => '$title (${zone.code})';
}

class PlanWeek {
  const PlanWeek({
    required this.weekNumber,
    required this.startDate,
    required this.phase,
    required this.workouts,
    required this.targetVolumeKm,
    this.isCutback = false,
  });

  final int weekNumber;
  final DateTime startDate;
  final PlanPhase phase;
  final List<Workout> workouts;
  final double targetVolumeKm;
  final bool isCutback;

  List<Workout> get runs =>
      workouts.where((w) => w.type != WorkoutType.rest).toList();

  int get runCount => runs.length;

  /// Distance run above easy pace this week, in km.
  double get hardVolumeKm => runs
      .where((w) => !w.zone.isEasy)
      .fold(0.0, (sum, w) => sum + w.distanceKm * w.hardFractionOfDistance);

  /// Actual distance prescribed for the week, in km.
  ///
  /// The 80/20 rule is about how a week's *actual* running is distributed, so
  /// the fraction has to be measured against this rather than against
  /// [targetVolumeKm] — the two differ whenever a week's prescribed sessions
  /// do not add up to the volume target.
  double get runVolumeKm =>
      runs.fold(0.0, (sum, w) => sum + w.distanceKm);

  /// Fraction of the week's actual volume run at or below easy pace.
  double get easyFraction =>
      runVolumeKm == 0 ? 1.0 : (runVolumeKm - hardVolumeKm) / runVolumeKm;

  int get qualityCount => workouts.where((w) => w.isQuality).length;

  Workout? get longRun {
    for (final w in workouts) {
      if (w.type == WorkoutType.long) return w;
    }
    return null;
  }

  PlanWeek copyWith({
    List<Workout>? workouts,
    double? targetVolumeKm,
  }) =>
      PlanWeek(
        weekNumber: weekNumber,
        startDate: startDate,
        phase: phase,
        workouts: workouts ?? this.workouts,
        targetVolumeKm: targetVolumeKm ?? this.targetVolumeKm,
        isCutback: isCutback,
      );
}

/// Which generator produced a plan.
enum TrainingPath { beginnerBase, trainedRace }

extension TrainingPathLabel on TrainingPath {
  String get label => switch (this) {
        TrainingPath.beginnerBase => 'Base building',
        TrainingPath.trainedRace => 'Race preparation',
      };
}

/// A warning or advisory surfaced before the runner commits to a plan.
class PlanFlag {
  const PlanFlag({
    required this.severity,
    required this.title,
    required this.detail,
    this.suggestedDistance,
    this.suggestedDate,
  });

  final FlagSeverity severity;
  final String title;
  final String detail;

  /// For a "race too soon" flag: a distance that would be preparable.
  final RaceDistance? suggestedDistance;

  /// For a "race too soon" flag: a date that would leave enough runway.
  final DateTime? suggestedDate;
}

enum FlagSeverity { info, caution, warning }

class TrainingPlan {
  const TrainingPlan({
    required this.path,
    required this.weeks,
    required this.paces,
    required this.weeklyVolumeKm,
    required this.startDate,
    this.goal,
    this.flags = const [],
  });

  final TrainingPath path;
  final List<PlanWeek> weeks;

  /// Training paces derived from the goal race pace (or, with no goal, from
  /// current fitness).
  final TrainingPaces paces;

  final double weeklyVolumeKm;
  final DateTime startDate;
  final GoalRace? goal;
  final List<PlanFlag> flags;

  int get weekCount => weeks.length;

  DateTime? get raceDate => goal?.date;

  /// Averages the target volume across non-cutback weeks.
  double get averageWeeklyKm {
    if (weeks.isEmpty) return 0;
    final total = weeks.fold(0.0, (s, w) => s + w.targetVolumeKm);
    return total / weeks.length;
  }
}

/// The five training paces for a runner, in km units.
class TrainingPaces {
  const TrainingPaces({
    required this.repetition,
    required this.interval,
    required this.threshold,
    required this.marathon,
    required this.easy,
    required this.recovery,
  });

  final Pace repetition;
  final Pace interval;
  final Pace threshold;
  final Pace marathon;
  final Pace easy;
  final Pace recovery;

  Pace forZone(IntensityZone zone) => switch (zone) {
        IntensityZone.repetition => repetition,
        IntensityZone.interval => interval,
        IntensityZone.threshold => threshold,
        IntensityZone.marathon => marathon,
        IntensityZone.easy => easy,
        IntensityZone.recovery => recovery,
      };

  /// The zone whose pace is closest to [pace].
  ///
  /// For colour and classification only — never to produce a number, which is
  /// what [Workout.prescribedPace] is for. Used where a session is prescribed at
  /// a pace that is not on the ladder: the taper's race-pace set at 5:06/km is
  /// threshold effort for an athlete whose marathon-pace equivalent is 5:46, and
  /// labelling it `marathon` would paint the hardest-scheduled session of the
  /// block as the easiest.
  IntensityZone nearestZone(Pace pace) {
    var best = IntensityZone.easy;
    var bestGap = -1;
    for (final candidate in IntensityZone.values) {
      final gap = (forZone(candidate).secPerKm - pace.secPerKm).abs();
      if (bestGap < 0 || gap < bestGap) {
        bestGap = gap;
        best = candidate;
      }
    }
    return best;
  }

  /// The wide band for easy running: recovery end to marathon end.
  (Pace, Pace) get easyBand => (recovery, easy);

  /// Longest marathon-equivalent duration the athlete can hold at [zone].
  static const zoneIsFasterThanEasy = true;
}

/// Pre-plan validation.
///
/// These checks exist so the runner sees an honest picture *before* they
/// commit to a multi-month plan, rather than discovering the problem in week
/// nine. They warn; they do not block. The user's goal is the user's call —
/// the job here is to make sure they are choosing it with open eyes.
library;

import '../models/goal.dart';
import '../models/plan.dart';
import '../models/profile.dart';
import '../models/race.dart';
import '../models/week_log.dart';
import '../units.dart';
import '../progress.dart';
import 'fitness.dart';
import 'riiegel.dart';

/// What share of improvement a solid training block typically delivers, by
/// distance. Longer races have less percentage headroom.
///
/// [typical] is what a well-executed block usually produces; [stretch] is the
/// upper end of credible. Beyond [stretch] the goal is a fantasy, and training
/// to it is how runners get hurt.
({double typical, double stretch}) improvementHeadroom(RaceDistance d) =>
    switch (d) {
      RaceDistance.marathon => (typical: 0.03, stretch: 0.05),
      RaceDistance.half => (typical: 0.04, stretch: 0.06),
      RaceDistance.k10 => (typical: 0.05, stretch: 0.07),
      RaceDistance.k5 => (typical: 0.05, stretch: 0.08),
    };

/// Weeks of runway a goal needs to be properly preparable.
int requiredRunwayWeeks({required bool beginner, required RaceDistance goal}) {
  if (beginner) return goal == RaceDistance.marathon ? 20 : 12;
  return goal == RaceDistance.marathon ? 16 : 10;
}

/// How much of a realistic block a short runway allows. Below this the plan
/// cannot build fitness, only maintain it.
const double shortRunwayThreshold = 0.5;

/// How much the runner's logged training shifts the fitness the goal is judged
/// against, as a signed fraction. **Positive means fitter than the anchor race
/// suggests, negative means below it.** Null when the logs say nothing
/// confident.
///
/// A personal best is a *peak*, not current fitness. Somebody who ran 3:30 in
/// spring and has since trained consistently is probably a little better than
/// that figure implies, so judging a goal against the bare PB is quietly
/// optimistic. Somebody whose weeks keep coming back 8+ may in fact be below
/// their PB level right now, and judging against the bare PB is optimistic in
/// the same direction.
///
/// Because a fitter athlete has less ground to cover to reach a given target,
/// absorbed training makes a goal look *less* ambitious, and hard weeks make
/// it look *more* so. That is the useful direction: it means a goal that has
/// quietly become out of reach gets flagged.
///
/// The adjustments are deliberately small (1%). This is a nudge on an
/// already-imperfect projection, not a second fitness model — claiming to know
/// more than the logs do would be worse than leaving the PB alone.
const double _absorbedTrainingBonus = 0.01;
const double _strugglingPenalty = 0.01;
const double _strugglingDifficulty = 7.0;

double? trainedFitnessAdjustment(Map<String, WeekLog> weekLogs) {
  final difficulties = weekLogs.values
      .where((l) => l.completed && l.difficulty != null)
      .map((l) => l.difficulty!)
      .toList();
  if (difficulties.isEmpty) return null;

  final average =
      difficulties.reduce((a, b) => a + b) / difficulties.length;
  if (average >= _strugglingDifficulty) return -_strugglingPenalty;
  if (average <= _strugglingDifficulty - 2) return _absorbedTrainingBonus;
  // Somewhere in between: genuinely not sure, so say nothing.
  return null;
}

/// The time a runner could expect today at [distance], in a shape that can be
/// shown to them.
({Duration time, String basis}) currentExpectation({
  required FitnessAssessment fitness,
  required RaceDistance distance,
  Map<String, WeekLog> weekLogs = const {},
}) {
  final base = fitness.equivalentTo(distance);
  final adjustment = trainedFitnessAdjustment(weekLogs);
  if (base == null || adjustment == null) {
    return (
      time: base ?? Duration.zero,
      basis: 'your race times',
    );
  }
  final seconds = base.inSeconds * (1 - adjustment);
  return (
    time: Duration(seconds: seconds.round()),
    basis: adjustment > 0
        ? 'your race times plus the training you have logged'
        : 'your race times, allowing for the weeks that felt hard',
  );
}

/// Share of recorded sessions that must be rated hard before it is worth
/// saying anything.
///
/// Demanding on purpose. A single hard session is a bad day — heat, poor sleep,
/// a hard week at work. Half your sessions is a pattern, and half is also the
/// point at which the 80/20 rule has stopped being true in practice however
/// correct it is on paper.
const double _observedIntensityThreshold = 0.5;

/// How many recorded sessions are needed before the observation is worth raising.
///
/// Small samples are noise. Four sessions that all felt hard might be one
/// weekend.
const int _observedIntensityMinSessions = 8;

/// Flags a runner who is consistently training harder than the plan asks.
///
/// This is the one thing per-week logging structurally cannot see. A week-level
/// difficulty of "fine" is entirely compatible with running every easy day at
/// threshold, and that is precisely how a plan stops being gentle while every
/// headline number still looks correct.
List<PlanFlag> _validateObservedIntensity(
  Map<String, WeekLog> weekLogs,
  int weekCount,
  DateTime Function(int) weekStartFor,
) {
  final share = observedIntensity(
    weekLogs: weekLogs,
    weekCount: weekCount,
    weekStartFor: weekStartFor,
  );
  if (share == null || share <= _observedIntensityThreshold) {
    return const [];
  }

  var recorded = 0;
  for (var i = 0; i < weekCount; i++) {
    recorded += weekLogs[weekKey(weekStartFor(i))]?.recordedSessionCount ?? 0;
  }
  if (recorded < _observedIntensityMinSessions) return const [];

  final pct = (share * 100).round();
  return [
    PlanFlag(
      severity: FlagSeverity.caution,
      title: '$pct% of your sessions felt harder than planned',
      detail:
          'This plan asks for most of its running to be easy, and that is what '
          'makes the hard sessions work. When the easy days are run hard too, '
          'nothing recovers, and the adaptation you are training for does not '
          'happen.\n\n'
          'It is worth checking whether the prescribed easy pace feels '
          'uncomfortably slow. If it does, say so — the plan would rather be '
          'adjusted than quietly ignored.',
    ),
  ];
}

/// Runs every safety check and returns the flags to surface.
List<PlanFlag> validate({
  required RunnerProfile profile,
  required FitnessAssessment fitness,
  required GoalRace? goal,
  required DateTime today,
  Map<String, WeekLog> weekLogs = const {},
  int weekCount = 0,
  DateTime Function(int i)? weekStartFor,
}) {
  final flags = <PlanFlag>[];

  // Every data-quality note goes into **one** flag, not one flag each.
  //
  // This used to add a flag per note, all with the identical title "About your
  // race data", so a runner with two notes saw two identically-titled cards and
  // reasonably concluded the app had duplicated itself. The notes are not
  // separately actionable either — they are all the same category of "here is
  // what we did with your data" — so one card is the honest shape.
  if (fitness.notes.isNotEmpty) {
    flags.add(PlanFlag(
      severity: FlagSeverity.info,
      title: 'About your race data',
      detail: fitness.notes.join('\n\n'),
    ));
  }

  if (goal == null) return flags;

  final isBeginner = isBeginnerPath(profile, fitness);
  final weeks = goal.weeksUntilFrom(today);

  flags.addAll(_validateDate(goal, today, isBeginner, weeks));
  flags.addAll(_validateDistance(profile, goal, isBeginner));
  flags.addAll(_validateGoalTime(fitness, goal, weekLogs));
  flags.addAll(_validateGoalAgainstLoggedEffort(fitness, goal));
  if (weekStartFor != null) {
    flags.addAll(_validateObservedIntensity(weekLogs, weekCount, weekStartFor));
  }

  return flags;
}

/// True when the runner should get the beginner path.
///
/// The rule is about *experience*, and it is mostly about whether we have
/// anything to derive paces from.
///
/// The trained path reads every zone off an anchor race, so **no race data means
/// no trained path** — that is not a judgement call, it is a missing input. An
/// earlier version of this function let a 12-month runner with no race data
/// through, and every plan built for them threw.
///
/// Past that, a year of consistency plus real race data is strong evidence. A
/// volume gate may still demote to the all-easy base block, but it is scaled to
/// the days the runner actually trains. An *absolute* weekly threshold could
/// not be: a three-day runner cannot reach 24 km a week without already doing
/// the long run the threshold was meant to be gating. That misfiled a real
/// report — two years' running, a 1:56 half marathon, 15 km a week — onto a
/// beginner block with a 3 km long run.
bool isBeginnerPath(RunnerProfile profile, FitnessAssessment fitness) {
  if (!fitness.hasData) return true;
  if (profile.monthsRunning < 12) return true;

  final km = profile.estimatedWeeklyKm;
  if (km == null) return false;
  return km < profile.daysPerWeek * 5.0 * 0.6;
}

List<PlanFlag> _validateDate(
  GoalRace goal,
  DateTime today,
  bool isBeginner,
  int weeks,
) {
  final flags = <PlanFlag>[];

  if (goal.isInPast(today)) {
    return [
      const PlanFlag(
        severity: FlagSeverity.warning,
        title: 'That race has already happened',
        detail:
            'Pick a future date and we will build a plan around it.',
      ),
    ];
  }

  if (goal.daysPerWeek < 3) {
    flags.add(PlanFlag(
      severity: FlagSeverity.warning,
      title: 'Three days a week is the floor',
      detail:
          'You have said you can run on $goal.daysPerWeek days. Plans built on '
          'fewer than three days per week do not work — there is too little '
          'frequency for the training to land. We have built this plan on three '
          'days regardless, but the real fix is finding a third day.',
    ));
  }

  final needed = requiredRunwayWeeks(beginner: isBeginner, goal: goal.distance);
  if (weeks < needed) {
    final shortBy = needed - weeks;
    final suggestedDate = today.add(Duration(days: needed * 7));
    flags.add(PlanFlag(
      severity: weeks < needed * shortRunwayThreshold
          ? FlagSeverity.warning
          : FlagSeverity.caution,
      title: 'Only $weeks weeks to race day',
      detail: weeks < needed * shortRunwayThreshold
          ? 'There is not enough runway to build the fitness this race needs. '
              'A plan this short can only maintain you, not build you, so we '
              'have made it deliberately easy and treated the race as an '
              'A-effort. Moving the date by about $shortBy weeks, or choosing '
              'a shorter distance, would change that.'
          : 'It is tight, but workable. The plan leans easy and finishes with a '
              'taper. A little more runway would let us build properly.',
      suggestedDate: suggestedDate,
      suggestedDistance: _shorterGoal(goal.distance),
    ));
  }

  return flags;
}

/// The next distance down, for the "too soon" suggestion.
RaceDistance? _shorterGoal(RaceDistance d) => switch (d) {
      RaceDistance.marathon => RaceDistance.half,
      RaceDistance.half => RaceDistance.k10,
      RaceDistance.k10 => RaceDistance.k5,
      RaceDistance.k5 => null,
    };

List<PlanFlag> _validateDistance(
  RunnerProfile profile,
  GoalRace goal,
  bool isBeginner,
) {
  if (!isBeginner) return const [];
  if (goal.distance != RaceDistance.marathon) return const [];

  return const [
    PlanFlag(
      severity: FlagSeverity.warning,
      title: 'Marathon from a beginner base',
      detail:
          'You have under a year of running behind you, and the marathon is the '
          'single most injury-prone goal there is. A half marathon would let you '
          'build the same engine with a fraction of the risk — many runners go '
          'on to run the marathon a season later, faster and uninjured. We have '
          'built the marathon plan anyway, but it is genuinely the harder road.',
      suggestedDistance: RaceDistance.half,
    ),
  ];
}

/// How much faster a goal pace may be than the pace already sustained at a
/// logged heart rate before it is worth mentioning.
///
/// A goal is an ambition, and the whole point of this app is that it will build
/// toward one, so a demanding target is not a problem in itself. The margin is
/// set where a runner has clearly never held that pace at that effort — not at
/// the first sign of a stretch.
const double _effortCaveatMargin = 0.05;

/// Flags a goal whose pace is well beyond what the runner has demonstrated at a
/// recorded heart rate.
///
/// Arithmetic on the runner's own data — "you ran this pace at this bpm, and
/// the goal is faster" — and not a claim about lactate or maximum heart rate,
/// which a single race average cannot support. It can only ever *add a flag*;
/// it never touches a pace.
List<PlanFlag> _validateGoalAgainstLoggedEffort(
  FitnessAssessment fitness,
  GoalRace goal,
) {
  final withHr = fitness.races.where((r) => r.hasHr);
  if (withHr.isEmpty) return const [];

  // The most recent result with a heart rate, since that is the best evidence
  // of what they can do right now.
  final reference = withHr.first;
  final logged = Pace.fromDuration(reference.time, reference.distance.metres);
  final target = Pace.fromDuration(
    goal.finishTimeGoal,
    goal.distance.metres,
  );

  final demanded = (logged.secPerKm - target.secPerKm) / logged.secPerKm;
  if (demanded <= _effortCaveatMargin) return const [];

  final hr = reference.averageHr;
  return [
    PlanFlag(
      severity: FlagSeverity.info,
      title: 'Your goal pace is faster than you have run at $hr bpm',
      detail:
          'Your ${reference.distance.label} was ${formatDuration(reference.time)} '
          'at $hr bpm, and a ${goal.distance.label} in '
          '${formatDuration(goal.finishTimeGoal)} asks for a pace about '
          '${(demanded * 100).round()}% faster than that. Holding $hr bpm would '
          'not get you there, so expect this to feel harder than it looks on paper.\n\n'
          'Nothing has changed — we build to the goal you asked for, and the '
          'paces that result are safe either way. This is so the effort is not a '
          'surprise on race day.',
    ),
  ];
}

List<PlanFlag> _validateGoalTime(
  FitnessAssessment fitness,
  GoalRace goal,
  Map<String, WeekLog> weekLogs,
) {
  final expectation = currentExpectation(
    fitness: fitness,
    distance: goal.distance,
    weekLogs: weekLogs,
  );
  final equivalent = expectation.time;
  if (equivalent.inSeconds <= 0) return const [];

  final headroom = improvementHeadroom(goal.distance);
  final improvement =
      (equivalent.inSeconds - goal.finishTimeGoal.inSeconds) /
          equivalent.inSeconds;
  final basis = expectation.basis;

  if (improvement <= 0) {
    return [
      PlanFlag(
        severity: FlagSeverity.info,
        title: 'Goal is slower than your current equivalent',
        detail:
            'On $basis, you would expect around ${_fmt(equivalent)} for a '
            '${goal.distance.label}. Your ${_fmt(goal.finishTimeGoal)} goal is '
            'more conservative than that, which is a perfectly reasonable place '
            'to start. Expect to be pleasantly surprised.',
      ),
    ];
  }

  if (improvement <= headroom.typical) return const [];

  final stretch = improvement <= headroom.stretch;
  return [
    PlanFlag(
      severity: stretch ? FlagSeverity.caution : FlagSeverity.warning,
      title: stretch
          ? 'A stretch goal: ${_pct(improvement)} faster'
          : 'Beyond what this block can deliver: ${_pct(improvement)} faster',
      detail: stretch
          ? 'On $basis, you would expect around ${_fmt(equivalent)} for a '
              '${goal.distance.label}. ${_pct(improvement)} is at the hard end '
              'of what a training block delivers for this distance. It is '
              'achievable, but it depends on everything going right. We are '
              'building to your ${_fmt(goal.finishTimeGoal)} goal as you asked.'
          : 'On $basis, you would expect around ${_fmt(equivalent)} for a '
              '${goal.distance.label}. A ${goal.distance.label} block typically '
              'delivers about ${_pct(headroom.typical)}, and '
              '${_pct(headroom.stretch)} is a genuinely exceptional block. '
              '${_pct(improvement)} is a stretch worth revisiting — but we are '
              'building to your goal as you asked, and the paces that result '
              'are safe either way.',
    ),
  ];
}

String _pct(double fraction) => '${(fraction * 100).round()}%';

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$h:$m'.replaceFirst(RegExp(r'^0:'), '');
}

/// The equivalent time a runner could expect today, without a goal set.
Duration? currentEquivalent(FitnessAssessment fitness, RaceDistance d) =>
    fitness.equivalentTo(d);

/// Riegel projection from a single race, for the review screen.
Duration? projectFrom(
  RaceResult race,
  RaceDistance target, {
  bool conservative = true,
}) =>
    predictFrom(race, target: target, conservative: conservative);

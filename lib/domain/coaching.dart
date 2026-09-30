/// Turns recorded experience into proposals the runner can accept or decline.
///
/// ## Why proposals and not automatic changes
///
/// The product premise is that the plan must never be harder than the person
/// can follow. That is a promise about *the runner's* experience, so the runner
/// has to be the one who decides the plan changes. An app that silently
/// rewrites the thing it told you to do is not coaching, it is nagging with
/// extra steps.
///
/// So [propose] is pure: it reads logged weeks and returns zero or more
/// candidates. Nothing is applied. Each [CoachProposal] carries the reasoning
/// alongside the change, because a proposal without a reason is just a
/// surprise.
library;

import 'models/plan.dart';
import 'models/plan_directive.dart';
import 'progress.dart';

class CoachProposal {
  const CoachProposal({
    required this.id,
    required this.title,
    required this.rationale,
    required this.directive,
    this.severity = FlagSeverity.caution,
  });

  /// Stable identifier, so a proposal can be declined without being re-shown
  /// and re-accepted once the underlying situation changes.
  final String id;

  final String title;
  final String rationale;
  final PlanDirective directive;
  final FlagSeverity severity;
}

/// Fewest training days a proposal will ever suggest. Below three the habit
/// the plan is meant to be building stops existing.
const int _minimumTrainingDays = 3;

/// Hard quality sessions needed before dropping quality work is suggested.
///
/// Deliberately as demanding as the volume cap. A single hard tempo is a bad
/// day — heat, poor sleep, a hard week at work — and suggesting someone give up
/// their threshold work over one would be the app nagging with extra steps. Three
/// is where it stops being a bad day and becomes a miscalibration.
const int _hardQualitySessionsToSuggest = 3;

/// Hard *easy-day* sessions needed before anything is said about intensity.
///
/// Higher than the quality threshold on purpose. Running an easy day hard is a
/// genuine mistake and worth naming, but the fix is usually "slow down" rather
/// than "change the plan", so the bar for interrupting the runner is higher.
const int _hardEasySessionsToSuggest = 4;

List<CoachProposal> propose(PlanProgress progress) {
  final proposals = <CoachProposal>[];

  if (progress.looksTooHard) {
    proposals.add(CoachProposal(
      id: 'cap-volume',
      title: 'Hold your volume where it is',
      rationale: 'You rated ${_weekList(progress.hardWeeks)} at 8 or above out of '
          '10. Finishing a block is not the same as absorbing it, and building '
          'on weeks that hurt is how runners get hurt rather than faster.\n\n'
          'This keeps your distance flat from here on and lets the quality of '
          'each run do the work. You can lift it whenever you want.',
      directive: const PlanDirective(capVolume: true),
      severity: FlagSeverity.warning,
    ));
  }

  // The per-session answer to the same problem, and a more specific one: the
  // volume cap is right when *everything* is hard, and wrong when only the hard
  // sessions are. Offering both is safe precisely because neither applies itself.
  final hardQuality = progress.hardQualitySessionsRecorded;
  if (hardQuality >= _hardQualitySessionsToSuggest) {
    proposals.add(CoachProposal(
      id: 'drop-quality',
      title: 'Drop the hard sessions, keep everything else',
      rationale: 'The tempo and interval sessions in '
          '${_weekList(progress.hardQualityWeeks)} came back harder than you '
          'planned, while the rest of those weeks did not. That points at the '
          'quality work rather than at your volume.\n\n'
          'This removes the hard sessions and leaves your long run and easy days '
          'exactly as they are. You keep all the running; you lose the part that '
          'is not working. Put it back whenever it starts feeling right.',
      directive: const PlanDirective(suppressQuality: true),
      severity: FlagSeverity.caution,
    ));
  }

  if (progress.hardEasySessionsRecorded >= _hardEasySessionsToSuggest) {
    proposals.add(CoachProposal(
      id: 'slow-down',
      title: 'Your easy days are not being run easy',
      rationale: '${_sessionCount(progress.hardEasySessionsRecorded)} of your '
          'easy or recovery runs came back harder than planned. Most of this '
          'plan is easy running, and that is not filler — it is what lets the '
          'hard sessions work and what you actually adapt to.\n\n'
          'Worth a try: the prescribed easy pace should feel '
          'uncomfortably slow, to the point of feeling like you are going too '
          'slow to be running. We have not changed anything, because this is '
          'usually a pace to hold rather than a plan to change.',
      directive: const PlanDirective(),
      severity: FlagSeverity.info,
    ));
  }

  if (progress.looksUnderserved) {
    final prescribed = progress.typicalPrescribedSessions;
    if (prescribed != null && prescribed > _minimumTrainingDays) {
      final reduced = prescribed - 1;
      final pct = ((progress.sessionAdherence ?? 0) * 100).round();
      proposals.add(CoachProposal(
        id: 'fewer-days',
        title: 'Fewer days, not a harder plan',
        rationale: 'You are getting through $pct% of the sessions you are asked '
            'for, but the weeks themselves are not feeling hard. That is a '
            'scheduling problem, not a fitness one — the plan is asking for '
            'more time than you have, and the honest fix is to ask for less.\n\n'
            'Dropping to $reduced days keeps every run intact and makes the ones '
            'you do run count.',
        directive: PlanDirective(targetDaysPerWeek: reduced),
      ));
    }
  }

  return proposals;
}

/// Counts individual sessions rather than weeks, for the per-session proposals.
String _sessionCount(int n) => '$n of your runs';

String _weekList(List<int> weeks) {
  if (weeks.isEmpty) return 'no weeks';
  if (weeks.length == 1) return 'week ${weeks.first + 1}';
  if (weeks.length == 2) {
    return 'weeks ${weeks[0] + 1} and ${weeks[1] + 1}';
  }
  final head = weeks.take(weeks.length - 1).map((w) => w + 1).join(', ');
  return 'weeks $head and ${weeks.last + 1}';
}

/// What the runner has decided about proposals.
class CoachState {
  const CoachState({this.applied = const {}, this.dismissed = const {}});

  static const CoachState empty = CoachState();

  /// Proposal id → the directive accepted for it.
  final Map<String, PlanDirective> applied;

  /// Proposal id → the hard-week count at the moment it was declined.
  ///
  /// Keyed on the count rather than a boolean so a *worse* pattern can
  /// legitimately re-surface the proposal. Being told a block is too hard,
  /// declining it, and then having it get worse should not stay silent.
  final Map<String, int> dismissed;

  bool isAccepted(String id) => applied.containsKey(id);

  bool isDeclined(String id, int currentHardWeekCount) {
    final at = dismissed[id];
    if (at == null) return false;
    return currentHardWeekCount <= at;
  }

  /// The combined directive from everything accepted.
  ///
  /// A later accept wins on days, and any cap wins over no cap, so nudging the
  /// plan in one direction takes effect rather than silently losing to
  /// whichever was stored first.
  PlanDirective get directive {
    var days = applied['fewer-days']?.targetDaysPerWeek;
    var cap = false;
    for (final entry in applied.entries) {
      final d = entry.value;
      if (d.capVolume) cap = true;
      if (d.targetDaysPerWeek != null) days = d.targetDaysPerWeek;
    }
    return PlanDirective(capVolume: cap, targetDaysPerWeek: days);
  }

  bool get isEmpty => applied.isEmpty;

  CoachState accept(String id, PlanDirective directive) => CoachState(
        applied: {...applied, id: directive},
        dismissed: Map.of(dismissed)..remove(id),
      );

  CoachState decline(String id, int hardWeekCount) => CoachState(
        applied: Map.of(applied)..remove(id),
        dismissed: {...dismissed, id: hardWeekCount},
      );

  /// Proposals the runner has neither accepted nor declined into silence.
  List<CoachProposal> outstanding(PlanProgress progress) => propose(progress)
      .where((p) =>
          !isAccepted(p.id) && !isDeclined(p.id, progress.hardWeeks.length))
      .toList();

  Map<String, dynamic> toJson() => {
        'applied': applied.map((k, v) => MapEntry(k, v.toJson())),
        'dismissed': dismissed,
      };

  static CoachState fromJson(Map<String, dynamic> json) {
    final applied = <String, PlanDirective>{};
    final raw = json['applied'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map) {
          applied['${entry.key}'] = PlanDirective.fromJson(
            value.map((k, v) => MapEntry('$k', v)),
          );
        }
      }
    }
    final declined = <String, int>{};
    final rawDeclined = json['dismissed'];
    if (rawDeclined is Map) {
      for (final entry in rawDeclined.entries) {
        final value = entry.value;
        if (value is num) declined['${entry.key}'] = value.toInt();
      }
    }
    return CoachState(applied: applied, dismissed: declined);
  }
}

import 'package:flutter/foundation.dart';

import '../domain/coaching.dart';
import '../domain/engine/fitness.dart';
import '../domain/models/goal.dart';
import '../domain/models/plan.dart';
import '../domain/models/plan_directive.dart';
import '../domain/models/profile.dart';
import '../domain/models/race.dart';
import '../domain/models/week_log.dart';
import '../domain/plan/beginner_plan.dart' show alignToNextMonday;
import '../domain/plan/generate.dart';
import '../domain/progress.dart';
import 'storage.dart';

/// Owns the runner's inputs and the plan derived from them.
///
/// The plan is never stored — it is recomputed from the inputs, so there is no
/// way for the two to disagree. That also means any input change regenerates
/// the whole plan from week zero, which is the v1 limitation: with no training
/// log there is nothing to preserve completed weeks against.
class TrainerController extends ChangeNotifier {
  TrainerController(this._storage);

  final TrainerStorage _storage;

  RunnerProfile? _profile;
  List<RaceResult> _races = const [];
  GoalRace? _goal;
  DateTime? _startDate;
  TrainingPlan? _plan;
  FitnessAssessment? _fitness;
  Map<String, WeekLog> _weekLogs = <String, WeekLog>{};
  CoachState _coachState = CoachState.empty;

  bool _ready = false;

  RunnerProfile? get profile => _profile;
  List<RaceResult> get races => _races;
  GoalRace? get goal => _goal;
  DateTime? get startDate => _startDate;
  TrainingPlan? get plan => _plan;
  FitnessAssessment? get fitness => _fitness;
  bool get ready => _ready;
  bool get hasPlan => _plan != null;

  /// Completion, adherence and orientation, derived from the plan and the logs.
  PlanProgress? get progress {
    final p = _plan;
    if (p == null) return null;
    return PlanProgress(plan: p, weekLogs: _weekLogs);
  }

  /// Coach proposals the runner has not accepted or declined into silence.
  List<CoachProposal> get outstandingProposals {
    final p = progress;
    return p == null ? const [] : _coachState.outstanding(p);
  }

  /// What the runner has agreed to change, and the plan lines in force.
  CoachState get coachState => _coachState;
  PlanDirective get directive => _coachState.directive;

  /// Loads any saved state and regenerates from it.
  Future<void> init() async {
    _profile = _storage.loadProfile();
    _races = _storage.loadRaces();
    _goal = _storage.loadGoal();
    _startDate = _storage.loadStartDate();
    _weekLogs = _storage.loadWeekLogs();
    _coachState = _storage.loadCoachState();
    if (_profile != null) {
      _rebuild();
    }
    _ready = true;
    notifyListeners();
  }

  /// Accepts a coach proposal. This is the only way a plan changes shape
  /// automatically — nothing is applied without the runner saying yes.
  Future<void> acceptProposal(CoachProposal proposal) async {
    _coachState = _coachState.accept(proposal.id, proposal.directive);
    await _applyAndPersist();
  }

  /// Declines a proposal. It will not reappear unless the situation worsens.
  Future<void> declineProposal(CoachProposal proposal) async {
    final hard = progress?.hardWeeks.length ?? 0;
    _coachState = _coachState.decline(proposal.id, hard);
    await _applyAndPersist();
  }

  /// Withdraws an accepted change, putting the plan back as it was.
  Future<void> revokeProposal(String id) async {
    if (!_coachState.isAccepted(id)) return;
    _coachState = _coachState.accept(id, const PlanDirective());
    await _applyAndPersist();
  }

  Future<void> _applyAndPersist() async {
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// Commits onboarding and builds the first plan.
  Future<void> completeOnboarding({
    required RunnerProfile profile,
    required List<RaceResult> races,
    GoalRace? goal,
    DateTime? startDate,
  }) async {
    _profile = profile;
    _races = races;
    _goal = goal;
    // Weeks are relative to onboarding, but snapped forward to the next
    // Monday. A plan that starts mid-week wastes its first week, and makes the
    // runner look behind before they have run a step.
    _startDate = alignToNextMonday(startDate ?? DateTime.now());
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// Replaces the goal race and regenerates.
  ///
  /// Regeneration changes the plan but not the week start dates, so completed
  /// weeks carry over — this used to throw away the whole block.
  Future<void> setGoal(GoalRace? goal) async {
    _goal = goal;
    if (_profile == null) return;
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// Replaces the runner's details and regenerates.
  ///
  /// **Logged weeks are kept.** The start date is unchanged, so completion is
  /// keyed on the same week-start keys and carries over. That is the same
  /// property that makes editing a goal safe, and it is the reason this is an
  /// edit rather than a restart: a new 10K time should not cost you a season of
  /// logs. The logs stay true statements about what you ran, and the 90% rule
  /// uses them to shape the new plan.
  Future<void> setProfile(RunnerProfile profile) async {
    _profile = profile;
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// Replaces the recorded race results and regenerates.
  ///
  /// Kept weeks, as with [setProfile].
  Future<void> setRaces(List<RaceResult> races) async {
    _races = races;
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// Starts a fresh block for the same runner.
  ///
  /// Keeps the profile, race times and goal — the runner is the same person with
  /// the same fitness. Re-anchors the start to the next Monday and **clears the
  /// week log**, because completion is keyed on week-start dates: a new start
  /// means new keys, and carrying old weeks across would credit this block with
  /// work done in the last one.
  ///
  /// Coach state is cleared too. An accepted cap or a decline was a judgement
  /// about the block that has just ended, and keeping it would silently shape
  /// the new one.
  Future<void> restartPlan() async {
    if (_profile == null) return;
    _startDate = alignToNextMonday(DateTime.now());
    _weekLogs = <String, WeekLog>{};
    _coachState = CoachState.empty;
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// Marks a plan week done or not-done, from the one-tap control.
  ///
  /// The quick button is **authoritative** for the week's *self-reported* fields:
  /// it clears difficulty and mileage so the effect never depends on invisible
  /// prior state. A predictable button beats one whose behaviour is a function
  /// of what happens to be lying around.
  ///
  /// **Per-session records survive.** They are what the runner actually did, and
  /// they are the most expensive data in the app to reproduce — losing a week of
  /// one-tap-per-session logging because someone tapped "done" would be throwing
  /// away the thing that took the most effort. Un-marking still clears the
  /// week's own data as well as everything after it, because you cannot have run
  /// part of a week and also disowned the week itself.
  Future<void> markWeekComplete(int weekIndex, {bool value = true}) {
    if (!value) return logWeek(weekIndex, const WeekLog());
    final existing = logWeekFor(weekIndex);
    return logWeek(weekIndex, existing.clearedForQuickDone());
  }

  /// Records what actually happened in a week.
  ///
  /// Every field beyond [completed] is optional. A runner who just taps "done"
  /// should never be nagged.
  ///
  /// Un-marking a week also clears every week after it, because you cannot
  /// claim to have finished weeks built on one you disowned.
  Future<void> logWeek(int weekIndex, WeekLog log) async {
    final plan = _plan;
    if (plan == null) return;
    if (weekIndex < 0 || weekIndex >= plan.weekCount) return;

    final key = weekKey(plan.weeks[weekIndex].startDate);

    if (!log.completed) {
      // A week that is not done cannot carry session or distance data, and it
      // invalidates every week built on top of it.
      for (var i = weekIndex + 1; i < plan.weekCount; i++) {
        _weekLogs.remove(weekKey(plan.weeks[i].startDate));
      }
    }

    if (log.hasData) {
      _weekLogs[key] = log;
    } else {
      _weekLogs.remove(key);
    }
    // Regenerate: the volume curve is a function of the logs, so a newly
    // recorded week can hold the following week flat. Without this the logs
    // were recorded and the plan silently ignored them.
    _rebuild();
    await _persist();
    notifyListeners();
  }

  /// The current record for a week.
  WeekLog logWeekFor(int weekIndex) => progress?.logFor(weekIndex) ?? const WeekLog();

  /// Records how one prescribed session went.
  ///
  /// Additive and forgiving: it merges into whatever is already recorded for
  /// that day rather than replacing the week, because a runner tapping "that
  /// one was hard" has not just invalidated everything else they told us about
  /// the week. A null [felt] clears the record for that day rather than storing
  /// a "not sure" — the same rule as everywhere else in this app: absent means
  /// unknown, never bad.
  Future<void> logSession(
    int weekIndex,
    int dayOfWeek, {
    SessionFelt? felt,
    bool clearFelt = false,
  }) async {
    final plan = _plan;
    if (plan == null) return;
    if (weekIndex < 0 || weekIndex >= plan.weekCount) return;
    if (dayOfWeek < 1 || dayOfWeek > 7) return;

    final key = weekKey(plan.weeks[weekIndex].startDate);
    final log = _weekLogs[key] ?? const WeekLog();

    final updated = [
      for (final s in log.sessions)
        if (s.dayOfWeek != dayOfWeek) s,
      if (!clearFelt)
        SessionLog(dayOfWeek: dayOfWeek, felt: felt ?? _existingFelt(log, dayOfWeek)),
    ];

    // A week with a session record but no completion is still a real record, so
    // `hasData` must stay true for it — otherwise marking effort during the week
    // in progress would look like "nothing logged" to every rollup.
    _weekLogs[key] = log.copyWith(sessions: updated);
    _rebuild();
    await _persist();
    notifyListeners();
  }

  static SessionFelt? _existingFelt(WeekLog log, int day) {
    for (final s in log.sessions) {
      if (s.dayOfWeek == day) return s.felt;
    }
    return null;
  }

  /// Wipes all state and returns to onboarding.
  Future<void> reset() async {
    _profile = null;
    _races = const [];
    _goal = null;
    _startDate = null;
    _plan = null;
    _fitness = null;
    _weekLogs = <String, WeekLog>{};
    _coachState = CoachState.empty;
    await _storage.clear();
    notifyListeners();
  }

  void _rebuild() {
    final p = _profile;
    if (p == null) return;
    final start = _startDate ?? DateTime.now();
    _fitness = assessFitness(_races, start);
    // The week logs are an *input* to generation, not a decoration applied
    // afterwards. That keeps `generate` a pure function while letting the
    // volume curve react to a week the runner did not complete.
    _plan = generate(
      profile: p,
      races: _races,
      goal: _goal,
      startDate: start,
      weekLogs: _weekLogs,
      directive: _coachState.directive,
    );
    // Drop logs for weeks that no longer exist, so a shortened plan does not
    // carry orphaned keys forever. Note this happens *after* generation, so
    // orphan keys still participate in one cycle's curve — harmless, and it
    // avoids a chicken-and-egg with the keys the new plan is about to use.
    final valid = _plan!.weeks.map((w) => weekKey(w.startDate)).toSet();
    final pruned = Map.fromEntries(
      _weekLogs.entries.where((e) => valid.contains(e.key)),
    );
    if (pruned.length != _weekLogs.length) {
      _weekLogs = pruned;
    }
  }

  Future<void> _persist() async {
    final p = _profile;
    if (p == null) return;
    await _storage.save(
      profile: p,
      races: _races,
      goal: _goal,
      startDate: _startDate ?? DateTime.now(),
      weekLogs: _weekLogs,
      coachState: _coachState,
    );
  }

  /// Index of the week the runner is currently in, based on wall-clock time.
  ///
  /// Falls back to [PlanProgress.suggestedWeekIndex] once completion is
  /// tracked, so a runner who falls behind is put back on their first missed
  /// week instead of being marched forward into a block they never started.
  int get currentWeekIndex {
    final plan = _plan;
    final p = progress;
    if (plan == null || p == null) return 0;
    return p.suggestedWeekIndex.clamp(0, plan.weekCount - 1);
  }

  /// Flags worth surfacing above the fold, worst first.
  List<PlanFlag> get importantFlags {
    final flags = [...?_plan?.flags];
    flags.sort((a, b) => b.severity.index.compareTo(a.severity.index));
    return flags;
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/coaching.dart';
import '../domain/models/goal.dart';
import '../domain/models/profile.dart';
import '../domain/models/race.dart';
import '../domain/models/week_log.dart';

/// Persists the runner's inputs.
///
/// The generated plan is deliberately *not* stored. It is a pure function of
/// these inputs, so it is regenerated on load — which means it can never drift
/// out of sync with the profile that produced it, and there is only one copy
/// of the plan logic in the app.
class TrainerStorage {
  TrainerStorage(this._prefs);

  static const _kProfile = 'profile';
  static const _kRaces = 'races';
  static const _kGoal = 'goal';
  static const _kStartDate = 'startDate';
  static const _kCompletedWeeks = 'completedWeeks';
  static const _kWeekLogs = 'weekLogs';
  static const _kCoachState = 'coachState';

  final SharedPreferences _prefs;

  static Future<TrainerStorage> open() async =>
      TrainerStorage(await SharedPreferences.getInstance());

  bool get hasProfile => _prefs.containsKey(_kProfile);

  RunnerProfile? loadProfile() {
    final raw = _prefs.getString(_kProfile);
    if (raw == null) return null;
    return RunnerProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  List<RaceResult> loadRaces() {
    final raw = _prefs.getString(_kRaces);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => RaceResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  GoalRace? loadGoal() {
    final raw = _prefs.getString(_kGoal);
    if (raw == null) return null;
    return GoalRace.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  DateTime? loadStartDate() {
    final raw = _prefs.getString(_kStartDate);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Week-start keys (`yyyy-MM-dd`) the runner has marked done.
  ///
  /// Superseded by [loadWeekLogs], which carries more than the boolean. Still
  /// read for one-off migration of installs made before the richer log existed.
  Set<String> loadCompletedWeeks() {
    final raw = _prefs.getStringList(_kCompletedWeeks);
    if (raw == null) return <String>{};
    return raw.where((e) => e.isNotEmpty).toSet();
  }

  /// Week-start key → the runner's record for that week.
  Map<String, WeekLog> loadWeekLogs() {
    final raw = _prefs.getString(_kWeekLogs);
    final logs = <String, WeekLog>{};
    if (raw != null) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        try {
          logs[entry.key] = WeekLog.fromJson(entry.value as Map<String, dynamic>);
        } on Object {
          // A single unreadable entry must not lose the rest of the history.
          continue;
        }
      }
    } else {
      // Migrate the older boolean-only format rather than silently dropping a
      // returning runner's completed weeks.
      for (final key in loadCompletedWeeks()) {
        logs[key] = const WeekLog(completed: true);
      }
    }
    return logs;
  }

  /// What the runner has accepted or declined from coach proposals.
  CoachState loadCoachState() {
    final raw = _prefs.getString(_kCoachState);
    if (raw == null) return CoachState.empty;
    try {
      return CoachState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // A corrupt state must not stop the app launching; the worst case is
      // that proposals are shown again.
      return CoachState.empty;
    }
  }

  Future<void> save({
    required RunnerProfile profile,
    required List<RaceResult> races,
    required GoalRace? goal,
    required DateTime startDate,
    Map<String, WeekLog> weekLogs = const {},
    CoachState coachState = CoachState.empty,
  }) async {
    await _prefs.setString(_kProfile, jsonEncode(profile.toJson()));
    await _prefs.setString(
      _kRaces,
      jsonEncode(races.map((r) => r.toJson()).toList()),
    );
    if (goal == null) {
      await _prefs.remove(_kGoal);
    } else {
      await _prefs.setString(_kGoal, jsonEncode(goal.toJson()));
    }
    await _prefs.setString(_kStartDate, startDate.toIso8601String());
    // Keys sorted so the stored value is stable and diffable.
    final keys = weekLogs.keys.toList()..sort();
    await _prefs.setString(
      _kWeekLogs,
      jsonEncode({for (final k in keys) k: weekLogs[k]!.toJson()}),
    );
    await _prefs.setString(_kCoachState, jsonEncode(coachState.toJson()));
  }

  Future<void> clear() async {
    await _prefs.remove(_kProfile);
    await _prefs.remove(_kRaces);
    await _prefs.remove(_kGoal);
    await _prefs.remove(_kStartDate);
    await _prefs.remove(_kCompletedWeeks);
    await _prefs.remove(_kWeekLogs);
    await _prefs.remove(_kCoachState);
  }
}

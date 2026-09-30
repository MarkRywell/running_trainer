/// What a runner records about a week they have done.
///
/// ## Why per-week, not per-run
///
/// Deliberate product decision. A per-run log grows without bound and would
/// eventually force a real database; per-week keeps a few dozen small records
/// in `shared_preferences`, which is the right tool at this size.
///
/// The trade-off is real and worth stating: per-week adaptation is coarser.
/// You learn that a week was too hard, not *which* session in it was. That is
/// enough to cap progression and to flag a block as too ambitious, but not
/// enough to rewrite a specific workout.
///
/// ## Why difficulty is the important field
///
/// `completed` answers "did you do it". `difficulty` answers "was it too
/// much", and the second question is the one the product exists to handle. A
/// runner who ticks every box while grinding out every week is following a
/// plan that is too hard for them, and only difficulty reveals that.
///
/// ## Why [sessions] is bounded by the plan
///
/// Phase 5 rejected a per-run log because it "grows without bound and would
/// eventually force a real database". That objection is about *free-form run
/// history* — every run, forever, including runs that were not on the plan.
///
/// This is not that. A [SessionLog] is one entry per **prescribed** session, so
/// a week holds at most seven, and a twenty-week block is roughly 140 small
/// records. The plan supplies the bound; nothing has to be disciplined about it.
/// `shared_preferences` is still the right tool at that size.
library;

/// How one prescribed session actually went.
///
/// Three states, deliberately. The week-level `difficulty` is a 1–10 slider and
/// it works, but it is three or four taps and a week is a coarse unit — a runner
/// who was fine on the long run and cooked on the tempo has no way to say so.
/// A single tap per session is the difference between data that exists on the
/// weeks that matter and data that does not.
enum SessionFelt {
  /// Comfortably as prescribed.
  easy,

  /// About right. Neither good nor bad.
  right,

  /// Harder than prescribed — too fast, too long, or the legs were not there.
  hard,
}

/// One prescribed session, and how it actually went.
class SessionLog {
  const SessionLog({
    required this.dayOfWeek,
    this.felt,
    this.actualKm,
  });

  /// Which day of the plan's week this was, 1 = Monday.
  ///
  /// Keyed to the *prescribed* session rather than to a timestamp, which is what
  /// keeps the record bounded and directly comparable to what was asked.
  final int dayOfWeek;

  /// How it felt, or null if not recorded.
  ///
  /// Null is neutral, never "bad". Unrecorded is the overwhelmingly common case
  /// and must not be read as a missed session or a hard one.
  final SessionFelt? felt;

  /// Distance actually run, in km. Null if not recorded.
  final double? actualKm;

  /// A hard session, by the runner's own account.
  bool get feltHard => felt == SessionFelt.hard;

  bool get hasData => felt != null || actualKm != null;

  SessionLog copyWith({
    SessionFelt? felt,
    double? actualKm,
    bool clearFelt = false,
    bool clearActualKm = false,
  }) =>
      SessionLog(
        dayOfWeek: dayOfWeek,
        felt: clearFelt ? null : (felt ?? this.felt),
        actualKm: clearActualKm ? null : (actualKm ?? this.actualKm),
      );

  Map<String, dynamic> toJson() => {
        'day': dayOfWeek,
        if (felt != null) 'felt': felt!.name,
        if (actualKm != null) 'actualKm': actualKm,
      };

  static SessionLog fromJson(Map<String, dynamic> json) => SessionLog(
        dayOfWeek: (json['day'] as num?)?.toInt() ?? 1,
        felt: json['felt'] == null
            ? null
            : SessionFelt.values.firstWhere(
                (f) => f.name == json['felt'],
                orElse: () => SessionFelt.right,
              ),
        actualKm: (json['actualKm'] as num?)?.toDouble(),
      );
}

class WeekLog {
  const WeekLog({
    this.completed = false,
    this.actualKm,
    this.sessionsDone,
    this.difficulty,
    this.note,
    this.sessions = const [],
  });

  /// The runner marked the week done.
  final bool completed;

  /// Distance actually run, in km. Null if not recorded.
  final double? actualKm;

  /// How many of the prescribed sessions were actually run.
  final int? sessionsDone;

  /// How hard the week felt overall, 1–10. Null if not recorded.
  ///
  /// 1–2 is uncomfortably easy, 3–4 about right, 7+ too hard. Anything
  /// consistently at 8+ means the plan is miscalibrated for this runner.
  final int? difficulty;

  /// Free text. A place for "knee hurt", "holiday", "life happened".
  final String? note;

  /// How the individual prescribed sessions went. At most
  /// [maxSessionsPerWeek] entries.
  final List<SessionLog> sessions;

  /// Sessions the runner recorded as harder than prescribed.
  int get hardSessionCount => sessions.where((s) => s.feltHard).length;

  /// Sessions recorded with any effort at all.
  ///
  /// The denominator for anything per-session, so that a week with no session
  /// records reads as "unknown" rather than 0%.
  int get recordedSessionCount => sessions.where((s) => s.felt != null).length;

  /// Alias of [recordedSessionCount], for the week level rather than the
  /// plan-wide rollup of the same name.
  int get sessionsWithEffort => recordedSessionCount;

  bool get hasData =>
      completed ||
      actualKm != null ||
      sessionsDone != null ||
      difficulty != null ||
      (note != null && note!.trim().isNotEmpty) ||
      sessions.any((s) => s.hasData);

  /// A week that felt too hard, by the runner's own account.
  bool get feltTooHard => (difficulty ?? 0) >= 8;

  /// A week that was comfortably too easy.
  bool get feltTooEasy => difficulty != null && difficulty! <= 2;

  WeekLog copyWith({
    bool? completed,
    double? actualKm,
    int? sessionsDone,
    int? difficulty,
    String? note,
    bool clearNote = false,
    List<SessionLog>? sessions,
  }) {
    return WeekLog(
      completed: completed ?? this.completed,
      actualKm: actualKm ?? this.actualKm,
      sessionsDone: sessionsDone ?? this.sessionsDone,
      difficulty: difficulty ?? this.difficulty,
      note: clearNote ? null : (note ?? this.note),
      sessions: sessions ?? this.sessions,
    );
  }

  /// A copy with the self-reported week-level fields cleared and `sessions`
  /// preserved.
  ///
  /// This is what the one-tap "mark done" control needs. [markWeekComplete] is
  /// deliberately *authoritative* — it clears difficulty and mileage so the
  /// button's effect never depends on invisible prior state — but a per-session
  /// record is what the runner actually did, and it is the most expensive data
  /// in the app to reproduce. Wiping it because someone tapped "done" would be
  /// throwing away the thing that took the most effort to collect.
  WeekLog clearedForQuickDone() => WeekLog(
        completed: true,
        sessions: sessions,
      );

  Map<String, dynamic> toJson() => {
        'completed': completed,
        if (actualKm != null) 'actualKm': actualKm,
        if (sessionsDone != null) 'sessionsDone': sessionsDone,
        if (difficulty != null) 'difficulty': difficulty,
        if (note != null && note!.trim().isNotEmpty) 'note': note,
        if (sessions.isNotEmpty)
          'sessions': [for (final s in sessions) s.toJson()],
      };

  static WeekLog fromJson(Map<String, dynamic> json) {
    final sessions = <SessionLog>[];
    final raw = json['sessions'];
    if (raw is List) {
      for (final entry in raw) {
        try {
          final s = SessionLog.fromJson(entry as Map<String, dynamic>);
          if (s.dayOfWeek >= 1 && s.dayOfWeek <= 7) sessions.add(s);
        } on Object {
          // One unreadable session must not lose the rest of the week.
          continue;
        }
      }
    }
    return WeekLog(
      completed: json['completed'] == true,
      actualKm: (json['actualKm'] as num?)?.toDouble(),
      sessionsDone: (json['sessionsDone'] as num?)?.toInt(),
      difficulty: (json['difficulty'] as num?)?.toInt(),
      note: json['note'] as String?,
      sessions: _bounded(sessions),
    );
  }
}

/// Longest a week can hold, so the record cannot grow without bound.
///
/// Seven is a week. The plan never prescribes more, and an entry beyond this
/// would have no session to correspond to.
const int maxSessionsPerWeek = 7;

/// Trims a session list to the week bound, keeping the earliest days.
List<SessionLog> _bounded(List<SessionLog> sessions) {
  if (sessions.length <= maxSessionsPerWeek) return sessions;
  final byDay = {for (final s in sessions) s.dayOfWeek: s};
  return [
    for (var day = 1; day <= maxSessionsPerWeek; day++)
      if (byDay[day] != null) byDay[day]!,
  ];
}

/// An upcoming target race.
library;

import 'race.dart';

class GoalRace {
  const GoalRace({
    required this.distance,
    required this.date,
    required this.finishTimeGoal,
    required this.daysPerWeek,
  });

  final RaceDistance distance;
  final DateTime date;

  /// The finish time the runner is aiming for.
  final Duration finishTimeGoal;

  /// Days per week the runner can commit to preparing. This is a hard
  /// constraint on the generated plan, not a preference.
  final int daysPerWeek;

  /// Whole weeks from [start] until race day. Never negative.
  int weeksUntilFrom(DateTime start) {
    final days = date.difference(start).inDays;
    if (days <= 0) return 0;
    return (days / 7).ceil();
  }

  bool isInPast(DateTime reference) =>
      date.difference(reference).inDays < 0;

  GoalRace copyWith({
    RaceDistance? distance,
    DateTime? date,
    Duration? finishTimeGoal,
    int? daysPerWeek,
  }) {
    return GoalRace(
      distance: distance ?? this.distance,
      date: date ?? this.date,
      finishTimeGoal: finishTimeGoal ?? this.finishTimeGoal,
      daysPerWeek: daysPerWeek ?? this.daysPerWeek,
    );
  }

  Map<String, dynamic> toJson() => {
        'distance': distance.name,
        'date': date.toIso8601String(),
        'finishTimeGoal': finishTimeGoal.inSeconds,
        'daysPerWeek': daysPerWeek,
      };

  /// Value equality.
  ///
  /// `GoalEditor.didUpdateWidget` guards its resync with
  /// `widget.value != old.value`, and the comment above it says the guard is
  /// there so "every keystroke" does not reset the field being typed into.
  /// **Without this the guard is an identity comparison and does the exact
  /// opposite**, which is a real bug found on a physical phone: the finish-time
  /// field was being rewritten on every keystroke, and because `formatTimeInput`
  /// pads and re-shapes the text, the character you had just typed was
  /// swallowed.
  ///
  /// It presented as "the second colon won't go in", and the asymmetry is the
  /// tell. The first colon survived because at that point no goal had been saved
  /// yet, so `_emit` returned without emitting and nothing rebuilt. By the second
  /// colon a previous value existed, the unparseable text was emitted as that
  /// previous value, the parent rebuilt, and the reseed erased the colon. Every
  /// three-part time hits this, because the second colon is the last character
  /// typed and by then a successful parse has already created a previous value.
  ///
  /// A value object with a `copyWith`; identity was never the semantics wanted.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GoalRace &&
          other.distance == distance &&
          other.date == date &&
          other.finishTimeGoal == finishTimeGoal &&
          other.daysPerWeek == daysPerWeek;

  @override
  int get hashCode =>
      Object.hash(distance, date, finishTimeGoal, daysPerWeek);

  static GoalRace? fromJson(Map<String, dynamic> json) {
    final name = json['distance'] as String?;
    if (name == null) return null;
    return GoalRace(
      distance: RaceDistance.values.firstWhere((d) => d.name == name),
      date: DateTime.parse(json['date'] as String),
      finishTimeGoal: Duration(seconds: (json['finishTimeGoal'] as num).toInt()),
      daysPerWeek: (json['daysPerWeek'] as num?)?.toInt() ?? 3,
    );
  }
}

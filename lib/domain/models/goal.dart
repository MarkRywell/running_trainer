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

/// Race distances the app supports.
library;

enum RaceDistance {
  k5(5000, '5K'),
  k10(10000, '10K'),
  half(21097.5, 'Half marathon'),
  marathon(42197.5, 'Marathon');

  const RaceDistance(this.metres, this.label);

  final double metres;
  final String label;

  /// 5K and 10K — a distance that is finished on current fitness.
  ///
  /// This is the line the taper is drawn on, and it is a real physiological
  /// distinction rather than a matter of taste. There is no glycogen debt to clear
  /// at these distances and no race-specific durability to build, so the tools
  /// that a marathon taper needs — a second week, a shortened long run — buy
  /// nothing here. A 10K athlete is racing on speed and freshness; a marathon
  /// athlete is racing on fuelling and fatigue management.
  bool get isShort => this == k5 || this == k10;

  static RaceDistance fromName(String name) =>
      RaceDistance.values.firstWhere((d) => d.name == name);
}

/// A single race result, with the date it was achieved.
///
/// The date matters as much as the time: a two-year-old 10K describes a
/// different physiological reality than a six-week-old one.
class RaceResult {
  const RaceResult({
    required this.distance,
    required this.time,
    required this.date,
    this.averageHr,
  });

  final RaceDistance distance;
  final Duration time;
  final DateTime date;

  /// Average heart rate across the race, in bpm. Optional.
  ///
  /// Stored, shown, and used to raise a note — and for nothing else. It is
  /// deliberately **not** an input to plan generation, because VDOT from a
  /// finish time is more accurate than anything derivable from a race average,
  /// and because a heart rate is device-dependent and drifts with heat,
  /// hydration, caffeine and age. A zone derived from the wrong number targets
  /// the wrong thing, which is the one failure this app is built to avoid.
  ///
  /// `test/domain/heart_rate_guard_test.dart` asserts a plan generated with and
  /// without this field is identical. That test is what makes the paragraph
  /// above true rather than aspirational.
  final int? averageHr;

  /// True when this result carries a heart rate, used to disclose a set where
  /// only some races were recorded with one.
  bool get hasHr => averageHr != null;

  /// Days between this race and [reference]. Negative if in the future.
  int ageInDays(DateTime reference) =>
      reference.difference(date).inDays;

  @override
  String toString() =>
      '${distance.label} $time on ${date.year}-${date.month}-${date.day}';

  Map<String, dynamic> toJson() => {
        'distance': distance.name,
        'seconds': time.inSeconds,
        'date': date.toIso8601String(),
        // Absent rather than null, so an existing install's stored value is
        // unchanged by adding the field.
        if (averageHr != null) 'averageHr': averageHr,
      };

  static RaceResult fromJson(Map<String, dynamic> json) => RaceResult(
        distance: RaceDistance.values.firstWhere(
          (d) => d.name == json['distance'],
          orElse: () => RaceDistance.k10,
        ),
        time: Duration(seconds: (json['seconds'] as num).toInt()),
        date: DateTime.parse(json['date'] as String),
        averageHr: (json['averageHr'] as num?)?.toInt(),
      );
}

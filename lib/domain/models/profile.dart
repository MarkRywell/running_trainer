/// The runner's profile, captured during onboarding.
library;

enum Gender { female, male, other, preferNotToSay }

/// A value that distinguishes "not supplied" from "supplied as null".
///
/// Dart's null-safety gives one `null`, and `copyWith` needs two different
/// meanings from it. This is the smallest thing that carries both, and it is why
/// `RunnerProfile.copyWith` takes wrappers rather than bare nullable fields.
class Optional<T> {
  const Optional(this.value);

  final T? value;
}

class RunnerProfile {
  const RunnerProfile({
    required this.name,
    required this.age,
    required this.gender,
    required this.monthsRunning,
    required this.daysPerWeek,
    this.heightCm,
    this.weightKg,
    this.estimatedWeeklyKm,
  });

  final String name;
  final int age;
  final Gender gender;

  /// How long the runner has been running regularly, in months.
  final int monthsRunning;

  /// How many days per week they currently run.
  final int daysPerWeek;

  final double? heightCm;
  final double? weightKg;

  /// Current weekly volume, in km. Optional — used to decide the training
  /// path, and to seed the first week of a generated plan.
  final double? estimatedWeeklyKm;

  /// Returns a copy with the given fields replaced.
  ///
  /// The three optional fields take a **wrapper** rather than a bare `double?`,
  /// so an omitted argument means "leave alone" and an explicit
  /// `clearHeightCm()` means "set to null". A plain `?? this.x` cannot express
  /// that difference, which means a form can set a value but never clear one —
  /// and a field the runner has explicitly emptied is not the same as a field
  /// they never filled in.
  RunnerProfile copyWith({
    String? name,
    int? age,
    Gender? gender,
    int? monthsRunning,
    int? daysPerWeek,
    Optional<double>? heightCm,
    Optional<double>? weightKg,
    Optional<double>? estimatedWeeklyKm,
  }) {
    return RunnerProfile(
      name: name ?? this.name,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      monthsRunning: monthsRunning ?? this.monthsRunning,
      daysPerWeek: daysPerWeek ?? this.daysPerWeek,
      heightCm: heightCm == null ? this.heightCm : heightCm.value,
      weightKg: weightKg == null ? this.weightKg : weightKg.value,
      estimatedWeeklyKm: estimatedWeeklyKm == null
          ? this.estimatedWeeklyKm
          : estimatedWeeklyKm.value,
    );
  }

  /// `copyWith` with the optional measurements cleared.
  RunnerProfile cleared({
    bool height = false,
    bool weight = false,
    bool weeklyKm = false,
  }) =>
      copyWith(
        heightCm: height ? const Optional(null) : null,
        weightKg: weight ? const Optional(null) : null,
        estimatedWeeklyKm: weeklyKm ? const Optional(null) : null,
      );

  /// Body mass index, or null if height/weight were not supplied.
  double? get bmi {
    final h = heightCm;
    final w = weightKg;
    if (h == null || w == null || h <= 0) return null;
    final m = h / 100;
    return w / (m * m);
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'age': age,
        'gender': gender.name,
        'monthsRunning': monthsRunning,
        'daysPerWeek': daysPerWeek,
        'heightCm': heightCm,
        'weightKg': weightKg,
        'estimatedWeeklyKm': estimatedWeeklyKm,
      };

  static RunnerProfile fromJson(Map<String, dynamic> json) => RunnerProfile(
        name: json['name'] as String? ?? 'Runner',
        age: (json['age'] as num?)?.toInt() ?? 30,
        gender: Gender.values.firstWhere(
          (g) => g.name == json['gender'],
          orElse: () => Gender.preferNotToSay,
        ),
        monthsRunning: (json['monthsRunning'] as num?)?.toInt() ?? 0,
        daysPerWeek: (json['daysPerWeek'] as num?)?.toInt() ?? 3,
        heightCm: (json['heightCm'] as num?)?.toDouble(),
        weightKg: (json['weightKg'] as num?)?.toDouble(),
        estimatedWeeklyKm: (json['estimatedWeeklyKm'] as num?)?.toDouble(),
      );

  /// Value equality.
  ///
  /// `ProfileEditor.didUpdateWidget` guards its resync with
  /// `widget.value != old.value`, and that comment says the guard is there so
  /// "every keystroke" does not reset the field being typed into. **Without this
  /// the guard is an identity comparison and does the exact opposite**: a form
  /// emits a new profile on every keystroke, the parent rebuilds, the instances
  /// differ, and all five text fields are reseeded under the user's hands.
  ///
  /// It was invisible for the *name* — a name re-formats to itself — and would
  /// bite the fields that normalise, the same way it bit the goal editor's finish
  /// time. This is a value object with a `copyWith`; identity was never the
  /// semantics anyone wanted.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RunnerProfile &&
          other.name == name &&
          other.age == age &&
          other.gender == gender &&
          other.monthsRunning == monthsRunning &&
          other.daysPerWeek == daysPerWeek &&
          other.heightCm == heightCm &&
          other.weightKg == weightKg &&
          other.estimatedWeeklyKm == estimatedWeeklyKm;

  @override
  int get hashCode => Object.hash(
        name,
        age,
        gender,
        monthsRunning,
        daysPerWeek,
        heightCm,
        weightKg,
        estimatedWeeklyKm,
      );
}

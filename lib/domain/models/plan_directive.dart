/// A change to the plan that the runner has explicitly agreed to.
///
/// This exists so that adaptation is always a *proposal*, never a silent
/// rewrite. The app's premise is "never too hard", and a plan that quietly
/// changes what it asked for undermines that — the runner has to see the
/// reasoning and agree. So nothing in here is applied automatically; a
/// directive only exists because [CoachProposal] was accepted.
///
/// Passed into `generate()` as an explicit input, so the plan stays a pure
/// function of its inputs.
library;

class PlanDirective {
  const PlanDirective({
    this.capVolume = false,
    this.targetDaysPerWeek,
    this.suppressQuality = false,
  });

  /// Hold weekly volume flat from the first incomplete week onward.
  ///
  /// Weeks already completed keep the shape they were built with; only the
  /// future is held. The past is not rewritten.
  final bool capVolume;

  /// Override the number of training days. Null means "no change".
  ///
  /// Clamped to a sensible range by the caller. Three is the floor: below that
  /// the habit the plan is meant to be building stops existing.
  final int? targetDaysPerWeek;

  /// Remove the hard sessions, keeping everything else as planned.
  ///
  /// The answer to "my tempo is too much" when the long runs and easy days are
  /// fine. `capVolume` cannot distinguish those two cases, because one difficulty
  /// number for a week cannot say which session hurt — so it flattens the whole
  /// block when only the quality work needed dropping.
  ///
  /// This only ever makes a week *easier*: it replaces hard sessions with easy
  /// ones, which cannot push the 80/20 split the wrong way. The beginner base
  /// block is a proven zero-quality plan, so the shape is known to be valid.
  final bool suppressQuality;

  bool get isEmpty =>
      !capVolume && targetDaysPerWeek == null && !suppressQuality;

  bool get isNotEmpty => !isEmpty;

  PlanDirective copyWith({
    bool? capVolume,
    int? targetDaysPerWeek,
    bool? suppressQuality,
    bool clearDays = false,
  }) {
    return PlanDirective(
      capVolume: capVolume ?? this.capVolume,
      targetDaysPerWeek:
          clearDays ? null : (targetDaysPerWeek ?? this.targetDaysPerWeek),
      suppressQuality: suppressQuality ?? this.suppressQuality,
    );
  }

  /// A human-readable account of what is in force, for the review screen.
  List<String> get summary => [
        if (capVolume)
          'Volume is being held flat — the plan will not increase your '
              'weekly distance until you say so.',
        if (targetDaysPerWeek != null)
          'Training is set to $targetDaysPerWeek days a week.',
        if (suppressQuality)
          'The hard sessions have been removed. Everything else runs as planned.',
      ];

  Map<String, dynamic> toJson() => {
        'capVolume': capVolume,
        if (targetDaysPerWeek != null) 'targetDaysPerWeek': targetDaysPerWeek,
        if (suppressQuality) 'suppressQuality': suppressQuality,
      };

  static PlanDirective fromJson(Map<String, dynamic> json) => PlanDirective(
        capVolume: json['capVolume'] == true,
        targetDaysPerWeek: (json['targetDaysPerWeek'] as num?)?.toInt(),
        suppressQuality: json['suppressQuality'] == true,
      );
}

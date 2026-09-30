/// Turning a scattered set of race results into one usable fitness picture.
library;

import '../models/race.dart';
import 'riiegel.dart';
import 'vdot.dart';

/// How old a race may be and still be treated as current.
const int freshnessWindowDays = 183; // ~6 months

class FitnessAssessment {
  const FitnessAssessment({
    required this.races,
    required this.anchor,
    required this.equivalents,
    required this.vdot,
    required this.notes,
    required this.hasFreshRace,
  });

  /// Every race supplied, newest first.
  final List<RaceResult> races;

  /// The race everything else is derived from: the longest one recent enough
  /// to trust. Null when the runner supplied no races at all.
  final RaceResult? anchor;

  /// Equivalent times at every supported distance, derived from [anchor].
  final Map<RaceDistance, Duration> equivalents;

  /// VDOT implied by [anchor], or null when outside the calibrated range.
  final double? vdot;

  /// Data-quality notes to surface in the UI. These are shown rather than
  /// silently assumed — a runner should know when the plan is built on a
  /// two-year-old result.
  final List<String> notes;

  /// True if [anchor] falls inside [freshnessWindowDays].
  final bool hasFreshRace;

  bool get hasData => anchor != null;

  /// True when VDOT exists and is inside the calibrated range.
  bool get hasSupportedVdot => vdot != null && isVdotSupported(vdot!);

  Duration? equivalentTo(RaceDistance d) => equivalents[d];
}

/// Picks an anchor race and derives equivalent times across all distances.
///
/// Only one good recent race is actually needed: Riegel is invertible, so the
/// other three distances follow from it. Asking the runner for all four is
/// still worth doing, but completeness is not the point — recency is.
FitnessAssessment assessFitness(List<RaceResult> races, DateTime now) {
  if (races.isEmpty) {
    return const FitnessAssessment(
      races: [],
      anchor: null,
      equivalents: {},
      vdot: null,
      notes: [],
      hasFreshRace: false,
    );
  }

  final sorted = [...races]..sort((a, b) => b.date.compareTo(a.date));
  final notes = <String>[];

  final fresh = sorted.where((r) => r.ageInDays(now) <= freshnessWindowDays).toList();
  final hasFreshRace = fresh.isNotEmpty;

  final pool = hasFreshRace ? fresh : sorted;
  if (!hasFreshRace) {
    final age = pool.first.ageInDays(now);
    notes.add(
      'Your most recent result is $age days old. Everything below is based on it, '
      'so treat the paces as a starting point and adjust by feel.',
    );
  } else {
    // Results outside the freshness window are dropped so a stale PB cannot
    // quietly inflate the plan. But a runner who supplied a 1:56 half marathon
    // and watched it shape nothing deserves to be told rather than left to
    // wonder what happened to it.
    final stale = sorted
        .where((r) => r.ageInDays(now) > freshnessWindowDays)
        .toList();
    if (stale.isNotEmpty) {
      final one = stale.length == 1;
      notes.add(
        'Not used: your ${stale.map((r) => r.distance.label).join(' and ')} '
        '${one ? 'result is' : 'results are'} more than '
        '${freshnessWindowDays ~/ 30} months old, so ${one ? 'it is' : 'they are'} '
        'treated as out of date. Recent form is the safer basis for your paces.',
      );
    }
  }

  // Longest recent race is the most useful anchor: it involves the least
  // extrapolation, and it reflects endurance as well as speed.
  final byDistanceDesc = [...pool]
    ..sort((a, b) {
      final byDistance = b.distance.metres.compareTo(a.distance.metres);
      return byDistance != 0 ? byDistance : b.date.compareTo(a.date);
    });
  final anchor = byDistanceDesc.first;

  // A marathon is the best anchor of all; say so when we have it.
  if (anchor.distance == RaceDistance.marathon) {
    notes.add('Marathon result used as the anchor — the least extrapolation.');
  }

  final vdot = vdotFor(anchor.distance, anchor.time);
  if (vdot == null) {
    notes.add(
      'This result is outside the range where the VDOT model is reliable, so '
      'paces are derived from your race times directly rather than a fitness score.',
    );
  } else if (!hasFreshRace) {
    notes.add('VDOT ${vdot.round()} from a stale result — it is a floor, not a ceiling.');
  }

  notes.addAll(_heartRateNotes(fresh));

  // A time the runner actually ran at a distance is a *fact* about that
  // distance. A Riegel projection from a different race is a guess about it,
  // and the guess must never be allowed to contradict the measurement.
  //
  // This was a real report: a 42:02 10K five days old, and a half marathon
  // forty days old, produced an expectation of 44:01 for the 10K — the
  // projection. A goal two seconds inside the PB was then reported as a 5%
  // "hard end" stretch, which is simply false.
  //
  // `pool` is newest-first, so the first hit per distance is the most recent
  // run at that distance. Using the freshest one is the conservative choice as
  // well as the correct one: a runner's current training 10K is better evidence
  // of today than a spring PB.
  final measured = <RaceDistance, RaceResult>{};
  for (final r in pool) {
    measured.putIfAbsent(r.distance, () => r);
  }

  final equivalents = <RaceDistance, Duration>{};
  for (final d in RaceDistance.values) {
    final run = measured[d];
    if (run != null) {
      equivalents[d] = run.time;
    } else if (d == anchor.distance) {
      equivalents[d] = anchor.time;
    } else {
      equivalents[d] = predictFrom(anchor, target: d);
    }
  }

  // Disclosed rather than silently corrected: if the projection and the
  // measurement disagreed, the runner is entitled to know which one is being
  // used and why.
  final corrected = <RaceDistance>[];
  for (final d in RaceDistance.values) {
    final run = measured[d];
    if (run == null) continue;
    final projected = predictFrom(anchor, target: d);
    final drift = (projected.inSeconds - run.time.inSeconds) /
        run.time.inSeconds;
    if (drift.abs() > 0.01) corrected.add(d);
  }
  if (corrected.isNotEmpty) {
    final one = corrected.length == 1;
    notes.add(
      'Your ${corrected.map((d) => d.label).join(' and ')} ${one ? 'time is' : 'times are'} '
      'taken from a ${one ? 'race' : 'set of races'} you have actually run, not '
      'projected from your ${anchor.distance.label}. Where a projection would '
      'have said slower, we have used the time you ran.',
    );
  }

  return FitnessAssessment(
    races: sorted,
    anchor: anchor,
    equivalents: equivalents,
    vdot: vdot,
    notes: notes,
    hasFreshRace: hasFreshRace,
  );
}

/// Plausible average heart-rate range per race, in bpm.
///
/// Wide on purpose. These are **error bounds, not zone boundaries** — their only
/// job is to catch a mistyped digit, and they must never be mistaken for a
/// statement about training intensity. A genuine outlier on a hot day or with
/// poor sleep lands inside these bounds, and rightly is not flagged.
const Map<RaceDistance, (int, int)> _plausibleHr = {
  RaceDistance.k5: (130, 200),
  RaceDistance.k10: (125, 198),
  RaceDistance.half: (115, 190),
  RaceDistance.marathon: (100, 185),
};

/// Notes about heart rates recorded against races.
///
/// Everything here is a disclosure or an error check. None of it reaches
/// `vdotFor`, `riiegel` or `zoneAnchorPace` — see
/// `test/domain/heart_rate_guard_test.dart`, which fails if that ever changes.
List<String> _heartRateNotes(List<RaceResult> races) {
  final notes = <String>[];

  // A set where only some races carry a heart rate is more misleading than one
  // with none at all: it looks like the others were forgotten rather than
  // deliberately skipped, and two devices rarely agree.
  final withHr = races.where((r) => r.hasHr).length;
  if (withHr > 0 && withHr < races.length) {
    notes.add(
      'Some of your results have a heart rate and some do not. If they came from '
      'different devices they are not the same measurement, so none of them '
      'change the plan — they are recorded for your reference only.',
    );
  }

  for (final r in races) {
    final hr = r.averageHr;
    if (hr == null) continue;
    final bounds = _plausibleHr[r.distance];
    if (bounds == null) continue;
    if (hr < bounds.$1 || hr > bounds.$2) {
      notes.add(
        'Your ${r.distance.label} average heart rate is recorded as $hr bpm, which '
        'is outside what that distance normally produces. It is probably worth '
        'checking for a typo. It has not been used to build anything.',
      );
    }
  }

  return notes;
}

/// End-to-end guards for the two disclosure fixes.
///
/// Both are the same class of fault: the plan behaves correctly and the runner
/// is not told, so a correct plan reads as a broken one. Found by reading real
/// reports, not by a failing test — which is why these exist as assertions
/// rather than as a code change that needed justifying.
///
/// Each test below was verified to fail with its own fix removed.
library;

import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/plan_directive.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

/// A trained runner: two years of running, real race data, a stated weekly
/// volume. Every fixture here is on the trained path, because the disclosures
/// are about a periodised plan and the beginner base block is a different shape.
RunnerProfile trained({
  required double weeklyKm,
  int months = 30,
  int days = 4,
}) =>
    RunnerProfile(
      name: 'Sam',
      age: 28,
      gender: Gender.preferNotToSay,
      monthsRunning: months,
      daysPerWeek: days,
      estimatedWeeklyKm: weeklyKm,
    );

List<RaceResult> races() => [
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 45),
        date: DateTime(2026, 8, 1),
      ),
      RaceResult(
        distance: RaceDistance.half,
        time: const Duration(hours: 1, minutes: 45),
        date: DateTime(2026, 8, 20),
      ),
    ];

/// A goal [weeksOut] from the block's start.
///
/// The date is what sets the block length, and block length is what these tests
/// are about — a fixed far-future date silently gives every block the same shape
/// and the short-block assertions stop testing anything. The default is 15 weeks
/// out, which is long enough that every goal block earns a 3-week peak.
GoalRace goalFor(int weeksOut, RaceDistance d) => GoalRace(
      distance: d,
      date: DateTime(2026, 9, 28).add(Duration(days: 7 * weeksOut)),
      finishTimeGoal: const Duration(hours: 1, minutes: 40),
      daysPerWeek: 4,
    );

TrainingPlan plan({
  required double weeklyKm,
  int months = 30,
  RaceDistance goalDistance = RaceDistance.half,
  bool withGoal = true,
  int goalWeeksOut = 15,
  PlanDirective directive = const PlanDirective(),
}) =>
    generate(
      profile: trained(weeklyKm: weeklyKm, months: months),
      races: races(),
      goal: withGoal ? goalFor(goalWeeksOut, goalDistance) : null,
      startDate: DateTime(2026, 9, 28),
      directive: directive,
    );

bool mentionsCeiling(TrainingPlan p) =>
    p.flags.any((f) => f.title.contains('reached the volume'));

void main() {
  group('a capped plan says so out loud', () {
    // The reported case: 45 km a week, four days, a half in January. The plan
    // peaks at 45 x 1.35 = 60.75 and then holds there for weeks. Every number
    // on screen is correct and none of them explain the flatness, so the plan
    // reads as though it has lost interest.
    test('a runner held at the ceiling is told why', () {
      final p = plan(weeklyKm: 45);
      expect(
        mentionsCeiling(p),
        isTrue,
        reason: 'the plan holds at ${(45 * 1.35).toStringAsFixed(1)} km and '
            'says nothing about it',
      );
    });

    test('the explanation names the ceiling and the arithmetic behind it', () {
      final flag = plan(weeklyKm: 45)
          .flags
          .firstWhere((f) => f.title.contains('reached the volume'));
      expect(flag.severity, FlagSeverity.info);
      expect(flag.detail, contains('45'), reason: 'their current weekly volume');
      expect(
        flag.detail,
        contains('61'),
        reason: 'the ceiling, rounded for display: 45 x 1.35 = 60.75',
      );
    });

    test('it is disclosure, not a warning about the runner', () {
      // The plan is behaving correctly. Nothing here is the runner's fault and
      // nothing needs fixing, so a `caution` would be telling them their plan is
      // wrong when it is right.
      final flag = plan(weeklyKm: 45)
          .flags
          .firstWhere((f) => f.title.contains('reached the volume'));
      expect(flag.severity, FlagSeverity.info);
    });

    test('a beginner on the base block is not given a periodisation caveat', () {
      // The base block is deliberately flat and all-easy. Its volume does not
      // "reach a ceiling" in any sense the runner would recognise, and the
      // 55 km beginner cap is a different mechanism entirely.
      expect(mentionsCeiling(plan(weeklyKm: 30, months: 6)), isFalse);
    });

    test('a volume held by an accepted proposal is not a ceiling', () {
      // Two mechanisms hold volume flat and they are not the same thing. An
      // accepted cap is the runner's own decision and already carries its own
      // explanation, so attributing it to the ceiling would be a false account
      // of why their plan stopped growing.
      expect(
        mentionsCeiling(
          plan(
            weeklyKm: 45,
            directive: const PlanDirective(capVolume: true),
          ),
        ),
        isFalse,
      );
    });

    test('a large-volume runner whose weeks are trimmed elsewhere is not told '
        'they maxed out', () {
      // The regression this file exists for. A 70 km/week runner curves toward
      // 94.5, but `enforceSafety` holds the weeks actually prescribed at 75.0 —
      // the long-run cap and 80/20 bind long before the ceiling. Judged on the
      // raw curve, this runner is told they have maxed out when they have not.
      final p = plan(weeklyKm: 70);
      final maxReported =
          p.weeks.map((w) => w.targetVolumeKm).reduce((a, b) => a > b ? a : b);
      expect(maxReported, lessThan(70 * 1.35),
          reason: 'fixture assumption: this block really is trimmed below the '
              'ceiling, at ${maxReported.toStringAsFixed(1)}');
      expect(
        mentionsCeiling(p),
        isFalse,
        reason: 'the plan never reaches its ceiling, so there is nothing to '
            'disclose — saying otherwise is the fault being guarded',
      );
    });

    test('it fires for every distance whose curve can actually reach the cap',
        () {
      // A 5K block is deliberately excluded, and the reason is worth stating
      // rather than working around: its 14 km long-run cap flattens the week at
      // about 54.6 km, well before the 60.75 km volume ceiling. The plan is
      // stopping for a different reason, so a volume-ceiling flag would be a
      // false account of why. That runner is not left silent — the long-run cap
      // is doing the flattening and the plan is being honest about that
      // separately; this assertion is only that the *volume* claim is not made.
      for (final d in [
        RaceDistance.k10,
        RaceDistance.half,
        RaceDistance.marathon,
      ]) {
        expect(
          mentionsCeiling(plan(weeklyKm: 45, goalDistance: d, goalWeeksOut: 20)),
          isTrue,
          reason: 'no ceiling disclosure for a ${d.name} block',
        );
      }
    });

    test('a 5K block is not told it hit a volume ceiling it never reached', () {
      // The inverse case, and it is a real distinction rather than a technicality.
      // Long-run cap 14 km at a 30% share bounds the week near 54.6 km, so the
      // volume ceiling at 60.75 is never the binding constraint.
      final p = plan(
        weeklyKm: 45,
        goalDistance: RaceDistance.k5,
        goalWeeksOut: 20,
      );
      final maxReported =
          p.weeks.map((w) => w.targetVolumeKm).reduce((a, b) => a > b ? a : b);
      expect(
        maxReported,
        lessThan(45 * 1.35),
        reason: 'fixture assumption: the 5K long-run cap holds this block at '
            '${maxReported.toStringAsFixed(1)}',
      );
      expect(mentionsCeiling(p), isFalse);
    });

    test('a block that touches the ceiling for one week is not a hold', () {
      // The 12-week no-goal base block tops out *at* 60.8 km but only for a
      // single week before the block ends. A peak that grazes its cap has not
      // maxed the runner out, and saying so would be the over-eager version of
      // this same disclosure.
      final p = plan(weeklyKm: 45, withGoal: false);
      final atCeiling = p.weeks
          .where((w) => (w.targetVolumeKm - 45 * 1.35).abs() <= 0.05)
          .length;
      expect(
        atCeiling,
        1,
        reason: 'fixture assumption: exactly one week sits at the ceiling',
      );
      expect(
        mentionsCeiling(p),
        isFalse,
        reason: 'one week at the cap is a peak, not a plateau',
      );
    });

    test('a block too short to reach the ceiling says nothing about one', () {
      // The reason the disclosure needs a trigger at all. A 5K taper is one week,
      // so a 9-week block spends most of its life in base and never climbs to
      // the cap. Announcing a ceiling the plan never approached is the same
      // error as hiding one it sat on.
      final p = plan(
        weeklyKm: 45,
        goalDistance: RaceDistance.k5,
        goalWeeksOut: 9,
      );
      final maxReported =
          p.weeks.map((w) => w.targetVolumeKm).reduce((a, b) => a > b ? a : b);
      expect(
        maxReported,
        lessThan(45 * 1.35),
        reason: 'fixture assumption: a 9-week 5K block tops out at '
            '${maxReported.toStringAsFixed(1)}',
      );
      expect(mentionsCeiling(p), isFalse);
    });
  });

  group('a phase does not claim a shape the block never earned', () {
    // A nine-week 10K block is told it is "building toward a peak". It is
    // closer to maintenance-plus-taper. The "Only N weeks to race day" flag
    // already says so at the plan level, so the phase labels were contradicting
    // a flag three screens away.
    int peakWeeks(TrainingPlan p) =>
        p.weeks.where((w) => w.phase == PlanPhase.peak).length;

    test('a one-or-two-week peak does not call itself the biggest weeks', () {
      // A 10-week block is the reported shape: 9 weeks is the short-runway case
      // the plan already warns about, and its peak is one week.
      final p = plan(
        weeklyKm: 45,
        goalDistance: RaceDistance.k10,
        goalWeeksOut: 10,
      );
      final peak = peakWeeks(p);
      expect(
        peak,
        lessThan(minimumWeeksToEarnPeakBlurb),
        reason: 'fixture assumption: this block is short enough that its peak '
            'is $peak week(s)',
      );
      final blurb = PlanPhase.peak.blurbFor(peak);
      expect(
        blurb,
        isNot(PlanPhase.peak.blurb),
        reason: 'a $peak-week peak is not "${PlanPhase.peak.blurb}"',
      );
      expect(blurb, isNot(contains('biggest weeks')));
    });

    test('a peak with room to earn the claim still gets it', () {
      final p = plan(weeklyKm: 45, goalDistance: RaceDistance.marathon);
      final peak = peakWeeks(p);
      expect(
        peak,
        greaterThanOrEqualTo(minimumWeeksToEarnPeakBlurb),
        reason: 'fixture assumption: a marathon peak is $peak weeks',
      );
      expect(PlanPhase.peak.blurbFor(peak), PlanPhase.peak.blurb);
    });

    test('the correction is about length, not about which phase it is', () {
      // A half block and a 10K block of the *same length* get the same peak
      // wording. If these diverged, the blurb would be describing a distance
      // rather than a duration.
      final tenK = plan(
        weeklyKm: 45,
        goalDistance: RaceDistance.k10,
        goalWeeksOut: 10,
      );
      final half = plan(
        weeklyKm: 45,
        goalDistance: RaceDistance.half,
        goalWeeksOut: 10,
      );
      expect(
        PlanPhase.peak.blurbFor(peakWeeks(tenK)),
        PlanPhase.peak.blurbFor(peakWeeks(half)),
      );
    });

    test('a short base phase is corrected and a long one is not', () {
      // The other half of the claim. "Build volume" over two weeks is a promise
      // the block cannot keep; over five it is exactly what happens.
      expect(PlanPhase.base.blurbFor(1), isNot(PlanPhase.base.blurb));
      expect(PlanPhase.base.blurbFor(2), isNot(PlanPhase.base.blurb));
      expect(
        PlanPhase.base.blurbFor(minimumWeeksToEarnBaseBlurb),
        PlanPhase.base.blurb,
      );
    });

    test('a short base phase does not claim to build volume', () {
      final blurb = PlanPhase.base.blurbFor(1);
      expect(blurb, isNot(PlanPhase.base.blurb));
      expect(blurb, contains('1 week'));
    });

    test('phases whose meaning does not depend on length are untouched', () {
      // Specific, taper, race week and the beginner base block mean the same
      // thing at one week as at four. Correcting them would be inventing a rule
      // the ladder never had.
      for (final phase in [
        PlanPhase.specific,
        PlanPhase.taper,
        PlanPhase.raceWeek,
        PlanPhase.baseBlock,
      ]) {
        expect(phase.blurbFor(1), phase.blurb, reason: phase.name);
        expect(phase.blurbFor(9), phase.blurb, reason: phase.name);
      }
    });

    test('phaseLengthIn counts every week in the phase, not just the first', () {
      // The obvious wrong implementation is a lookahead that returns 1 for a
      // week whose *next* week differs, which would make the last week of every
      // phase claim a shorter phase than it is in.
      final p = plan(weeklyKm: 45);
      for (final w in p.weeks) {
        final expected = p.weeks.where((o) => o.phase == w.phase).length;
        expect(
          w.phaseLengthIn(p),
          expected,
          reason: 'week ${w.weekNumber} (${w.phase.name})',
        );
      }
    });
  });
}

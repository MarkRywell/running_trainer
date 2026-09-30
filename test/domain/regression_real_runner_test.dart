/// Regression tests built from a real report, not a hypothetical.
///
/// The report: two years of running, three days a week, 5K 24:10, 10K 52:25
/// and a 1:56:10 half marathon. The plan came back with a **3 km long run and
/// 4.9 km easy runs** — a "long run" shorter than an easy day, on a plan for
/// someone who can run a half marathon under two hours.
///
/// Three separate faults combined to produce it, and each is pinned here so it
/// cannot come back.
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// Two years' running, three days a week, at a normal 5 km a day.
RunnerProfile reported() => const RunnerProfile(
      name: 'Sam',
      age: 34,
      gender: Gender.preferNotToSay,
      monthsRunning: 24,
      daysPerWeek: 3,
      estimatedWeeklyKm: 15,
    );

final _now = DateTime(2026, 9, 27);

List<RaceResult> reportedRaces() => [
      RaceResult(
        distance: RaceDistance.k5,
        time: const Duration(minutes: 24, seconds: 10),
        date: _now.subtract(const Duration(days: 60)),
      ),
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 52, seconds: 25),
        date: _now.subtract(const Duration(days: 2)),
      ),
      RaceResult(
        distance: RaceDistance.half,
        time: const Duration(hours: 1, minutes: 56, seconds: 10),
        date: _now.subtract(const Duration(days: 400)),
      ),
    ];

TrainingPlan reportedPlan() => generate(
      profile: reported(),
      races: reportedRaces(),
      goal: null,
      startDate: _now,
    );

/// The longest run of a week, which by definition is the long run.
double longestRun(PlanWeek w) => w.workouts
    .where((r) => r.type != WorkoutType.rest && r.distanceKm > 0)
    .fold(0.0, (m, r) => r.distanceKm > m ? r.distanceKm : m);

void main() {
  final f = assessFitness(reportedRaces(), _now);

  group('reading the reported data', () {
    test('the 10K two days ago is the anchor, not the 400-day-old half', () {
      // Correct, and worth being explicit about: a year-old half marathon is
      // outside the freshness window, so it is dropped. Using it would have made
      // the plan *more* aggressive off a stale peak.
      expect(freshnessWindowDays, lessThan(400));
      expect(f.anchor!.distance, RaceDistance.k10);
      expect(f.equivalents[RaceDistance.half],
          isNot(reportedRaces().last.time));
    });

    test('a 52:25 10K reads as roughly VDOT 38', () {
      expect(f.vdot, closeTo(38, 2));
    });

    test('the dropped half marathon is disclosed, not silently discarded', () {
      // The runner gave this number. It shaped nothing, and they are told so.
      expect(
        f.notes.any((n) => n.contains('Half marathon') && n.contains('Not used')),
        isTrue,
        reason: 'excluded results must be surfaced: ${f.notes}',
      );
    });
  });

  group('path selection', () {
    test('this athlete is on the trained path, not the beginner one', () {
      // 15 km a week is normal for three days a week. An absolute weekly
      // threshold could not tell the difference, so it misfiled a two-year
      // runner with a sub-two-hour half onto a beginner block.
      expect(isBeginnerPath(reported(), f), isFalse);
    });

    test('a genuine beginner is still on the beginner path', () {
      expect(
        isBeginnerPath(
          const RunnerProfile(
            name: 'New',
            age: 27,
            gender: Gender.preferNotToSay,
            monthsRunning: 4,
            daysPerWeek: 3,
          ),
          f,
        ),
        isTrue,
      );
    });

    test('no race data means the base path, whatever the volume', () {
      // Not a judgement about experience — the trained path reads every zone
      // off an anchor race, so without one there is nothing to derive. A
      // version of this rule that let a 12-month runner through without race
      // data made every plan built for them throw.
      const noData = FitnessAssessment(
        races: [],
        anchor: null,
        equivalents: {},
        vdot: null,
        notes: [],
        hasFreshRace: false,
      );
      expect(
        isBeginnerPath(
          trainedProfile(monthsRunning: 40, daysPerWeek: 3, weeklyKm: 24),
          noData,
        ),
        isTrue,
      );
    });
  });

  group('the long run is the long run', () {
    test('no week has a long run shorter than an easy run', () {
      for (final w in reportedPlan().weeks) {
        final long = w.longRun;
        if (long == null) continue;
        final easiest = w.workouts
            .where((r) =>
                r.type == WorkoutType.easy ||
                r.type == WorkoutType.recovery)
            .fold<double>(0, (m, r) => r.distanceKm > m ? r.distanceKm : m);
        expect(
          long.distanceKm,
          greaterThanOrEqualTo(easiest),
          reason: 'week ${w.weekNumber}: long ${long.distanceKm} vs easy $easiest',
        );
      }
    });

    test('no week has any run longer than the long run', () {
      for (final w in reportedPlan().weeks) {
        if (w.longRun == null) continue;
        expect(
          longestRun(w),
          lessThanOrEqualTo(w.longRun!.distanceKm + 0.001),
          reason: 'week ${w.weekNumber} has something longer than its long run',
        );
      }
    });

    test('the long run is never shorter than it was the week before', () {
      // Cutbacks aside, a long run that shrinks for no stated reason reads as
      // a bug to the runner.
      final plan = reportedPlan();
      for (var i = 1; i < plan.weekCount; i++) {
        final previous = plan.weeks[i - 1].longRun;
        final current = plan.weeks[i].longRun;
        if (previous == null || current == null) continue;
        if (plan.weeks[i].isCutback) continue;
        expect(
          current.distanceKm,
          greaterThanOrEqualTo(previous.distanceKm - 0.01),
          reason: 'week ${plan.weeks[i].weekNumber} shrank without a cutback',
        );
      }
    });

    test('the long run stays inside the share allowed for three days', () {
      for (final w in reportedPlan().weeks) {
        final long = w.longRun;
        if (long == null || w.targetVolumeKm == 0) continue;
        expect(
          long.distanceKm,
          lessThanOrEqualTo(
            w.targetVolumeKm * maxLongRunFractionFor(runDaysIn(w)) + 0.01,
          ),
          reason: 'week ${w.weekNumber}',
        );
      }
    });

    test('the plan does not prescribe more than the runner already runs', () {
      // They said 15 km a week. The first week must not be a jump beyond that.
      final first = reportedPlan().weeks.first;
      expect(
        first.targetVolumeKm,
        lessThanOrEqualTo(15 * 1.35 + 0.01),
        reason: 'the volume ceiling is current + 35%',
      );
    });
  });

  group('the share rules themselves', () {
    test('a three-day week cannot give the long run 30%', () {
      // At 30%, the other 70% splits across two days at 35% each. The long run
      // is arithmetically forced to be the shortest run of the week.
      expect(longRunShare(3), greaterThan(0.30));
      expect(0.70 / 2, greaterThan(0.30));
    });

    test('the long run share always beats an easy day share', () {
      for (var days = 2; days <= 7; days++) {
        final share = longRunShare(days);
        final easyShare = (1 - share) / (days - 1);
        expect(
          share,
          greaterThanOrEqualTo(easyShare),
          reason: '$days days: long $share vs easy $easyShare',
        );
      }
    });

    test('the hard cap always sits above the target share', () {
      // When it did not, enforcement trimmed the long run straight back and
      // undid the generator. This is the coupling that caused the bug.
      for (var days = 2; days <= 7; days++) {
        expect(
          maxLongRunFractionFor(days),
          greaterThanOrEqualTo(longRunShare(days)),
          reason: '$days days',
        );
      }
    });
  });
}

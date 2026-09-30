/// What a goal race does to a plan, and — more importantly — what it must not do.
///
/// **The report.** A runner set a 21K goal (1:32:00, January 2027), saw no
/// change to their sessions, removed the goal, and again saw no change. Same
/// paces, same distances. It looked broken.
///
/// **Two of the three things they noticed are correct, and one was a bug.**
///
/// - **Paces never change with the goal.** This is deliberate, and it is the
///   zone-anchor fix: training intensity comes from what the runner can
///   demonstrably do today, never from the pace they hope to hold in January.
///   A goal that raised the Tuesday session above current fitness is exactly
///   how a stretch goal produces a plan that is too hard.
/// - **The first four weeks are identical with and without a goal.** Both
///   blocks open with the same base build. The goal's real effects are the
///   block length and everything from week 5 on.
/// - **But the notes were duplicated.** "About your race data" appeared twice,
///   stacked, because every note became its own flag with the same title. That
///   one is a genuine bug and is what made the screen look broken.
///
/// The runner's own data, from the same report, with ages at 28 Sep 2026:
/// 5K 19:50 (62d), 10K 42:02 (243d), 21K 1:35:34 (31d), 42K 3:23:26 (335d).
/// Only the 5K and the half are inside the 183-day freshness window, so the
/// **half is the anchor** — not the marathon, which is discarded as stale.
library;

import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 9, 28);

const _profile = RunnerProfile(
  name: 'Sam',
  age: 28,
  gender: Gender.preferNotToSay,
  monthsRunning: 36,
  daysPerWeek: 4,
  estimatedWeeklyKm: 50,
);

List<RaceResult> _races() => [
      RaceResult(
        distance: RaceDistance.k5,
        time: const Duration(minutes: 19, seconds: 50),
        date: _now.subtract(const Duration(days: 62)),
      ),
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 42, seconds: 2),
        date: _now.subtract(const Duration(days: 243)),
      ),
      RaceResult(
        distance: RaceDistance.half,
        time: const Duration(hours: 1, minutes: 35, seconds: 34),
        date: _now.subtract(const Duration(days: 31)),
      ),
      RaceResult(
        distance: RaceDistance.marathon,
        time: const Duration(hours: 3, minutes: 23, seconds: 26),
        date: _now.subtract(const Duration(days: 335)),
      ),
    ];

final _goal = GoalRace(
  distance: RaceDistance.half,
  date: DateTime(2027, 1, 24),
  finishTimeGoal: const Duration(hours: 1, minutes: 32),
  daysPerWeek: 4,
);

TrainingPlan _plan({GoalRace? goal}) => generate(
      profile: _profile,
      races: _races(),
      goal: goal,
      startDate: _now,
    );

void main() {
  final withGoal = _plan(goal: _goal);
  final withoutGoal = _plan();

  group('a goal must not change the paces', () {
    test('every zone is identical with and without a goal', () {
      // The zone-anchor principle, pinned at the plan level rather than only in
      // the zones unit test. A goal that speeds up training intensity is the
      // regression this whole rule exists to prevent, and "the paces moved" is
      // the exact symptom a runner would report as "it got harder when I added
      // a race".
      expect(withGoal.paces.easy, withoutGoal.paces.easy);
      expect(withGoal.paces.recovery, withoutGoal.paces.recovery);
      expect(withGoal.paces.threshold, withoutGoal.paces.threshold);
      expect(withGoal.paces.interval, withoutGoal.paces.interval);
      expect(withGoal.paces.marathon, withoutGoal.paces.marathon);
    });

    test('and the paces are the ones the half marathon implies', () {
      // 1:35:34 half is the only fresh long race, so the ladder must track it
      // and not the stale marathon.
      expect(withGoal.paces.threshold.secPerKm.round(), 248);
    });
  });

  group('a goal does change the block', () {
    test('it is longer, because it has to reach the race', () {
      expect(
        withGoal.weekCount,
        greaterThan(withoutGoal.weekCount),
        reason: 'a block that ends in a taper needs weeks the base block does not',
      );
    });

    test('it ends in a taper and a race week', () {
      final phases = withGoal.weeks.map((w) => w.phase).toList();
      expect(phases, contains(PlanPhase.taper));
      expect(phases.last, PlanPhase.raceWeek);
      expect(
        withoutGoal.weeks.map((w) => w.phase),
        isNot(contains(PlanPhase.taper)),
        reason: 'with no race there is nothing to taper for',
      );
    });

    test('the goal block is not just the base block with a taper bolted on', () {
      // The discriminator used to be "the base block has no intervals", and a
      // base block with no goal race now *does* have them — twelve identical
      // tempos was the actual defect, not a safety property. So the difference
      // is no longer the presence of a session type but the shape: the goal
      // block runs a peak, a taper and a race, and tapers its volume.
      final types = withGoal.weeks.expand((w) => w.workouts).map((k) => k.type);
      expect(types, contains(WorkoutType.intervals));

      expect(withGoal.weeks.map((w) => w.phase), contains(PlanPhase.peak));
      expect(
        withoutGoal.weeks.map((w) => w.phase),
        isNot(contains(PlanPhase.peak)),
        reason: 'with no race there is nothing to peak for',
      );

      // Both blocks carry repetition work — a no-goal runner on 4 days used to
      // get twelve tempos and no sets at all, which is what this asserts against.
      final baseTypes =
          withoutGoal.weeks.expand((w) => w.workouts).map((k) => k.type);
      expect(baseTypes, contains(WorkoutType.intervals));
    });

    test('the race week actually prescribes the race', () {
      final last = withGoal.weeks.last;
      expect(
        last.workouts.map((w) => w.type),
        contains(WorkoutType.race),
      );
    });
  });

  group('the shared base prefix is deliberate, not accidental', () {
    test('the opening weeks match, and the divergence point is recorded', () {
      // A runner looking at week 1 sees no difference, which is what generated
      // the report. That is acceptable — but only because the blocks genuinely
      // share a base opening. If a future change makes week 1 differ, this
      // test is the thing that should be looked at and consciously updated,
      // rather than the change landing silently.
      var firstDivergence = -1;
      for (var i = 0; i < withoutGoal.weekCount; i++) {
        final a = withoutGoal.weeks[i];
        final b = withGoal.weeks[i];
        final same = a.phase == b.phase &&
            a.targetVolumeKm == b.targetVolumeKm &&
            a.workouts.length == b.workouts.length;
        if (!same) {
          firstDivergence = i;
          break;
        }
      }
      expect(
        firstDivergence,
        4,
        reason: 'weeks 1-4 are the shared base build; the goal block diverges '
            'from week 5. If this moved, the "nothing changed" report is back.',
      );
    });
  });

  group('notes are one card, not one card each', () {
    test('no two flags share a title', () {
      // The regression: every note used to become its own flag titled "About
      // your race data", so this runner saw that title twice, stacked, and
      // concluded the app had duplicated itself.
      for (final plan in [withGoal, withoutGoal]) {
        final titles = plan.flags.map((f) => f.title).toList();
        expect(
          titles.toSet().length,
          titles.length,
          reason: 'duplicate flag titles: $titles',
        );
      }
    });

    test('and every note still reaches the runner', () {
      final data = withGoal.flags.where((f) => f.title == 'About your race data');
      expect(data, hasLength(1));
      final detail = data.single.detail;
      expect(detail, contains('Not used'), reason: 'the stale-race note survives');
      expect(
        detail,
        contains('actually run'),
        reason: 'and so does the measured-beats-projected note',
      );
    });
  });

  group('what the stale data means for this runner', () {
    test('the discarded races are named, so the exclusion is not silent', () {
      final data =
          withGoal.flags.firstWhere((f) => f.title == 'About your race data');
      expect(data.detail, contains('10K'));
      expect(data.detail, contains('Marathon'));
    });

    test('the half is the anchor, not the longer marathon', () {
      // "Longest race wins" only applies *within* the freshness window. An
      // 11-month-old marathon loses to a 1-month-old half, which is the opposite
      // of what the anchor comment suggests at a glance.
      final halfAnchored = withoutGoal.paces.threshold.secPerKm;
      final marathonOnly = generate(
        profile: _profile,
        races: [
          RaceResult(
            distance: RaceDistance.marathon,
            time: const Duration(hours: 3, minutes: 23, seconds: 26),
            date: _now.subtract(const Duration(days: 335)),
          ),
        ],
        goal: _goal,
        startDate: _now,
      );
      expect(
        (marathonOnly.paces.threshold.secPerKm - halfAnchored).abs(),
        greaterThan(1),
        reason: 'if these matched, the test would not be distinguishing '
            'which race anchors the plan',
      );
      // Worth knowing, and counter-intuitive: the anchor barely matters here.
      // The half projects to a 3:19 marathon equivalent against the real 3:23,
      // so the training ladder moves by only ~4 s/km. The stale data costs this
      // runner almost nothing in *paces*; what it costs them is the 10K
      // expectation, which falls back to a projection (43:18) because their
      // 42:02 PB is 8 months old.
      expect(halfAnchored.round(), 248);
      expect(marathonOnly.paces.threshold.secPerKm.round(), 252);
    });
  });
}

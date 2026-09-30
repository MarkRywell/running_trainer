/// A prediction must never contradict a measurement.
///
/// **The report.** A runner set a 10K goal of **42:00** with a PB of **42:02**
/// from a few days earlier — a two-second target, i.e. no improvement at all.
/// The app answered:
///
/// > On your race times, you would expect around 44:00 for a 10K. 5% is at the
/// > hard end of what a training block delivers for this distance.
///
/// Both halves of that are wrong. The expectation was not derived from "your
/// race times" at the 10K at all — it was a Riegel projection from a marathon,
/// and the runner's actual 10K was sitting in the data unused. And a 0.1%
/// improvement was reported as a 5% stretch.
///
/// **The cause.** `assessFitness` picks the *longest* fresh race as the anchor,
/// then builds every equivalent by projecting from it. That is a defensible rule
/// for choosing an anchor, but it must not then be allowed to overwrite a time
/// the runner has actually run at that distance. Riegel going *down* in distance
/// is pessimistic and carries no conservative margin (the margin only applies
/// when stretching out), so a marathon anchor systematically overstates short
/// distances — 3:23:26 projects to 44:12 at 10K against a real 42:02.
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/riiegel.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 9, 27);

/// The reported race set: a recent 10K PB and a marathon that anchors the plan.
List<RaceResult> _races() => [
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 42, seconds: 2),
        date: _now.subtract(const Duration(days: 3)),
      ),
      RaceResult(
        distance: RaceDistance.marathon,
        time: const Duration(hours: 3, minutes: 23, seconds: 26),
        date: _now.subtract(const Duration(days: 70)),
      ),
    ];

const _runner = RunnerProfile(
  name: 'Sam',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 36,
  daysPerWeek: 4,
  estimatedWeeklyKm: 35,
);

GoalRace _goal() => GoalRace(
      distance: RaceDistance.k10,
      date: DateTime(2027, 1, 1),
      finishTimeGoal: const Duration(minutes: 42),
      daysPerWeek: 4,
    );

void main() {
  group('a measured time is never overwritten by a projection', () {
    test('the 10K equivalent is the 10K that was run', () {
      final f = assessFitness(_races(), _now);
      expect(
        f.equivalentTo(RaceDistance.k10),
        const Duration(minutes: 42, seconds: 2),
        reason: 'a Riegel guess about the 10K must not overrule the real 10K',
      );
    });

    test('and the expectation the goal check reads is that same 42:02', () {
      final f = assessFitness(_races(), _now);
      final e = currentExpectation(
        fitness: f,
        distance: RaceDistance.k10,
      );
      expect(e.time, const Duration(minutes: 42, seconds: 2));
    });

    test('it is never slower than the freshest result at that distance', () {
      // The general form of the rule, checked across distances: for every
      // distance the runner has a fresh result for, the equivalent is that
      // result. This is the assertion that catches a future anchor change
      // reintroducing the overwrite, whatever the anchor happens to be.
      for (final d in RaceDistance.values) {
        final freshAtDistance = _races()
            .where((r) => r.distance == d && r.ageInDays(_now) <= freshnessWindowDays)
            .toList();
        if (freshAtDistance.isEmpty) continue;
        final fastestOrLatest = freshAtDistance.last; // _races() is newest first
        final f = assessFitness(_races(), _now);
        expect(
          f.equivalentTo(d),
          fastestOrLatest.time,
          reason: 'the ${d.label} equivalent must be the ${d.label} that was run',
        );
      }
    });

    test('a distance with no result of its own is still projected', () {
      // The fix must not disable Riegel — it is still how a 5K or a marathon
      // equivalent is obtained when the runner has never run that distance.
      final f = assessFitness(_races(), _now);
      expect(
        f.equivalentTo(RaceDistance.k5),
        isNotNull,
        reason: 'a runner with no 5K still needs a 5K equivalent',
      );
      expect(
        f.equivalentTo(RaceDistance.k5)!,
        lessThan(f.equivalentTo(RaceDistance.marathon)!),
        reason: 'and it must be faster than the marathon, not slower',
      );
    });

    test('the marathon anchor is still the marathon', () {
      // Selecting a *different* anchor is a separate decision with a separate
      // blast radius. This test is here to say that the equivalents fix did not
      // quietly make that change.
      final f = assessFitness(_races(), _now);
      expect(f.anchor?.distance, RaceDistance.marathon);
      expect(f.equivalentTo(RaceDistance.marathon),
          const Duration(hours: 3, minutes: 23, seconds: 26));
    });
  });

  group('the goal warning it produced', () {
    test('a goal two seconds inside the PB is not a stretch goal', () {
      final flags = validate(
        profile: _runner,
        fitness: assessFitness(_races(), _now),
        goal: _goal(),
        today: _now,
      );
      final stretch = flags.where(
        (f) => f.title.contains('stretch') ||
            f.title.contains('Beyond what this block'),
      );
      expect(
        stretch,
        isEmpty,
        reason: '42:00 against a 42:02 PB is 0.1%, not "5% at the hard end"',
      );
    });

    test('no flag quotes the projected time back at the runner', () {
      // The reported wording was "you would expect around 44 for a 10K". Note
      // that the app's time formatter prints 44:13 as plain "44" — it only
      // carries seconds when the time runs past an hour — so the wrong value is
      // easy to miss when eyeballing the output. This derives the wrong number
      // rather than hardcoding it, so it survives the data being retuned.
      final f = assessFitness(_races(), _now);
      final anchor = f.anchor!;
      final wrong = predictFrom(anchor, target: RaceDistance.k10);
      final wrongText = '${wrong.inMinutes}';

      final flags = validate(
        profile: _runner,
        fitness: f,
        goal: _goal(),
        today: _now,
      );
      for (final flag in flags) {
        expect(
          flag.detail,
          isNot(contains('around $wrongText ')),
          reason: 'flag "${flag.title}" quotes the projected $wrongText, '
              'not the ${f.equivalentTo(RaceDistance.k10)} that was run',
        );
      }
    });

    test('a genuinely ambitious goal is still flagged', () {
      // The warning must not have been silenced — only corrected. 41:00 is 2.5%
      // inside a 42:02 PB, which is inside `typical`; 38:00 is 9.5%, which is
      // beyond even a stretch.
      final flags = validate(
        profile: _runner,
        fitness: assessFitness(_races(), _now),
        goal: GoalRace(
          distance: RaceDistance.k10,
          date: DateTime(2027, 1, 1),
          finishTimeGoal: const Duration(minutes: 38),
          daysPerWeek: 4,
        ),
        today: _now,
      );
      expect(
        flags.where((f) => f.title.contains('Beyond what this block')),
        isNotEmpty,
        reason: 'a 38:00 goal is still well beyond a training block',
      );
    });
  });

  group('disclosure', () {
    test('the runner is told a measured time beat the projection', () {
      final f = assessFitness(_races(), _now);
      expect(
        f.notes.where((n) => n.contains('actually run')),
        isNotEmpty,
        reason: 'silently swapping a projection for a measurement is not honest',
      );
    });

    test('no note when the projection and the measurement already agree', () {
      // A runner whose data is internally consistent should not be told about a
      // correction that did not happen.
      final consistent = [
        RaceResult(
          distance: RaceDistance.marathon,
          time: const Duration(hours: 3, minutes: 23, seconds: 26),
          date: _now.subtract(const Duration(days: 70)),
        ),
      ];
      final f = assessFitness(consistent, _now);
      expect(
        f.notes.where((n) => n.contains('actually run')),
        isEmpty,
        reason: 'a single race has no measurement to prefer over the projection',
      );
    });
  });
}

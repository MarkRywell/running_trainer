/// The guard for Phase 8: heart rate is an annotation, never an input.
///
/// Written before `averageHr` exists. `RaceResult` currently has no heart-rate
/// field at all, so the two plans compared here are trivially identical — which
/// is the point. The moment someone wires HR into `zoneAnchorPace` or
/// `vdotFor`, this stops being trivially true and goes red.
///
/// "Annotation only" is an intention until something enforces it.
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

const _runner = RunnerProfile(
  name: 'Sam',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 24,
  daysPerWeek: 3,
  estimatedWeeklyKm: 15,
);

GoalRace _goal() => GoalRace(
      distance: RaceDistance.marathon,
      date: testToday.add(const Duration(days: 18 * 7)),
      finishTimeGoal: const Duration(hours: 3, minutes: 30),
      daysPerWeek: 3,
    );

RaceResult _race(
  RaceDistance d,
  Duration t, {
  int daysAgo = 20,
  int? hr,
}) =>
    RaceResult(
      distance: d,
      time: t,
      date: testToday.subtract(Duration(days: daysAgo)),
      averageHr: hr,
    );

/// The same race set, with and without heart rates.
List<RaceResult> _races({required bool withHr}) => [
      _race(RaceDistance.k5, const Duration(minutes: 24, seconds: 10),
          daysAgo: 60, hr: withHr ? 172 : null),
      _race(RaceDistance.k10, const Duration(minutes: 52, seconds: 25),
          daysAgo: 20, hr: withHr ? 168 : null),
    ];

TrainingPlan _plan({required bool withHr, GoalRace? goal}) => generate(
      profile: _runner,
      races: _races(withHr: withHr),
      goal: goal,
      startDate: testToday,
    );

void main() {
  group('heart rate does not change the plan', () {
    test('the base block is identical with and without HR', () {
      final without = _plan(withHr: false);
      final with_ = _plan(withHr: true);
      expect(with_.weeks.length, without.weeks.length);
      for (var i = 0; i < without.weeks.length; i++) {
        expect(
          with_.weeks[i].targetVolumeKm,
          without.weeks[i].targetVolumeKm,
          reason: 'week ${without.weeks[i].weekNumber} volume',
        );
        expect(
          with_.weeks[i].runs.map((r) => r.distanceKm).toList(),
          without.weeks[i].runs.map((r) => r.distanceKm).toList(),
          reason: 'week ${without.weeks[i].weekNumber} sessions',
        );
      }
    });

    test('the paces are identical with and without HR', () {
      final without = _plan(withHr: false);
      final with_ = _plan(withHr: true);
      for (final zone in IntensityZone.values) {
        expect(
          with_.paces.forZone(zone).secPerKm,
          without.paces.forZone(zone).secPerKm,
          reason: '${zone.name} pace must not move',
        );
      }
    });

    test('a race block is identical with and without HR', () {
      final without = _plan(withHr: false, goal: _goal());
      final with_ = _plan(withHr: true, goal: _goal());
      expect(with_.weekCount, without.weekCount);
      for (var i = 0; i < without.weeks.length; i++) {
        expect(
          with_.weeks[i].targetVolumeKm,
          without.weeks[i].targetVolumeKm,
          reason: 'week ${without.weeks[i].weekNumber}',
        );
        expect(
          with_.weeks[i].phase,
          without.weeks[i].phase,
          reason: 'week ${without.weeks[i].weekNumber} phase',
        );
      }
    });

    test('VDOT is derived from time alone', () {
      // The anchor is the 10K either way. If HR ever entered the model, this
      // would be the first place it showed.
      final without = assessFitness(_races(withHr: false), testToday);
      final with_ = assessFitness(_races(withHr: true), testToday);
      expect(with_.vdot, without.vdot);
      expect(with_.anchor!.distance, without.anchor!.distance);
      for (final d in RaceDistance.values) {
        expect(
          with_.equivalents[d],
          without.equivalents[d],
          reason: '${d.label} equivalent must not move',
        );
      }
    });

    test('an implausible heart rate still cannot change a pace', () {
      // The sanity check is meant to flag a typo, not to be silently believed.
      // A wild number must be *reported*, never *used*.
      final sane = _plan(withHr: false);
      final insane = generate(
        profile: _runner,
        races: [
          _race(RaceDistance.k5, const Duration(minutes: 24, seconds: 10),
              daysAgo: 60, hr: 199),
          _race(RaceDistance.k10, const Duration(minutes: 52, seconds: 25),
              daysAgo: 20, hr: 205),
        ],
        goal: null,
        startDate: testToday,
      );
      expect(insane.paces.easy.secPerKm, sane.paces.easy.secPerKm);
      expect(insane.paces.threshold.secPerKm, sane.paces.threshold.secPerKm);
    });
  });

  group('a heart rate may only ever add information', () {
    test('HR can add a flag, but never removes or alters an existing one', () {
      // The premise is not "no flags change" — an HR caveat is itself a flag,
      // and that is the point of recording it. The premise is that the
      // pre-existing verdicts are untouched: HR gets a word, not a vote.
      final without = validate(
        profile: _runner,
        fitness: assessFitness(_races(withHr: false), testToday),
        goal: _goal(),
        today: testToday,
      );
      final with_ = validate(
        profile: _runner,
        fitness: assessFitness(_races(withHr: true), testToday),
        goal: _goal(),
        today: testToday,
      );
      final before = without.map((f) => f.title).toList();
      final after = with_.map((f) => f.title).toList();
      expect(
        after,
        containsAll(before),
        reason: 'every pre-existing flag must survive unchanged',
      );
      expect(after.length - before.length, lessThanOrEqualTo(1));
    });

    test('anything HR adds is informational, never a warning', () {
      // A demanding goal is an ambition, and the app builds toward it. HR is
      // only ever telling the runner something they did not know, so it must not
      // escalate into a caution or a warning.
      final with_ = validate(
        profile: _runner,
        fitness: assessFitness(_races(withHr: true), testToday),
        goal: _goal(),
        today: testToday,
      );
      final without = validate(
        profile: _runner,
        fitness: assessFitness(_races(withHr: false), testToday),
        goal: _goal(),
        today: testToday,
      );
      final added = with_.where((f) => !without.any((b) => b.title == f.title));
      for (final flag in added) {
        expect(
          flag.severity,
          FlagSeverity.info,
          reason: 'HR added "${flag.title}" at ${flag.severity}',
        );
      }
    });

    test('a heart-rate caveat never suggests a change of goal', () {
      // The goal is the runner's to set. An HR note may add a suggested date
      // for *runway*, but must not propose a different distance — that is the
      // one thing this feature is not allowed to argue for.
      final with_ = validate(
        profile: _runner,
        fitness: assessFitness(_races(withHr: true), testToday),
        goal: _goal(),
        today: testToday,
      );
      for (final flag in with_) {
        if (!flag.title.contains('bpm')) continue;
        expect(flag.suggestedDistance, isNull);
      }
    });
  });

  group('the notes a heart rate can produce', () {
    FitnessAssessment fitnessOf(List<RaceResult> races) =>
        assessFitness(races, testToday);

    List<String> notesFor(List<RaceResult> races, {GoalRace? goal}) => [
          ...fitnessOf(races).notes,
          if (goal != null)
            ...validate(
              profile: _runner,
              fitness: fitnessOf(races),
              goal: goal,
              today: testToday,
            ).map((f) => f.detail),
        ];

    test('a plausible heart rate on its own raises nothing', () {
      // Useful information that is not a problem should not read as a problem.
      final notes = notesFor(_races(withHr: true));
      expect(notes.where((n) => n.contains('bpm')), isEmpty);
    });

    test('a goal much faster than the logged effort is flagged', () {
      // 52:25 10K at 168 bpm, then a 3:20 marathon — roughly 5% faster than any
      // pace they have demonstrated.
      final notes = notesFor(
        _races(withHr: true),
        goal: GoalRace(
          distance: RaceDistance.marathon,
          date: testToday.add(const Duration(days: 18 * 7)),
          finishTimeGoal: const Duration(hours: 3, minutes: 20),
          daysPerWeek: 3,
        ),
      );
      expect(
        notes.where((n) => n.contains('168')),
        isNotEmpty,
        reason: 'a goal well beyond the logged effort should be noted: $notes',
      );
    });

    test('an out-of-band value is called a likely error', () {
      final notes = notesFor([
        _race(RaceDistance.k5, const Duration(minutes: 24, seconds: 10),
            daysAgo: 60, hr: 205),
      ]);
      expect(
        notes.any((n) => n.contains('205') && n.contains('typo')),
        isTrue,
        reason: 'a 205 bpm 5K average is a typo, not a training signal: $notes',
      );
    });

    test('a partly-recorded set is called out as inconsistent', () {
      // A wrist-only number and a chest-strap number are not the same
      // measurement, and averaging them would be worse than not using them.
      final notes = notesFor([
        _race(RaceDistance.k5, const Duration(minutes: 24, seconds: 10),
            daysAgo: 60, hr: 172),
        _race(RaceDistance.k10, const Duration(minutes: 52, seconds: 25),
            daysAgo: 20),
      ]);
      expect(
        notes.where((n) => n.contains('Some of your results')),
        isNotEmpty,
        reason: 'mixed HR presence should be disclosed: $notes',
      );
    });
  });

  group('a heart rate survives storage', () {
    test('round-trips through JSON', () {
      final original = _race(
        RaceDistance.half,
        const Duration(hours: 1, minutes: 56, seconds: 10),
        hr: 165,
      );
      final restored = RaceResult.fromJson(original.toJson());
      expect(restored.averageHr, 165);
      expect(restored.time, original.time);
      expect(restored.distance, original.distance);
    });

    test('an absent heart rate reads back as absent', () {
      final original = _race(RaceDistance.k10, const Duration(minutes: 45));
      final json = original.toJson();
      expect(json.containsKey('averageHr'), isFalse,
          reason: 'absent keys keep the stored value small');
      expect(RaceResult.fromJson(json).averageHr, isNull);
    });
  });

  group('the guard test is comparing the whole pace set', () {
    test('every zone has a distinct pace to compare', () {
      // Guards the guard: if `forZone` ever returned a constant for some zone,
      // the identity assertions above would pass without comparing anything.
      final paces = _plan(withHr: false).paces;
      final perKm = [
        for (final zone in IntensityZone.values)
          paces.forZone(zone).secPerKm,
      ];
      expect(perKm.length, IntensityZone.values.length);
      expect(
        paces.forZone(IntensityZone.easy).secPerKm,
        greaterThan(paces.forZone(IntensityZone.threshold).secPerKm),
        reason: 'easy is slower than threshold, in seconds per km',
      );
      expect(
        perKm.toSet().length,
        greaterThanOrEqualTo(5),
        reason: 'zones must not collapse onto each other',
      );
    });
  });
}

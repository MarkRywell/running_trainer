/// Reproduces the suspected cause of a trained runner being routed to the
/// beginner block (which contains no hard sessions at all).
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

const _runner = RunnerProfile(
  name: 'Sam',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 24,
  daysPerWeek: 3,
  estimatedWeeklyKm: 15,
);

List<RaceResult> _races() => [
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 52, seconds: 25),
        date: DateTime.now().subtract(const Duration(days: 2)),
      ),
    ];

/// Weeks with a hard session, out of the whole plan.
({int hard, int total}) _hardSessionCount(TrainingPlan plan) {
  var hard = 0;
  for (final w in plan.weeks) {
    if (w.workouts.any((s) => s.type == WorkoutType.tempo ||
        s.type == WorkoutType.intervals)) {
      hard++;
    }
  }
  return (hard: hard, total: plan.weekCount);
}

void main() {
  final fitness = assessFitness(_races(), DateTime.now());

  test('the reported profile is on the trained path', () {
    expect(isBeginnerPath(_runner, fitness), isFalse);
    expect(_runner.estimatedWeeklyKm, 15);
  });

  group('the beginner gate trusts one self-reported number', () {
    // Threshold for 3 days is 3 * 5 * 0.6 = 9 km.
    test('any weekly volume under 9 km demotes a two-year runner', () {
      for (final km in [1.0, 3.0, 5.0, 8.9]) {
        final p = _runner.copyWith(estimatedWeeklyKm: Optional(km));
        expect(
          isBeginnerPath(p, fitness),
          isTrue,
          reason: '$km km/week demotes someone with 2 years and a 52:25 10K',
        );
      }
    });

    test('9 km exactly is enough to stay trained', () {
      final p = _runner.copyWith(estimatedWeeklyKm: const Optional(9));
      expect(isBeginnerPath(p, fitness), isFalse);
    });
  });

  group('the consequence: no hard sessions at all', () {
    test('a demoted plan contains zero tempo or interval sessions', () {
      // The exact symptom reported: only easy runs and a long run.
      final plan = generate(
        profile: _runner.copyWith(estimatedWeeklyKm: const Optional(1)),
        races: _races(),
        goal: null,
        startDate: DateTime.now(),
      );
      expect(plan.path.label, 'Base building');
      final count = _hardSessionCount(plan);
      expect(count.hard, 0, reason: 'beginner block has no hard sessions');
    });

    test('a stray low value produces the reported Easy + Long shape', () {
      final plan = generate(
        profile: _runner.copyWith(estimatedWeeklyKm: const Optional(1)),
        races: _races(),
        goal: null,
        startDate: DateTime.now(),
      );
      for (final w in plan.weeks) {
        final titles = w.workouts
            .where((s) => s.type != WorkoutType.rest)
            .map((s) => s.type.name)
            .toList();
        expect(
          titles.where((t) => t != 'easy' && t != 'long' && t != 'strides'),
          isEmpty,
          reason: 'week ${w.weekNumber} contains $titles',
        );
      }
    });

    test('a mid-typing value is indistinguishable from a real one', () {
      // The editor emits on every keystroke, so "1" exists in the world while
      // "15" is being typed. If the runner navigates away at that moment, or the
      // field is later cleared and retyped, the low value is what is stored.
      final partial = _runner.copyWith(estimatedWeeklyKm: const Optional(1));
      final partialPlan = generate(
        profile: partial,
        races: _races(),
        goal: null,
        startDate: DateTime.now(),
      );
      expect(partialPlan.path.label, 'Base building');
      expect(_hardSessionCount(partialPlan).hard, 0);
    });
  });
}

import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 9, 30);

void main() {
  test('paces + taper text + long run accounting', () {
    final races = [
      RaceResult(distance: RaceDistance.k5,
          time: const Duration(minutes: 24, seconds: 10),
          date: now.subtract(const Duration(days: 20))),
      RaceResult(distance: RaceDistance.k10,
          time: const Duration(minutes: 52, seconds: 13),
          date: now.subtract(const Duration(days: 45))),
      RaceResult(distance: RaceDistance.half,
          time: const Duration(hours: 1, minutes: 56, seconds: 4),
          date: DateTime(2026, 8, 23)),
    ];
    final profile = RunnerProfile(name: 'Sam', age: 25,
        gender: Gender.preferNotToSay, monthsRunning: 24,
        daysPerWeek: 4, estimatedWeeklyKm: 45);
    final goal = GoalRace(distance: RaceDistance.k10,
        date: DateTime(2026, 11, 29),
        finishTimeGoal: const Duration(minutes: 51),
        daysPerWeek: 4);
    final plan = generate(
        profile: profile, races: races, goal: goal, startDate: now);
    final p = plan.paces;
    print('ZONES  interval=${p.interval.format()} threshold=${p.threshold.format()} '
          'marathon=${p.marathon.format()} easy=${p.easy.format()}');
    print('GOAL   10K 51:00 = 5:06/km');
    for (final fl in plan.flags) {
      print('FLAG [${fl.severity.name}] ${fl.title} :: ${fl.detail}');
    }
    for (final w in plan.weeks) {
      for (final s in w.runs) {
        if (s.title == 'Long run + goal-pace block') {
          print('LONG wk${w.weekNumber} ${s.distanceKm.toStringAsFixed(1)}km '
              'zone=${s.zone.name} hardFrac=${s.hardFractionOfDistance} '
              '-> hardVolume counted=${s.distanceKm * s.hardFractionOfDistance}');
        }
        if (s.title.startsWith('Goal-pace')) {
          print('TAPER wk${w.weekNumber} ${s.description}');
        }
      }
    }
  });
}

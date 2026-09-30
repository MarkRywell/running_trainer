import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';

/// A fixed reference date so tests never depend on the clock.
final testToday = DateTime(2026, 3, 2); // a Monday

/// A trained runner with a recent 10K, the common case.
RunnerProfile trainedProfile({
  int monthsRunning = 36,
  int daysPerWeek = 4,
  double? weeklyKm = 40,
  int age = 34,
}) =>
    RunnerProfile(
      name: 'Sam',
      age: age,
      gender: Gender.preferNotToSay,
      monthsRunning: monthsRunning,
      daysPerWeek: daysPerWeek,
      estimatedWeeklyKm: weeklyKm,
    );

/// Someone new to running. No race data.
RunnerProfile beginnerProfile({
  int monthsRunning = 3,
  int daysPerWeek = 3,
  double? weeklyKm = 14,
}) =>
    RunnerProfile(
      name: 'Alex',
      age: 29,
      gender: Gender.female,
      monthsRunning: monthsRunning,
      daysPerWeek: daysPerWeek,
      estimatedWeeklyKm: weeklyKm,
    );

/// A recent 10K, the most common single piece of data a runner has.
RaceResult raceK10(Duration time, {int daysAgo = 30}) => RaceResult(
      distance: RaceDistance.k10,
      time: time,
      date: testToday.subtract(Duration(days: daysAgo)),
    );

RaceResult raceMarathon(Duration time, {int daysAgo = 20}) => RaceResult(
      distance: RaceDistance.marathon,
      time: time,
      date: testToday.subtract(Duration(days: daysAgo)),
    );

RaceResult raceHalf(Duration time, {int daysAgo = 40}) => RaceResult(
      distance: RaceDistance.half,
      time: time,
      date: testToday.subtract(Duration(days: daysAgo)),
    );

GoalRace goal(
  RaceDistance distance, {
  required Duration finishTime,
  int inWeeks = 18,
  int daysPerWeek = 4,
}) =>
    GoalRace(
      distance: distance,
      date: testToday.add(Duration(days: inWeeks * 7)),
      finishTimeGoal: finishTime,
      daysPerWeek: daysPerWeek,
    );

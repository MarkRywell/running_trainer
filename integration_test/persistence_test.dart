import 'package:ai_running_trainer/app/controller.dart';
import 'package:ai_running_trainer/app/storage.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:ai_running_trainer/main.dart';
import 'package:ai_running_trainer/ui/onboarding/onboarding_screen.dart';
import 'package:ai_running_trainer/ui/plan/plan_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device tests.
///
/// The widget suite mocks SharedPreferences, which proves the *logic* works
/// but proves nothing about real storage. These run against the real plugin on
/// a real device, with no mock anywhere.
///
/// Run with:
///   flutter test integration_test -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Start from genuinely empty device storage.
    final storage = await TrainerStorage.open();
    await storage.clear();
    SharedPreferences.resetStatic();
  });

  testWidgets('onboarding writes to device storage and reads it back',
      (tester) async {
    final goalRace = GoalRace(
      distance: RaceDistance.marathon,
      date: DateTime.now().add(const Duration(days: 126)),
      finishTimeGoal: const Duration(hours: 3, minutes: 40),
      daysPerWeek: 4,
    );

    // --- Write ---
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'OnDevice',
        age: 34,
        gender: Gender.preferNotToSay,
        monthsRunning: 36,
        daysPerWeek: 4,
        heightCm: 178,
        weightKg: 72,
        estimatedWeeklyKm: 42,
      ),
      races: [
        RaceResult(
          distance: RaceDistance.k10,
          time: Duration(minutes: 44, seconds: 30),
          date: DateTime.now().subtract(const Duration(days: 21)),
        ),
      ],
      goal: goalRace,
      startDate: DateTime.now(),
    );
    expect(first.hasPlan, isTrue);

    await first.markWeekComplete(0);
    await first.markWeekComplete(1);

    // Drop the in-memory cache. The next read has to come off disk, which is
    // the whole point — without this the test would pass even if nothing was
    // ever written to the device.
    SharedPreferences.resetStatic();

    // --- Read back through a completely fresh controller ---
    final second = TrainerController(await TrainerStorage.open());
    await second.init();

    expect(second.hasPlan, isTrue, reason: 'plan must survive a cold read');
    expect(second.profile!.name, 'OnDevice');
    expect(second.profile!.monthsRunning, 36);
    expect(second.profile!.heightCm, 178);
    expect(second.races.length, 1);
    expect(second.races.first.time, const Duration(minutes: 44, seconds: 30));
    expect(second.goal!.distance, RaceDistance.marathon);
    expect(second.goal!.finishTimeGoal, const Duration(hours: 3, minutes: 40));
    expect(second.goal!.daysPerWeek, 4);
    expect(second.plan!.weekCount, first.plan!.weekCount);
    expect(second.progress!.completedCount, 2);
  });

  testWidgets('a saved profile goes straight to the plan on launch',
      (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Returning',
        age: 30,
        gender: Gender.preferNotToSay,
        monthsRunning: 24,
        daysPerWeek: 3,
        estimatedWeeklyKm: 30,
      ),
      races: const [],
      startDate: DateTime.now(),
    );

    SharedPreferences.resetStatic();

    // Exactly what main() does on a cold start.
    final controller = TrainerController(await TrainerStorage.open());
    await controller.init();
    await tester.pumpWidget(RunningTrainerApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byType(PlanScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('an accepted coach proposal survives an app restart',
      (tester) async {
    final start = DateTime.now();
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Coach',
        age: 38,
        gender: Gender.preferNotToSay,
        monthsRunning: 48,
        daysPerWeek: 4,
        estimatedWeeklyKm: 45,
      ),
      races: [
        RaceResult(
          distance: RaceDistance.k10,
          time: Duration(minutes: 43),
          date: DateTime.now().subtract(const Duration(days: 20)),
        ),
      ],
      goal: GoalRace(
        distance: RaceDistance.marathon,
        date: start.add(const Duration(days: 126)),
        finishTimeGoal: const Duration(hours: 3, minutes: 30),
        daysPerWeek: 4,
      ),
      startDate: start,
    );

    for (var i = 0; i < 3; i++) {
      await first.logWeek(
        i,
        const WeekLog(completed: true, sessionsDone: 4, difficulty: 9),
      );
    }

    final proposal = first.outstandingProposals.first;
    expect(proposal.id, 'cap-volume');
    await first.acceptProposal(proposal);
    expect(first.directive.capVolume, isTrue);

    // Force the read off disk.
    SharedPreferences.resetStatic();

    final second = TrainerController(await TrainerStorage.open());
    await second.init();

    expect(second.coachState.isAccepted('cap-volume'), isTrue);
    expect(second.directive.capVolume, isTrue);
    // The accepted change is still in force in the regenerated plan.
    expect(
      second.plan!.weeks[second.plan!.weekCount - 2].targetVolumeKm,
      lessThanOrEqualTo(second.plan!.weeks[3].targetVolumeKm + 0.01),
    );
  });

  testWidgets('a missed week holds the next one flat, on device',
      (tester) async {
    final start = DateTime.now();
    final c = TrainerController(await TrainerStorage.open());
    await c.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Reactive',
        age: 35,
        gender: Gender.preferNotToSay,
        monthsRunning: 36,
        daysPerWeek: 4,
        estimatedWeeklyKm: 40,
      ),
      races: [
        RaceResult(
          distance: RaceDistance.k10,
          time: Duration(minutes: 45),
          date: DateTime.now().subtract(const Duration(days: 20)),
        ),
      ],
      goal: GoalRace(
        distance: RaceDistance.marathon,
        date: start.add(const Duration(days: 126)),
        finishTimeGoal: const Duration(hours: 3, minutes: 40),
        daysPerWeek: 4,
      ),
      startDate: start,
    );

    final cleanWeek1 = c.plan!.weeks[0].targetVolumeKm;
    final cleanWeek2 = c.plan!.weeks[1].targetVolumeKm;
    // A clean plan builds.
    expect(cleanWeek2, greaterThan(cleanWeek1));

    // Now miss week 1 and regenerate.
    await c.logWeek(0, const WeekLog(sessionsDone: 1, difficulty: 9));
    expect(c.plan!.weeks[1].targetVolumeKm, cleanWeek1);

    // Completing it restores the build.
    await c.markWeekComplete(0);
    expect(c.plan!.weeks[1].targetVolumeKm, closeTo(cleanWeek2, 0.001));
  });

  testWidgets('a rich week log survives an app restart', (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Logger',
        age: 29,
        gender: Gender.preferNotToSay,
        monthsRunning: 24,
        daysPerWeek: 4,
        estimatedWeeklyKm: 36,
      ),
      races: const [],
      startDate: DateTime.now(),
    );
    await first.logWeek(
      0,
      const WeekLog(
        completed: true,
        actualKm: 34.5,
        sessionsDone: 3,
        difficulty: 8,
        note: 'heavy legs',
      ),
    );
    await first.logWeek(
      1,
      const WeekLog(completed: true, sessionsDone: 4, difficulty: 7),
    );
    await first.logWeek(
      2,
      const WeekLog(completed: true, sessionsDone: 4, difficulty: 9),
    );
    await first.logWeek(
      3,
      const WeekLog(completed: true, sessionsDone: 4, difficulty: 8),
    );

    // Force reads off disk.
    SharedPreferences.resetStatic();

    final second = TrainerController(await TrainerStorage.open());
    await second.init();

    final log = second.progress!.logFor(0);
    expect(log.actualKm, 34.5);
    expect(log.sessionsDone, 3);
    expect(log.difficulty, 8);
    expect(log.note, 'heavy legs');
    expect(second.progress!.looksTooHard, isTrue);
    expect(second.progress!.hardWeeks.length, 3);
    // Adherence is real, not a default.
    expect(second.progress!.sessionAdherence, isNotNull);
    expect(second.progress!.averageDifficulty, 8.0);
  });

  testWidgets('marked weeks survive an app restart', (tester) async {
    final start = DateTime.now();
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Marker',
        age: 31,
        gender: Gender.preferNotToSay,
        monthsRunning: 30,
        daysPerWeek: 4,
        estimatedWeeklyKm: 38,
      ),
      races: [
        RaceResult(
          distance: RaceDistance.k10,
          time: Duration(minutes: 46),
          date: DateTime.now().subtract(const Duration(days: 25)),
        ),
      ],
      startDate: start,
    );

    await first.markWeekComplete(0);
    expect(first.progress!.isComplete(0), isTrue);

    // Force the read to come off disk.
    SharedPreferences.resetStatic();

    final second = TrainerController(await TrainerStorage.open());
    await second.init();
    expect(second.progress!.isComplete(0), isTrue);
    expect(second.progress!.completedCount, 1);

    // And the plan still renders.
    await tester.pumpWidget(RunningTrainerApp(controller: second));
    await tester.pumpAndSettle();
    expect(find.byType(PlanScreen), findsOneWidget);
  });

  testWidgets('edited details survive an app restart', (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Editor',
        age: 34,
        gender: Gender.preferNotToSay,
        monthsRunning: 24,
        daysPerWeek: 3,
        estimatedWeeklyKm: 40,
      ),
      races: const [],
      startDate: DateTime.now(),
    );
    await first.markWeekComplete(0);

    // The edit path, driven through the controller the screen uses.
    await first.setProfile(
      (first.profile!).copyWith(
        name: 'Edited',
        estimatedWeeklyKm: const Optional(15),
      ),
    );
    await first.setRaces([
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 52, seconds: 25),
        date: DateTime.now().subtract(const Duration(days: 3)),
      ),
    ]);
    final seeded = first.plan!.weeks.first.targetVolumeKm;

    // Drop the in-memory cache so the read is forced off disk.
    SharedPreferences.resetStatic();

    final controller = TrainerController(await TrainerStorage.open());
    await controller.init();

    expect(controller.profile!.name, 'Edited');
    expect(controller.profile!.estimatedWeeklyKm, 15);
    expect(controller.races.single.time, const Duration(minutes: 52, seconds: 25));
    expect(
      controller.plan!.weeks.first.targetVolumeKm,
      seeded,
      reason: 'the same inputs must regenerate the same plan',
    );
    expect(
      controller.progress!.completedCount,
      1,
      reason: 'editing details is not a restart',
    );
  });

  testWidgets('clearing an optional field survives an app restart',
      (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Clearer',
        age: 34,
        gender: Gender.preferNotToSay,
        monthsRunning: 24,
        daysPerWeek: 3,
        estimatedWeeklyKm: 30,
      ),
      races: const [],
      startDate: DateTime.now(),
    );
    await first.setProfile(first.profile!.cleared(weeklyKm: true));

    SharedPreferences.resetStatic();

    final controller = TrainerController(await TrainerStorage.open());
    await controller.init();
    // Not left as the old value, and not lost — null, which means "not supplied",
    // so the plan falls back to the race-time estimate.
    expect(controller.profile!.estimatedWeeklyKm, isNull);
  });

  testWidgets('restarting a plan keeps the runner and clears the log',
      (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Rerunner',
        age: 40,
        gender: Gender.preferNotToSay,
        monthsRunning: 48,
        daysPerWeek: 4,
        estimatedWeeklyKm: 45,
      ),
      races: [
        RaceResult(
          distance: RaceDistance.k10,
          time: const Duration(minutes: 42),
          date: DateTime.now().subtract(const Duration(days: 20)),
        ),
      ],
      startDate: DateTime.now(),
    );
    await first.markWeekComplete(0);
    await first.restartPlan();

    SharedPreferences.resetStatic();

    final controller = TrainerController(await TrainerStorage.open());
    await controller.init();
    expect(controller.profile!.name, 'Rerunner');
    expect(controller.races, isNotEmpty);
    expect(controller.progress!.completedCount, 0);
    expect(controller.startDate!.weekday, DateTime.monday);
  });

  testWidgets('per-session records survive an app restart', (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Sessions',
        age: 34,
        gender: Gender.preferNotToSay,
        monthsRunning: 36,
        daysPerWeek: 4,
        estimatedWeeklyKm: 40,
      ),
      races: [
        RaceResult(
          distance: RaceDistance.k10,
          time: Duration(minutes: 44),
          date: DateTime.now().subtract(const Duration(days: 20)),
          averageHr: 168,
        ),
      ],
      startDate: DateTime.now(),
    );

    final day = first.plan!.weeks.first.workouts
        .firstWhere((w) => w.type == WorkoutType.tempo)
        .weekday!;
    await first.logSession(0, day, felt: SessionFelt.hard);

    // Marking the week done is authoritative for the self-reported fields but
    // must not discard what the runner recorded per session.
    await first.markWeekComplete(0);

    SharedPreferences.resetStatic();

    final controller = TrainerController(await TrainerStorage.open());
    await controller.init();

    expect(controller.races.single.averageHr, 168);
    final log = controller.progress!.logFor(0);
    expect(log.completed, isTrue);
    expect(log.sessions, hasLength(1));
    expect(log.sessions.single.dayOfWeek, day);
    expect(log.sessions.single.felt, SessionFelt.hard);
  });

  testWidgets('a heart rate does not change the regenerated plan', (tester) async {
    // The guard, on device. `generate` is pure, so this holds anywhere — but it
    // is worth proving through real storage that the field round-trips *and*
    // still moves nothing.
    Future<TrainingPlan> buildWith({required int? hr}) async {
      final c = TrainerController(await TrainerStorage.open());
      await c.completeOnboarding(
        profile: const RunnerProfile(
          name: 'Hr',
          age: 34,
          gender: Gender.preferNotToSay,
          monthsRunning: 24,
          daysPerWeek: 3,
          estimatedWeeklyKm: 15,
        ),
        races: [
          RaceResult(
            distance: RaceDistance.k10,
            time: Duration(minutes: 52, seconds: 25),
            date: DateTime.now().subtract(const Duration(days: 2)),
            averageHr: hr,
          ),
        ],
        startDate: DateTime.now(),
      );
      return c.plan!;
    }

    final without = await buildWith(hr: null);
    final with_ = await buildWith(hr: 168);
    expect(with_.weekCount, without.weekCount);
    expect(with_.paces.easy.secPerKm, without.paces.easy.secPerKm);
    for (var i = 0; i < without.weeks.length; i++) {
      expect(
        with_.weeks[i].targetVolumeKm,
        without.weeks[i].targetVolumeKm,
        reason: 'week ${without.weeks[i].weekNumber}',
      );
    }
  });

  testWidgets('clearing storage returns the app to onboarding',
      (tester) async {
    final first = TrainerController(await TrainerStorage.open());
    await first.completeOnboarding(
      profile: const RunnerProfile(
        name: 'Temporary',
        age: 28,
        gender: Gender.preferNotToSay,
        monthsRunning: 12,
        daysPerWeek: 3,
        estimatedWeeklyKm: 25,
      ),
      races: const [],
      startDate: DateTime.now(),
    );
    await first.reset();

    SharedPreferences.resetStatic();

    final controller = TrainerController(await TrainerStorage.open());
    await controller.init();
    await tester.pumpWidget(RunningTrainerApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(PlanScreen), findsNothing);
  });
}

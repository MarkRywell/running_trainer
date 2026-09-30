import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'app/storage.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/plan/plan_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await TrainerStorage.open();
  final controller = TrainerController(storage);
  await controller.init();
  runApp(RunningTrainerApp(controller: controller));
}

class RunningTrainerApp extends StatelessWidget {
  const RunningTrainerApp({super.key, required this.controller});

  final TrainerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: 'AI Running Trainer',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: controller.hasPlan
            ? PlanScreen(controller: controller)
            : OnboardingScreen(
                onComplete: (result) => controller.completeOnboarding(
                  profile: result.profile,
                  races: result.races,
                  goal: result.goal,
                ),
              ),
      ),
    );
  }
}

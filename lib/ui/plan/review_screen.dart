import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../domain/engine/fitness.dart';
import '../../domain/models/plan.dart';
import '../../domain/models/race.dart';
import '../../domain/units.dart';
import '../goal/goal_editor.dart';
import '../theme.dart';
import 'details_screen.dart';

/// The honest picture: what paces we derived, from what, and where we are
/// least sure. Shown before the runner commits, and reachable later.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.controller});

  final TrainerController controller;

  void _editGoal(BuildContext context) {
    showGoalEditor(
      context,
      current: controller.goal,
      onSave: controller.setGoal,
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = controller.plan;
    final fitness = controller.fitness;
    if (plan == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your plan'),
        actions: [
          IconButton(
            tooltip: 'Your details',
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DetailsScreen(controller: controller),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: AppColors.hairline),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.scrollBottom(context),
        ),
        children: [
          _Summary(plan: plan, onEditGoal: () => _editGoal(context)),
          const SectionHeader('Training paces'),
          _PaceTable(plan: plan),
          const SizedBox(height: AppSpacing.sm),
          const Callout(
            'Paces are anchored on your goal race pace, not on a prediction of '
            'what you can currently do. That is how a plan trains for the race '
            'you actually entered.',
          ),

          if (fitness != null && fitness.hasData) ...[
            const SectionHeader('Where these come from'),
            _Provenance(fitness: fitness),
            const SizedBox(height: AppSpacing.sm),
            _Equivalents(fitness: fitness),
            const SizedBox(height: AppSpacing.sm),
            const Callout(
              'Races you have not entered are projected from the one you have, '
              'using Riegel’s formula with a deliberately conservative '
              'correction — the raw formula tends to be optimistic at long '
              'distances, and an optimistic prediction becomes a plan that is '
              'too hard.',
            ),
          ],

          if (plan.flags.isNotEmpty) ...[
            const SectionHeader('Worth knowing'),
            for (final flag in plan.flags) ...[
              FlagCard(flag),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.plan, required this.onEditGoal});

  final TrainingPlan plan;
  final VoidCallback onEditGoal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF22140E), AppColors.surface],
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PLAN', style: theme.label),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.path.label,
                  style: theme.display.copyWith(fontSize: 24),
                ),
              ),
              TextButton.icon(
                key: const Key('review-edit-goal'),
                onPressed: onEditGoal,
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: Text(
                  plan.goal == null ? 'Set goal' : 'Edit goal',
                  style: theme.label.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            plan.goal != null
                ? '${plan.weekCount} weeks, built around your '
                    '${plan.goal!.distance.label} on '
                    '${plan.goal!.date.day}/${plan.goal!.date.month}.'
                : '${plan.weekCount} weeks of general base building. Add a goal '
                    'race when you have one and this becomes a periodised block.',
            style: theme.bodyMuted,
          ),
          const SizedBox(height: 10),
          // The plan start is snapped forward to a Monday, so say so rather
          // than leaving the runner to notice a week that starts on a
          // different day to everything else in their life.
          Row(
            children: [
              const Icon(Icons.event_available_outlined,
                  size: 14, color: AppColors.textTertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Starts Monday ${plan.startDate.day}/${plan.startDate.month}',
                  style: theme.bodyMuted.copyWith(fontSize: 12.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaceTable extends StatelessWidget {
  const _PaceTable({required this.plan});

  final TrainingPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < IntensityZone.slowestFirst.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            Builder(
              builder: (context) {
                final zone = IntensityZone.slowestFirst[i];
                final pace = plan.paces.forZone(zone);
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      ZoneSwatch(zone, size: 8),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              zone.label,
                              style: theme.body.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              zone.purpose,
                              style: theme.bodyMuted.copyWith(fontSize: 11),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        pace.format(),
                        style: theme.display.copyWith(
                          fontSize: 18,
                          color: ZonePalette.of(zone),
                        ),
                      ),
                      Text(
                        '/km',
                        style: theme.bodyMuted.copyWith(
                          fontSize: 11,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _Provenance extends StatelessWidget {
  const _Provenance({required this.fitness});

  final FitnessAssessment fitness;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anchor = fitness.anchor!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('BASED ON', style: theme.label),
                    const SizedBox(height: 2),
                    Text(
                      '${anchor.distance.label} in ${formatDuration(anchor.time)}',
                      style: theme.title.copyWith(fontSize: 15),
                    ),
                    Text(
                      _ago(anchor.ageInDays(DateTime.now())),
                      style: theme.bodyMuted.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (fitness.hasSupportedVdot)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('VDOT', style: theme.label),
                    const SizedBox(height: 2),
                    Text(
                      '${fitness.vdot!.round()}',
                      style: theme.display.copyWith(
                        fontSize: 28,
                        color: AppColors.brandAccent,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ago(int days) {
    if (days < 31) return '${(days / 7).round()} week(s) ago';
    if (days < 365) return '${(days / 30).round()} months ago';
    return '${(days / 365).toStringAsFixed(1)} years ago';
  }
}

class _Equivalents extends StatelessWidget {
  const _Equivalents({required this.fitness});

  final FitnessAssessment fitness;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(child: Text('EQUIVALENT TIMES', style: theme.label)),
              ],
            ),
          ),
          for (final d in RaceDistance.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      d.label,
                      style: theme.body.copyWith(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    formatDuration(fitness.equivalents[d]!),
                    style: theme.display.copyWith(fontSize: 16),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

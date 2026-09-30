/// Editing the runner's own details, and the three ways to redo a plan.
///
/// The three actions are deliberately separate rather than one combined flow.
/// "Edit details" is safe and "Start over" destroys a season of logs; putting
/// them behind the same control means one of them gets tapped by accident.
library;

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../domain/engine/fitness.dart';
import '../../domain/models/race.dart';
import '../../domain/progress.dart';
import '../../domain/units.dart';
import '../goal/goal_editor.dart';
import '../profile/profile_editor.dart';
import '../profile/race_editor.dart';
import '../theme.dart';

/// Profile, race times and goal, plus the plan actions.
///
/// Read-only by default with explicit edit affordances, so the common case —
/// looking at what the plan thinks about you — costs one tap and no risk.
class DetailsScreen extends StatelessWidget {
  const DetailsScreen({super.key, required this.controller});

  final TrainerController controller;

  Future<void> _editProfile(BuildContext context) async {
    final profile = controller.profile;
    if (profile == null) return;
    await showDetailsEditor(
      context,
      title: 'Your details',
      subtitle: 'Changing this rebuilds the plan. Weeks you have already '
          'logged are kept.',
      child: ProfileEditor(
        value: profile,
        onChanged: (v) => controller.setProfile(v),
      ),
    );
  }

  Future<void> _editRaces(BuildContext context) async {
    await showDetailsEditor(
      context,
      title: 'Race times',
      subtitle: 'One recent race is enough. Anything older than six months is '
          'not used to set your paces.',
      child: RaceEditor(
        value: controller.races,
        onChanged: (v) => controller.setRaces(v),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = controller.profile;
    final plan = controller.plan;
    final progress = controller.progress;
    if (profile == null || plan == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your details'),
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
          const SectionHeader('About you'),
          _DetailCard(
            cardKey: const Key('edit-profile'),
            onTap: () => _editProfile(context),
            rows: [
              ('Name', profile.name, null),
              ('Age', '${profile.age}', null),
              ('Gender', ProfileEditor.genderLabel(profile.gender), null),
              (
                'Running for',
                monthsLabel(profile.monthsRunning),
                null,
              ),
              ('Days a week', '${profile.daysPerWeek}', null),
              (
                'Weekly volume',
                profile.estimatedWeeklyKm == null
                    ? 'Estimated from race times'
                    : '${formatKm(profile.estimatedWeeklyKm!)} km',
                null,
              ),
              if (profile.heightCm != null)
                ('Height', '${formatKm(profile.heightCm!)} cm', null),
              if (profile.weightKg != null)
                ('Weight', '${formatKm(profile.weightKg!)} kg', null),
            ],
          ),
          if (profile.estimatedWeeklyKm == null) ...[
            const SizedBox(height: AppSpacing.sm),
            const Callout(
              'You have not told us how much you run, so the plan is seeded '
              'from your race times. That tends to overestimate a runner who '
              'trains three days a week. Setting it makes week 1 honest.',
            ),
          ],
          SectionHeader(
            'Race times',
            trailing: TextButton.icon(
              key: const Key('edit-races'),
              onPressed: () => _editRaces(context),
              icon: const Icon(Icons.edit_outlined, size: 15),
              label: Text(
                'Edit',
                style: Theme.of(context)
                        .label
                        .copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
          _DetailCard(
            rows: [
              for (final d in RaceDistance.values)
                (
                  d.label,
                  _timeFor(controller.races, d) ?? '—',
                  null,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _ProvenanceNote(fitness: controller.fitness),
          const SectionHeader('Goal race'),
          _DetailCard(
            rows: [
              if (plan.goal == null)
                ('None set', 'Base block', null)
              else ...[
                ('Race', plan.goal!.distance.label, null),
                ('Date', formatDate(plan.goal!.date), null),
                (
                  'Target',
                  formatTimeInput(plan.goal!.finishTimeGoal),
                  null,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            key: const Key('edit-goal'),
            onPressed: () => showGoalEditor(
              context,
              current: controller.goal,
              onSave: controller.setGoal,
            ),
            icon: const Icon(Icons.flag_outlined, size: 17),
            label: Text(plan.goal == null ? 'Set a goal race' : 'Edit goal race'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 46),
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.hairlineStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
          ),
          const SectionHeader('Redo the plan'),
          _PlanActions(
            controller: controller,
            progress: progress,
            onEditDetails: () => _editProfile(context),
          ),
        ],
      ),
    );
  }

  static String? _timeFor(List<RaceResult> races, RaceDistance d) {
    for (final r in races) {
      if (r.distance == d) return formatDuration(r.time);
    }
    return null;
  }

  static String monthsLabel(int m) {
    if (m < 12) return '$m month${m == 1 ? '' : 's'}';
    final y = m / 12;
    return '${y.toStringAsFixed(y < 2 ? 1 : 0)} years';
  }
}

/// Why the plan is not using every result the runner entered.
///
/// The runner gave us these numbers. If some of them were dropped for being old,
/// saying so is the difference between a plan that is quietly less confident
/// than it looks and one that is merely conservative.
class _ProvenanceNote extends StatelessWidget {
  const _ProvenanceNote({required this.fitness});

  final FitnessAssessment? fitness;

  @override
  Widget build(BuildContext context) {
    final f = fitness;
    if (f == null || !f.hasData) return const SizedBox.shrink();

    final stale = f.notes.where((n) => n.startsWith('Not used')).toList();
    if (stale.isEmpty) return const SizedBox.shrink();
    return Callout(stale.first, icon: Icons.info_outline);
  }
}

/// The three ways forward, each doing one thing.
class _PlanActions extends StatelessWidget {
  const _PlanActions({
    required this.controller,
    required this.progress,
    required this.onEditDetails,
  });

  final TrainerController controller;
  final PlanProgress? progress;
  final VoidCallback onEditDetails;

  @override
  Widget build(BuildContext context) {
    final logged = progress?.completedCount ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Action(
          key: const Key('action-edit-details'),
          icon: Icons.tune,
          title: 'Edit your details',
          detail: 'Keep everything you have logged. Rebuilds the plan around '
              'your new numbers.',
          onTap: onEditDetails,
        ),
        const SizedBox(height: AppSpacing.sm),
        _Action(
          key: const Key('action-new-plan'),
          icon: Icons.replay,
          title: 'Start a new plan',
          detail: logged == 0
              ? 'Same runner, same race times, new block starting next Monday.'
              : 'Same runner, same race times, new block starting next Monday. '
                  'Clears the $logged week${logged == 1 ? '' : 's'} you have logged.',
          destructive: logged > 0,
          onTap: () async {
            final ok = await _confirm(
              context,
              title: 'Start a new plan?',
              body: logged == 0
                  ? 'Your details and race times are kept. The block restarts '
                      'from next Monday.'
                  : 'Your details and race times are kept, but the $logged '
                      'logged week${logged == 1 ? '' : 's'} will be cleared and '
                      'the block will restart from next Monday. This cannot be '
                      'undone.',
              confirmLabel: 'Start new plan',
            );
            if (ok != true || !context.mounted) return;
            // Back to the root *before* mutating. Clearing the plan turns every
            // screen that reads one into a loading state, so anything left on the
            // stack becomes an indeterminate spinner over the onboarding form.
            Navigator.of(context).popUntil((r) => r.isFirst);
            await controller.restartPlan();
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        _Action(
          key: const Key('action-start-over'),
          icon: Icons.restart_alt,
          title: 'Start over',
          detail: 'Clears your details, race times and goal, and takes you back '
              'to the beginning.',
          destructive: true,
          onTap: () async {
            final ok = await _confirm(
              context,
              title: 'Start over?',
              body: 'This clears your profile, race times, goal and every week '
                  'you have logged. This cannot be undone.',
              confirmLabel: 'Start over',
            );
            if (ok != true || !context.mounted) return;
            // Back to the root — see the note on the action above.
            Navigator.of(context).popUntil((r) => r.isFirst);
            await controller.reset();
          },
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = destructive ? AppColors.danger : AppColors.textPrimary;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.title.copyWith(
                        fontSize: 14.5,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: theme.bodyMuted.copyWith(
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceHigh,
      title: Text(title),
      content: Text(body, style: Theme.of(ctx).bodyMuted),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            minimumSize: const Size(0, 44),
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// A read-only label/value card, with an optional row-level edit affordance.
class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.rows,
    this.cardKey,
    this.onTap,
  });

  final List<(String, String, String?)> rows;
  final Key? cardKey;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      style: theme.bodyMuted.copyWith(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      textAlign: TextAlign.right,
                      style: theme.body.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.edit_outlined,
                      size: 13,
                      color: AppColors.textTertiary,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      key: cardKey,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: card,
      ),
    );
  }
}

/// Full-screen editor for one of the detail groups.
///
/// Apply is explicit and there is no "save", because these editors emit on every
/// keystroke — the same pattern as the goal sheet, and the same reason: a
/// half-typed 10K time must not become the plan's anchor.
Future<void> showDetailsEditor(
  BuildContext context, {
  required String title,
  required String subtitle,
  required Widget child,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => Scaffold(
        appBar: AppBar(
          title: Text(title),
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
            Text(
              subtitle,
              style: Theme.of(ctx).bodyMuted.copyWith(height: 1.5),
            ),
            const SizedBox(height: AppSpacing.lg),
            child,
          ],
        ),
      ),
    ),
  );
}

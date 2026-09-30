import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../domain/coaching.dart';
import '../../domain/models/goal.dart';
import '../../domain/models/plan.dart';
import '../../domain/models/week_log.dart';
import '../../domain/progress.dart';
import '../../domain/units.dart';
import '../goal/goal_editor.dart';
import '../theme.dart';
import 'review_screen.dart';
import 'week_log_sheet.dart';

/// The main screen: where the runner is now, what is coming, and anything
/// they should know about.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key, required this.controller});

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
    final progress = controller.progress;
    final theme = Theme.of(context);
    if (plan == null || progress == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final index = controller.currentWeekIndex;
    final week = plan.weeks[index];
    final weekLog = progress.logFor(index);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.md,
        title: Row(
          children: [
            Text('W${week.weekNumber}',
                style: Theme.of(context).display.copyWith(fontSize: 26)),
            const SizedBox(width: 8),
            Text(
              '/ ${plan.weekCount}',
              style: Theme.of(context).bodyMuted.copyWith(
                    color: AppColors.textTertiary,
                  ),
            ),
            if (progress.completedCount > 0) ...[
              const SizedBox(width: 10),
              _ProgressPip(
                done: progress.completedCount,
                total: plan.weekCount,
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Paces and review',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ReviewScreen(controller: controller),
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
          if (progress.missedWeekCount > 0) ...[
            _MissedWeeksCallout(
              missed: progress.missedWeekCount,
              onJump: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _WeekStripScreen(controller: controller),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          _WeekHeader(
            week: week,
            plan: plan,
            isComplete: progress.isComplete(index),
            isProvisional: progress.isProvisional(index),
            outstandingBefore: progress.outstandingBefore(index),
            log: weekLog,
            onToggleComplete: () =>
                controller.markWeekComplete(index, value: !progress.isComplete(index)),
          ),
          const SizedBox(height: AppSpacing.md),
          // Always tappable. Before this the app told the runner they could
          // change their goal "at any time" and the only way to do it was to
          // wipe the profile and redo onboarding.
          if (plan.goal != null)
            _RaceCard(goal: plan.goal!, onEdit: () => _editGoal(context))
          else
            _AddGoalCard(onAdd: () => _editGoal(context)),
          for (final flag in controller.importantFlags) ...[
            const SizedBox(height: AppSpacing.sm + 2),
            FlagCard(flag),
          ],
          for (final proposal in controller.outstandingProposals) ...[
            const SizedBox(height: AppSpacing.sm + 2),
            _ProposalCard(
              proposal: proposal,
              onAccept: () => controller.acceptProposal(proposal),
              onDecline: () => controller.declineProposal(proposal),
            ),
          ],
          if (controller.directive.summary.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm + 2),
            _DirectiveSummary(
              lines: controller.directive.summary,
              onRevoke: (id) => controller.revokeProposal(id),
              acceptedIds: [
                if (controller.coachState.isAccepted('cap-volume')) 'cap-volume',
                if (controller.coachState.isAccepted('fewer-days')) 'fewer-days',
              ],
            ),
          ],
          SectionHeader(
            'This week',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (weekLog.hasData && !weekLog.completed)
                  _CutbackTag(week: week),
                const SizedBox(width: 4),
                _LogButton(
                  hasLog: weekLog.hasData,
                  onTap: () => showWeekLogSheet(
                    context,
                    week: week,
                    initial: weekLog,
                    onSave: (l) => controller.logWeek(index, l),
                  ),
                ),
              ],
            ),
          ),
          for (final w in week.workouts) ...[
            const SizedBox(height: AppSpacing.sm),
            _SessionCard(
              workout: w,
              paces: plan.paces,
              onTap: () => showSessionSheet(
                context,
                w,
                plan.paces,
                weekIndex: index,
                controller: controller,
              ),
            ),
          ],
          SectionHeader(
            'The block',
            trailing: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _WeekStripScreen(controller: controller),
                ),
              ),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              child: Text(
                'ALL WEEKS',
                style: theme.label.copyWith(color: AppColors.brandAccent),
              ),
            ),
          ),
          _PhaseRail(plan: plan, currentIndex: index),
          const SizedBox(height: AppSpacing.sm),
          _PhaseLegend(plan: plan),
          const SizedBox(height: AppSpacing.md),
          _WeekStrip(
            plan: plan,
            progress: progress,
            onOpen: (i) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _WeekScreen(controller: controller, index: i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "N / total" completion pip next to the week number.
class _ProgressPip extends StatelessWidget {
  const _ProgressPip({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$done/$total',
        style: theme.tabular.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// Shown when past weeks were never marked done.
class _MissedWeeksCallout extends StatelessWidget {
  const _MissedWeeksCallout({required this.missed, required this.onJump});

  final int missed;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border(
          left: BorderSide(color: AppColors.brandAccent, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            missed == 1
                ? 'ONE WEEK WENT UNLOGGED'
                : '$missed WEEKS WENT UNLOGGED',
            style: theme.label.copyWith(color: AppColors.brandAccent),
          ),
          const SizedBox(height: 6),
          Text(
            'Nothing here is lost. We have put you back on your first missed '
            'week so the plan still builds from something real.',
            style: theme.bodyMuted.copyWith(height: 1.5),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: onJump,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
            ),
            child: const Text('See the whole block'),
          ),
        ],
      ),
    );
  }
}

class _CutbackTag extends StatelessWidget {
  const _CutbackTag({required this.week});

  final PlanWeek week;

  @override
  Widget build(BuildContext context) {
    if (!week.isCutback) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('CUTBACK', style: Theme.of(context).label),
    );
  }
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({
    required this.week,
    required this.plan,
    required this.isComplete,
    required this.isProvisional,
    required this.outstandingBefore,
    required this.log,
    required this.onToggleComplete,
  });

  final PlanWeek week;
  final TrainingPlan plan;
  final bool isComplete;
  final bool isProvisional;
  final int outstandingBefore;
  final WeekLog log;
  final VoidCallback onToggleComplete;

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
          Row(
            children: [
              ZoneSwatch(phaseZone(week.phase)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  week.phase.label.toUpperCase(),
                  style: theme.label.copyWith(
                    color: ZonePalette.of(phaseZone(week.phase)),
                  ),
                ),
              ),
              _CompleteButton(
                complete: isComplete,
                onTap: onToggleComplete,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(week.phase.blurb, style: theme.bodyMuted),
          if (log.difficulty != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _DifficultyLine(difficulty: log.difficulty!),
          ],
          if (isProvisional) ...[
            const SizedBox(height: AppSpacing.sm),
            // Say the quiet part: this week was generated on the assumption
            // that an earlier one happened. Presenting it as settled would be
            // a lie the runner only discovers at week 12.
            Callout(
              outstandingBefore == 1
                  ? 'Still based on week ${week.weekNumber - outstandingBefore}, '
                      'which you have not marked done. Complete it and this '
                      'becomes real.'
                  : 'Still based on $outstandingBefore earlier weeks that were '
                      'never marked done. Complete those and this becomes real.',
              accent: AppColors.brandAccent,
              icon: Icons.info_outline_rounded,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _Stat(
                label: 'VOLUME',
                value: formatKm(week.targetVolumeKm),
                unit: 'km',
              ),
              _Stat(label: 'RUN DAYS', value: '${week.runCount}'),
              _Stat(
                label: 'EASY',
                value: '${(week.easyFraction * 100).round()}',
                unit: '%',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens the week log sheet.
class _LogButton extends StatelessWidget {
  const _LogButton({required this.hasLog, required this.onTap});

  final bool hasLog;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: const Key('log-week'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: hasLog ? AppColors.hairlineStrong : AppColors.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasLog ? Icons.edit_note : Icons.add_chart_outlined,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                hasLog ? 'EDIT LOG' : 'LOG WEEK',
                style: theme.label.copyWith(fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-line echo of how the week felt.
class _DifficultyLine extends StatelessWidget {
  const _DifficultyLine({required this.difficulty});

  final int difficulty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tooHard = difficulty >= 8;
    final tooEasy = difficulty <= 2;
    final color = tooHard
        ? AppColors.brandAccent
        : tooEasy
            ? AppColors.textTertiary
            : AppColors.textSecondary;
    return Row(
      children: [
        Icon(
          tooHard ? Icons.warning_amber_rounded : Icons.sentiment_neutral,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            tooHard
                ? 'You rated this week $difficulty/10 — too hard'
                : tooEasy
                    ? 'You rated this week $difficulty/10 — barely a workout'
                    : 'You rated this week $difficulty/10',
            style: theme.body.copyWith(fontSize: 12.5, color: color),
          ),
        ),
      ],
    );
  }
}

/// A coach proposal, with its reasoning and a real accept/decline.
///
/// The reasoning is not decoration. A change to the plan the runner agreed to
/// follow has to be explainable, or it is just a surprise with extra steps.
class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.onAccept,
    required this.onDecline,
  });

  final CoachProposal proposal;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent =
        proposal.severity == FlagSeverity.warning ? AppColors.danger : AppColors.brandAccent;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                proposal.severity == FlagSeverity.warning
                    ? Icons.trending_flat
                    : Icons.calendar_today_outlined,
                size: 17,
                color: accent,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'SUGGESTED',
                  style: theme.label.copyWith(color: accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(proposal.title, style: theme.title.copyWith(fontSize: 16)),
          const SizedBox(height: 6),
          Text(
            proposal.rationale,
            style: theme.bodyMuted.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: Key('accept-${proposal.id}'),
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    backgroundColor: AppColors.brand,
                  ),
                  child: const Text('Do it'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                height: 46,
                child: OutlinedButton(
                  key: Key('decline-${proposal.id}'),
                  onPressed: onDecline,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.hairlineStrong),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  child: const Text('No thanks'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows what is currently in force, and lets the runner withdraw it.
///
/// An accepted change must be reversible, or accepting becomes a trap.
class _DirectiveSummary extends StatelessWidget {
  const _DirectiveSummary({
    required this.lines,
    required this.onRevoke,
    required this.acceptedIds,
  });

  final List<String> lines;
  final ValueChanged<String> onRevoke;
  final List<String> acceptedIds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text('YOUR ADJUSTMENTS', style: theme.label),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < lines.length; i++) ...[
            Text(
              '· ${lines[i]}',
              style: theme.bodyMuted.copyWith(fontSize: 12.5, height: 1.45),
            ),
            if (i < lines.length - 1) const SizedBox(height: 4),
          ],
          if (acceptedIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('revoke-adjustments'),
                onPressed: () {
                  for (final id in acceptedIds) {
                    onRevoke(id);
                  }
                },
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                ),
                child: Text(
                  'Put my plan back',
                  style: theme.label.copyWith(color: AppColors.brandAccent),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CompleteButton extends StatelessWidget {
  const _CompleteButton({required this.complete, required this.onTap});

  final bool complete;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: complete ? AppColors.success : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: const Key('complete-week'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: complete ? AppColors.success : AppColors.hairlineStrong,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                complete ? Icons.check_rounded : Icons.check_circle_outline,
                size: 15,
                color: complete ? AppColors.bg : AppColors.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                complete ? 'DONE' : 'MARK DONE',
                style: theme.label.copyWith(
                  fontSize: 10,
                  color: complete ? AppColors.bg : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal strip of every week in the block, tappable and marked done.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.plan,
    required this.progress,
    required this.onOpen,
  });

  final TrainingPlan plan;
  final PlanProgress progress;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: plan.weekCount,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final done = progress.isComplete(i);
          final provisional = progress.isProvisional(i);
          final zone = phaseZone(plan.weeks[i].phase);
          return GestureDetector(
            key: Key('week-tile-$i'),
            onTap: () => onOpen(i),
            child: Container(
              width: 44,
              decoration: BoxDecoration(
                color: done ? AppColors.surfaceHigh : AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: done ? AppColors.success : AppColors.hairline,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${i + 1}',
                    style: theme.tabular.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: done ? AppColors.textSecondary : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 18,
                    height: 3,
                    decoration: BoxDecoration(
                      color: done
                          ? AppColors.success
                          : provisional
                              ? AppColors.textTertiary
                              : ZonePalette.of(zone),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A single week, with its sessions and a completion toggle.
class _WeekScreen extends StatelessWidget {
  const _WeekScreen({required this.controller, required this.index});

  final TrainerController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    final plan = controller.plan;
    final progress = controller.progress;
    if (plan == null || progress == null || index >= plan.weekCount) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final week = plan.weeks[index];
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Week ${week.weekNumber}'),
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
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        week.phase.label.toUpperCase(),
                        style: theme.label.copyWith(
                          color: ZonePalette.of(phaseZone(week.phase)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(week.phase.blurb, style: theme.bodyMuted),
                      const SizedBox(height: 8),
                      Text(
                        '${formatKm(week.targetVolumeKm)} km · '
                        '${week.runCount} run days',
                        style: theme.tabular.copyWith(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                _CompleteButton(
                  complete: progress.isComplete(index),
                  onTap: () => controller.markWeekComplete(
                    index,
                    value: !progress.isComplete(index),
                  ),
                ),
              ],
            ),
          ),
          if (progress.isProvisional(index)) ...[
            const SizedBox(height: AppSpacing.sm),
            Callout(
              progress.outstandingBefore(index) == 1
                  ? 'Built on week ${week.weekNumber - 1}, which is not marked '
                      'done. Complete it and this week becomes real.'
                  : 'Built on ${progress.outstandingBefore(index)} earlier '
                      'weeks that are not marked done.',
              accent: AppColors.brandAccent,
              icon: Icons.info_outline_rounded,
            ),
          ],
          const SectionHeader('Sessions'),
          for (final w in week.workouts) ...[
            const SizedBox(height: AppSpacing.sm),
            _SessionCard(
              workout: w,
              paces: plan.paces,
              onTap: () => showSessionSheet(
                context,
                w,
                plan.paces,
                weekIndex: controller.currentWeekIndex,
                controller: controller,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Whole-block overview, reached from the missed-weeks prompt.
class _WeekStripScreen extends StatelessWidget {
  const _WeekStripScreen({required this.controller});

  final TrainerController controller;

  @override
  Widget build(BuildContext context) {
    final plan = controller.plan;
    final progress = controller.progress;
    if (plan == null || progress == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('The whole block'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: AppColors.hairline),
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount: plan.weekCount,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, i) {
          final week = plan.weeks[i];
          final done = progress.isComplete(i);
          return Material(
            key: Key('block-week-$i'),
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: InkWell(
              onTap: () => controller.markWeekComplete(i, value: !done),
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(
                    color: done ? AppColors.success : AppColors.hairline,
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        '${week.weekNumber}',
                        style: theme.tabular.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: done
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            week.phase.label,
                            style: theme.body.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${formatKm(week.targetVolumeKm)} km · '
                            '${week.runCount} days',
                            style: theme.tabular.copyWith(
                              fontSize: 11.5,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      done ? Icons.check_circle : Icons.circle_outlined,
                      size: 20,
                      color: done ? AppColors.success : AppColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.unit,
    this.fontSize = 28,
  });

  final String label;
  final String value;
  final String? unit;

  /// Durations like `1:23:45` need a smaller size than a bare distance, or
  /// they overflow a third of a phone-width row.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Scale down rather than overflow. A stat is one third of a phone
          // row, and the content is not bounded: volume can reach three
          // digits and a duration can be `1:23:45`. Anything that renders a
          // plan number has to be able to shrink.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: theme.display.copyWith(fontSize: fontSize),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 2),
                  Text(
                    unit!,
                    style: theme.bodyMuted.copyWith(
                      fontSize: 13,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(label, style: theme.label),
          ),
        ],
      ),
    );
  }
}

/// The goal race, shown as a tappable card.
class _RaceCard extends StatelessWidget {
  const _RaceCard({required this.goal, required this.onEdit});

  final GoalRace goal;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = goal.date.difference(DateTime.now()).inDays;
    final weeks = days < 0 ? 0 : days ~/ 7;
    final passed = days < 0;

    return _TappableCard(
      key: const Key('race-card'),
      onTap: onEdit,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: passed
                  ? null
                  : const LinearGradient(
                      colors: [AppColors.brand, AppColors.brandAccent],
                    ),
              color: passed ? AppColors.surfaceHigh : null,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Icon(
              passed ? Icons.event_busy : Icons.flag_rounded,
              size: 20,
              color: passed ? AppColors.textTertiary : AppColors.onBrand,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  passed
                      ? 'RACE DAY HAS PASSED'
                      : 'RACE IN $weeks WEEK${weeks == 1 ? '' : 'S'}',
                  style: theme.label.copyWith(
                    color: passed
                        ? AppColors.textTertiary
                        : AppColors.brandAccent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${goal.distance.label} · '
                  '${formatDuration(goal.finishTimeGoal)} · '
                  '${goal.date.day}/${goal.date.month}',
                  style: theme.title.copyWith(fontSize: 15),
                ),
              ],
            ),
          ),
          const Icon(Icons.edit_outlined,
              size: 16, color: AppColors.textTertiary),
        ],
      ),
    );
  }
}

/// Shown when no goal is set, so the affordance is discoverable in both states.
class _AddGoalCard extends StatelessWidget {
  const _AddGoalCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TappableCard(
      key: const Key('add-goal-card'),
      onTap: onAdd,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(
                color: AppColors.hairlineStrong,
              ),
            ),
            child: const Icon(Icons.add,
                size: 20, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NO GOAL RACE SET',
                  style: theme.label.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  'Set one and this becomes a race plan',
                  style: theme.title.copyWith(fontSize: 15),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              size: 18, color: AppColors.textTertiary),
        ],
      ),
    );
  }
}

class _TappableCard extends StatelessWidget {
  const _TappableCard({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.hairline),
            ),
            child: child,
          ),
        ),
      );
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.workout,
    required this.paces,
    required this.onTap,
  });

  final Workout workout;
  final TrainingPaces paces;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRest = workout.type == WorkoutType.rest;
    // The session's own pace, not one inferred from its zone. A session
    // prescribed off-ladder — the taper's race-pace set, the goal race — would
    // otherwise show a number its own description contradicts.
    final pace = workout.displayPace(paces);
    final isRace = workout.type == WorkoutType.race;

    return Material(
      color: isRace ? AppColors.surfaceRaised : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: isRest ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: isRace ? AppColors.brandAccent : AppColors.hairline,
              width: isRace ? 1 : 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Rest days have no intensity, so they get a flat rule rather
              // than a zone colour. The old version used Colors.black26 here,
              // which vanishes against a dark surface.
              isRest
                  ? Container(
                      width: 3,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.hairlineStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )
                  : ZoneRule(workout.zone, width: 3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            workout.title,
                            style: theme.title.copyWith(
                              fontSize: 15,
                              color: isRest
                                  ? AppColors.textTertiary
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (!isRest && workout.distanceKm > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            formatKm(workout.distanceKm),
                            style: theme.display.copyWith(fontSize: 17),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            'km',
                            style: theme.bodyMuted.copyWith(
                              fontSize: 12,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (!isRest) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            pace.format(),
                            style: theme.tabular.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: ZonePalette.of(workout.zone),
                            ),
                          ),
                          Text(
                            ' /km',
                            style: theme.tabular.copyWith(
                              fontSize: 12,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      workout.description,
                      style: theme.bodyMuted.copyWith(
                        fontSize: 12.5,
                        height: 1.4,
                        color: isRest
                            ? AppColors.textTertiary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal progress rail through the phases of the block.
class _PhaseRail extends StatelessWidget {
  const _PhaseRail({required this.plan, required this.currentIndex});

  final TrainingPlan plan;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress =
        plan.weekCount <= 1 ? 0.0 : currentIndex / (plan.weekCount - 1);
    final current = plan.weeks[currentIndex];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                current.phase.label.toUpperCase(),
                style: theme.label.copyWith(
                  color: ZonePalette.of(phaseZone(current.phase)),
                ),
              ),
              const Spacer(),
              Text(
                'WEEK ${current.weekNumber} OF ${plan.weekCount}',
                style: theme.label,
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, c) => SizedBox(
              height: 6,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.brand, AppColors.brandAccent],
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(plan.weeks.first.phase.label, style: theme.label),
              Text(plan.weeks.last.phase.label, style: theme.label),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhaseLegend extends StatelessWidget {
  const _PhaseLegend({required this.plan});

  final TrainingPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seen = <PlanPhase>{};
    final phases = <PlanPhase>[];
    for (final w in plan.weeks) {
      if (seen.add(w.phase)) phases.add(w.phase);
    }

    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      children: [
        for (final p in phases)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ZoneSwatch(phaseZone(p), size: 8),
              const SizedBox(width: 6),
              Text(p.label, style: theme.bodyMuted.copyWith(fontSize: 12)),
            ],
          ),
      ],
    );
  }
}

/// Full detail for one session.
///
/// [weekIndex] and [controller] are optional: without them the sheet is purely a
/// read-only reference, which is how it is used from the review screen.
void showSessionSheet(
  BuildContext context,
  Workout w,
  TrainingPaces paces, {
  int? weekIndex,
  TrainerController? controller,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SessionSheet(
      workout: w,
      paces: paces,
      weekIndex: weekIndex,
      controller: controller,
    ),
  );
}

class _SessionSheet extends StatelessWidget {
  const _SessionSheet({
    required this.workout,
    required this.paces,
    this.weekIndex,
    this.controller,
  });

  final Workout workout;
  final TrainingPaces paces;
  final int? weekIndex;
  final TrainerController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Same rule as the card in the week list: the session's own pace, never one
    // inferred from its zone.
    final pace = workout.displayPace(paces);
    final zoneColor = ZonePalette.of(workout.zone);

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ZoneRule(workout.zone, width: 3),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      workout.title,
                      style: theme.display.copyWith(fontSize: 24),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                workout.zone.purpose,
                style: theme.bodyMuted,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  if (workout.distanceKm > 0)
                    _Stat(
                      label: 'DISTANCE',
                      value: formatKm(workout.distanceKm),
                      unit: 'km',
                      fontSize: 20,
                    ),
                  if (workout.targetDuration != null)
                    _Stat(
                      label: 'DURATION',
                      value: formatDuration(workout.targetDuration!),
                      fontSize: 20,
                    ),
                  _Stat(
                    label: 'PACE',
                    value: pace.format(),
                    unit: '/km',
                    fontSize: 20,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                workout.description,
                style: theme.body.copyWith(height: 1.55),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('EFFORT', style: theme.label),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border(left: BorderSide(color: zoneColor, width: 2)),
                ),
                child: Text(
                  _effort(workout.zone),
                  style: theme.bodyMuted.copyWith(height: 1.5),
                ),
              ),
              if (weekIndex != null && controller != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _FeltControl(
                  weekIndex: weekIndex!,
                  controller: controller!,
                  workout: workout,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _effort(IntensityZone z) => switch (z) {
        IntensityZone.recovery =>
          'RPE 2/10. You could hold a conversation without thinking about it.',
        IntensityZone.easy =>
          'RPE 3–4/10. Comfortable enough to talk in short sentences. This '
              'should feel too easy — that is the point.',
        IntensityZone.marathon =>
          'RPE 5–6/10. Controlled and sustainable. You know you could go '
              'faster; you are choosing not to.',
        IntensityZone.threshold =>
          'RPE 7/10. Comfortably hard. You could add a little at the end but '
              'you should not need to.',
        IntensityZone.interval =>
          'RPE 8–9/10. Hard, in bursts. You are not able to speak during the '
              'reps.',
        IntensityZone.repetition =>
          'RPE 9–10/10. Very hard and very short. Full recovery between reps.',
      };
}

/// One tap per session: how did it actually go?
///
/// Placed here, at the bottom of the sheet the runner already opens, rather than
/// as a row of controls on the week itself. That is the whole design: one tap in
/// a place they are already looking beats three controls they have to seek out.
/// Anything more and it does not get done on a bad week, which is the only week
/// the data matters on.
///
/// Three states, not a 1–10 slider. The week-level difficulty is a slider and
/// it works, but a week is too coarse to say *which* session hurt — and the
/// difference between "your tempo is too much" and "your long run is too much"
/// is the difference between two opposite plans.
class _FeltControl extends StatelessWidget {
  const _FeltControl({
    required this.weekIndex,
    required this.controller,
    required this.workout,
  });

  final int weekIndex;
  final TrainerController controller;
  final Workout workout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final day = workout.weekday;
    if (day == null || workout.type == WorkoutType.rest) {
      return const SizedBox.shrink();
    }

    final recorded = controller
        .logWeekFor(weekIndex)
        .sessions
        .where((s) => s.dayOfWeek == day)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HOW DID THAT GO?', style: theme.label),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final f in SessionFelt.values) ...[
              if (f != SessionFelt.values.first)
                const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _FeltButton(
                  key: Key('felt-$day-${f.name}'),
                  felt: f,
                  selected: recorded?.felt == f,
                  onTap: () => controller.logSession(weekIndex, day, felt: f),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          recorded?.felt == null
              ? 'Optional. It is what lets us tell the difference between a hard '
                  'tempo and a hard long run.'
              : 'Tap again to change it.',
          style: theme.bodyMuted.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}

class _FeltButton extends StatelessWidget {
  const _FeltButton({
    super.key,
    required this.felt,
    required this.selected,
    required this.onTap,
  });

  final SessionFelt felt;
  final bool selected;
  final VoidCallback onTap;

  static String label(SessionFelt f) => switch (f) {
        SessionFelt.easy => 'Easy',
        SessionFelt.right => 'About right',
        SessionFelt.hard => 'Hard',
      };

  /// Colour follows the zone ramp rather than introducing a new palette, so the
  /// control reads as part of the same system.
  static Color accent(SessionFelt f) => switch (f) {
        SessionFelt.easy => ZonePalette.of(IntensityZone.easy),
        SessionFelt.right => ZonePalette.of(IntensityZone.marathon),
        SessionFelt.hard => ZonePalette.of(IntensityZone.threshold),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent(felt);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(
            color: selected ? color : AppColors.hairlineStrong,
          ),
        ),
        child: Text(
          label(felt),
          textAlign: TextAlign.center,
          style: theme.body.copyWith(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? color : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}


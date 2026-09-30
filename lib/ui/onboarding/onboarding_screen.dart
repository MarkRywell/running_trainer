import 'package:flutter/material.dart';

import '../../domain/models/goal.dart';
import '../../domain/models/profile.dart';
import '../../domain/models/race.dart';
import '../../domain/units.dart';
import '../goal/goal_editor.dart';
import '../profile/profile_editor.dart';
import '../profile/race_editor.dart';
import '../theme.dart';

/// Collected across the wizard, handed back when the runner finishes.
class OnboardingResult {
  OnboardingResult({
    required this.profile,
    required this.races,
    this.goal,
  });

  final RunnerProfile profile;
  final List<RaceResult> races;
  final GoalRace? goal;
}

/// Five steps: about you, running history, race data, goal race, review.
///
/// Steps 3 and 4 are both skippable. Asking for four PBs and a goal race
/// sounds reasonable, but most runners have one of the two and not the other,
/// and a form that insists on completeness is a form people abandon.
///
/// The field bodies live in `ProfileEditor` and `RaceEditor`, which the
/// post-onboarding edit screen also uses. This wizard owns only the step chrome
/// and the review summary.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onComplete});

  final void Function(OnboardingResult result) onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pager = PageController();
  int _step = 0;

  // Steps 1 and 2 are the same form, split across two steps for pacing. The
  // draft lives here so moving between them does not lose anything.
  RunnerProfile? _profile;

  List<RaceResult> _races = const [];

  // Step 4 — owned by the shared GoalEditor, which emits the whole goal.
  GoalRace? _draftGoal;

  bool get _isLast => _step == 4;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _next() {
    FocusScope.of(context).unfocus();
    if (_isLast) {
      _finish();
      return;
    }
    setState(() => _step++);
    _pager.animateToPage(
      _step,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _back() {
    if (_step == 0) return;
    FocusScope.of(context).unfocus();
    setState(() => _step--);
    _pager.animateToPage(
      _step,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _finish() {
    // A profile is emitted on the first keystroke, so this only has to handle a
    // runner who walked straight through without typing.
    final profile = _profile ??
        const RunnerProfile(
          name: 'Runner',
          age: 30,
          gender: Gender.preferNotToSay,
          monthsRunning: 6,
          daysPerWeek: 3,
        );
    widget.onComplete(
      OnboardingResult(
        profile: profile,
        races: _races,
        goal: _draftGoal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              step: _step,
              total: 5,
              onBack: _step == 0 ? null : _back,
            ),
            Expanded(
              child: PageView(
                controller: _pager,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _stepAbout(),
                  _stepHistory(),
                  _stepRaces(),
                  _stepGoal(),
                  _stepReview(),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.md,
              ),
              decoration: const BoxDecoration(
                color: AppColors.bg,
                border: Border(
                  top: BorderSide(color: AppColors.hairline),
                ),
              ),
              child: Row(
                children: [
                  if (_step > 0) ...[
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: OutlinedButton(
                        onPressed: _back,
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          side: const BorderSide(color: AppColors.hairlineStrong),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.control),
                          ),
                        ),
                        child: const Icon(Icons.arrow_back, size: 20),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm + 2),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(
                        _isLast ? 'Build my plan' : 'Continue',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The first two steps are one form, split across two steps for pacing.
  ///
  /// Each step renders only its own section, and each carries its own heading.
  /// A shared widget is only worth sharing if it can render a *part* of itself —
  /// otherwise the two steps are the same form twice, which is what a naive
  /// extraction produces.
  Widget _stepAbout() {
    return _Scroll(
      children: [
        const _StepTitle(
          'About you',
          'A few basics so the plan fits the person doing it.',
        ),
        ProfileEditor(
          value: _profile,
          section: ProfileSection.aboutYou,
          onChanged: (v) => _profile = v,
        ),
      ],
    );
  }

  Widget _stepHistory() {
    return _Scroll(
      children: [
        const _StepTitle(
          'Your running',
          'This decides which kind of plan you get. There is no wrong answer.',
        ),
        ProfileEditor(
          value: _profile,
          section: ProfileSection.runningHistory,
          showName: false,
          onChanged: (v) => _profile = v,
        ),
      ],
    );
  }

  Widget _stepRaces() {
    return _Scroll(
      children: [
        const _StepTitle(
          'Race times',
          'The more recent data you give, the more accurate your paces will '
          'be. One good race is enough — we will work out the rest.',
        ),
        RaceEditor(
          value: _races,
          onChanged: (v) => _races = v,
        ),
      ],
    );
  }

  Widget _stepGoal() {
    return _Scroll(
      children: [
        const _StepTitle(
          'A race to train for',
          'A goal changes the plan completely — the paces, the length of the '
          'block, and how hard it builds. Optional either way.',
        ),
        // The same component the post-onboarding edit flow uses, so the two
        // cannot drift apart.
        GoalEditor(
          value: _draftGoal,
          onChanged: (v) => setState(() => _draftGoal = v),
        ),
        if (_draftGoal == null) ...[
          const SizedBox(height: AppSpacing.lg),
          const Callout(
            'Your plan is built the moment you tap below, and you can change '
            'the goal afterwards without redoing this form.',
          ),
        ],
      ],
    );
  }

  Widget _stepReview() {
    final profile = _profile ??
        const RunnerProfile(
          name: 'Runner',
          age: 30,
          gender: Gender.preferNotToSay,
          monthsRunning: 6,
          daysPerWeek: 3,
        );
    final byDistance = {for (final r in _races) r.distance: r.time};
    final dates = {for (final r in _races) r.distance: r.date};

    return _Scroll(
      children: [
        const _StepTitle('All set', 'Here is what we have.'),
        _ReviewCard(
          rows: [
            ('Name', profile.name, false),
            ('Age', '${profile.age}', false),
            ('Running for', _monthsLabel(profile.monthsRunning), false),
            ('Days a week', '${profile.daysPerWeek}', false),
            (
              'Weekly volume',
              profile.estimatedWeeklyKm == null
                  ? 'Estimated from race times'
                  : '${formatKm(profile.estimatedWeeklyKm!)} km',
              profile.estimatedWeeklyKm == null,
            ),
            if (profile.heightCm != null)
              ('Height', '${formatKm(profile.heightCm!)} cm', false),
            if (profile.weightKg != null)
              ('Weight', '${formatKm(profile.weightKg!)} kg', false),
          ],
        ),
        const SectionHeader('Race times'),
        _ReviewCard(
          rows: [
            for (final d in RaceDistance.values)
              (
                d.label,
                byDistance[d] == null
                    ? '—'
                    : formatDuration(byDistance[d]!),
                byDistance[d] == null,
              ),
          ],
        ),
        const SectionHeader('Goal race'),
        if (_draftGoal == null)
          _ReviewCard(
            rows: [('None set', 'Base block', true)],
          )
        else
          _ReviewCard(
            rows: [
              ('Race', _draftGoal!.distance.label, false),
              ('Date', formatDate(_draftGoal!.date), false),
              ('Target', formatTimeInput(_draftGoal!.finishTimeGoal), false),
              ('Training days', '${_draftGoal!.daysPerWeek}', false),
            ],
          ),
        if (dates.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Callout(
            'Oldest result: ${formatDate(
              dates.values.reduce((a, b) => a.isBefore(b) ? a : b),
            )}. Results older than six months are not used to set your paces.',
            icon: Icons.info_outline,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        const Callout(
          'Your plan is built the moment you tap below. You can change your '
          'details or your goal afterwards without redoing this form.',
        ),
      ],
    );
  }

  static String _monthsLabel(int m) {
    if (m < 12) return '$m month${m == 1 ? '' : 's'}';
    final y = m / 12;
    return '${y.toStringAsFixed(y < 2 ? 1 : 0)} years';
  }
}

/// Wizard header with a segmented step rail.
///
/// Replaces the `LinearProgressIndicator` used before, which is the stock
/// control and reads as a browser loading bar rather than as a wizard.
class _Header extends StatelessWidget {
  const _Header({required this.step, required this.total, this.onBack});

  final int step;
  final int total;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                if (onBack != null)
                  GestureDetector(
                    onTap: onBack,
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: Icon(Icons.arrow_back, size: 20),
                    ),
                  ),
                Expanded(
                  child: Text(
                    'STEP ${step + 1} OF $total',
                    style: theme.label.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (var i = 0; i < total; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    height: 3,
                    decoration: BoxDecoration(
                      gradient: i <= step
                          ? const LinearGradient(
                              colors: [AppColors.brand, AppColors.brandAccent],
                            )
                          : null,
                      color: i <= step ? null : AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Scroll extends StatelessWidget {
  const _Scroll({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        children: children,
      );
}

class _StepTitle extends StatelessWidget {
  const _StepTitle(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.display.copyWith(fontSize: 30)),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: theme.bodyMuted.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.rows});

  final List<(String, String, bool)> rows;

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
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
                        color: rows[i].$3
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The about-you and running-history form, as a controlled component.
///
/// Extracted from the onboarding wizard for the same reason `GoalEditor` is:
/// the wizard and the post-onboarding edit flow ask for exactly the same things,
/// and two copies of a form start disagreeing within a month. The edit screen
/// composes this; it does not have its own version.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/profile.dart';
import '../theme.dart';

/// Which slice of the profile a form is showing.
///
/// The wizard splits these across two steps for pacing, so the editor has to be
/// able to render either half on its own. The first attempt at this used a
/// `showName` flag, which hid exactly one field and made step 2 a near-copy of
/// step 1 — same heading, same age question, everything else included. A boolean
/// cannot describe "the other half of the form"; an enum can.
enum ProfileSection {
  /// Name, age, gender — who is running.
  aboutYou,

  /// How long, how often, how much, and the optional measurements.
  runningHistory,

  /// Everything. The edit screen has no reason to hide half of it.
  all,
}

/// The profile form, emitted whole on every change.
///
/// [value] is nullable so the wizard can start from a blank form. Once set, the
/// caller gets a complete profile back on each keystroke — there is no partial
/// state to reconcile, which is what makes the same widget usable in both the
/// wizard and the edit screen.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.section = ProfileSection.all,
    this.showName = true,
  });

  /// Current profile, or null before the runner has supplied anything.
  final RunnerProfile? value;

  final ValueChanged<RunnerProfile> onChanged;

  /// Which fields to render. [ProfileSection.all] shows the whole form.
  final ProfileSection section;

  /// Whether to ask for a name at all.
  final bool showName;

  bool get _showsAbout => section != ProfileSection.runningHistory;

  bool get _showsHistory => section != ProfileSection.aboutYou;

  /// Readable name for a stored gender value. Lives on the widget so the details
  /// screen labels the field the same way the form does.
  static String genderLabel(Gender g) => switch (g) {
        Gender.female => 'Female',
        Gender.male => 'Male',
        Gender.other => 'Other',
        Gender.preferNotToSay => 'Prefer not to say',
      };

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final _name = TextEditingController();
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _weeklyKm = TextEditingController();

  int _age = 30;
  Gender _gender = Gender.preferNotToSay;

  /// Years, not months. The model stores months; the form speaks in the unit a
  /// person actually counts in. See the counter below.
  int _yearsRunning = 1;
  int _daysPerWeek = 3;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void didUpdateWidget(ProfileEditor old) {
    super.didUpdateWidget(old);
    // Resync only when the incoming value really changes underneath us, or every
    // keystroke would reset the field being typed into.
    if (widget.value != old.value) _seed();
  }

  void _seed() {
    final v = widget.value;
    _name.text = v?.name ?? '';
    _height.text = v?.heightCm?.toString() ?? '';
    _weight.text = v?.weightKg?.toString() ?? '';
    _weeklyKm.text = v?.estimatedWeeklyKm?.toString() ?? '';
    _age = v?.age ?? 30;
    _gender = v?.gender ?? Gender.preferNotToSay;
    // Round up: someone who has run for 18 months is not a beginner, and
    // truncating to 1 year would put them on the wrong side of the gate.
    _yearsRunning = (((v?.monthsRunning ?? 12) / 12).ceil()).clamp(0, 40);
    _daysPerWeek = v?.daysPerWeek ?? 3;
  }

  /// Spells out what the answer means, in the same unit it was asked in.
  String get _yearsRunningLabel {
    if (_yearsRunning <= 0) {
      return 'Just starting — you will begin with a base block.';
    }
    if (_yearsRunning < 1) return 'Under a year — base block.';
    if (_yearsRunning == 1) {
      return 'A year — you will get a full periodised plan.';
    }
    if (_yearsRunning < 10) {
      return '$_yearsRunning years — a full periodised plan, with hard '
          'sessions every week.';
    }
    return '$_yearsRunning years — a full periodised plan.';
  }

  int get _monthsRunningFromForm => _yearsRunning * 12;

  @override
  void dispose() {
    _name.dispose();
    _height.dispose();
    _weight.dispose();
    _weeklyKm.dispose();
    super.dispose();
  }

  /// Emits the whole profile from whatever is currently in the form.
  ///
  /// Optional fields are cleared by emptying the box, which is the only honest
  /// reading of an empty field: the runner said they do not have that number.
  void _emit() {
    final name = _name.text.trim();
    widget.onChanged(RunnerProfile(
      name: name.isEmpty ? 'Runner' : name,
      age: _age,
      gender: _gender,
      monthsRunning: _monthsRunningFromForm,
      daysPerWeek: _daysPerWeek,
      heightCm: double.tryParse(_height.text.trim()),
      weightKg: double.tryParse(_weight.text.trim()),
      estimatedWeeklyKm: double.tryParse(_weeklyKm.text.trim()),
    ));
  }

  /// Days a week times a plausible per-run distance, used to explain what the
  /// weekly-volume field is actually for.
  static double _typicalKm(int days) => (days * 5.0).clamp(5.0, 45.0);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget._showsAbout) _buildAboutYou(),
        if (widget._showsAbout && widget._showsHistory)
          const SizedBox(height: AppSpacing.lg),
        if (widget._showsHistory) _buildRunningHistory(),
      ],
    );
  }

  Widget _buildAboutYou() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showName) ...[
          TextField(
            key: const Key('profile-name'),
            controller: _name,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _emit(),
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'What should we call you?',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        const FieldLabel('Age'),
        const SizedBox(height: AppSpacing.sm),
        Counter(
          value: _age,
          min: 12,
          max: 100,
          onChanged: (v) {
            setState(() => _age = v);
            _emit();
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Gender'),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final g in Gender.values)
              Pill(
                label: ProfileEditor.genderLabel(g),
                selected: _gender == g,
                onTap: () {
                  setState(() => _gender = g);
                  _emit();
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const Callout(
          'Gender is not used in the maths — the plan is driven by the paces '
          'your race times imply. It is stored only so you can see it later.',
        ),
      ],
    );
  }

  Widget _buildRunningHistory() {
    final theme = Theme.of(context);
    final typical = _typicalKm(_daysPerWeek);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('How long have you been running regularly?'),
        const SizedBox(height: AppSpacing.sm),
        // Counted in YEARS, not months.
        //
        // This was a bare month counter, and someone with three years' training
        // entered "3" — which the plan read as three *months*, routed them to
        // the beginner base block, and gave a runner with a 1:56 half marathon
        // twelve weeks containing no hard sessions at all. The unit was never
        // stated and three is a perfectly natural answer to "how long" if you
        // think in years.
        //
        // The 12-month gate in `isBeginnerPath` is exactly a one-year boundary,
        // so years are also the unit that maps onto the decision.
        Counter(
          key: const Key('profile-years'),
          value: _yearsRunning.clamp(0, 40),
          min: 0,
          max: 40,
          onChanged: (v) {
            setState(() => _yearsRunning = v);
            _emit();
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _yearsRunningLabel,
          style: theme.bodyMuted.copyWith(fontSize: 13),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('How many days a week do you run now?'),
        const SizedBox(height: AppSpacing.sm),
        Counter(
          value: _daysPerWeek,
          min: 1,
          max: 7,
          onChanged: (v) {
            setState(() => _daysPerWeek = v);
            _emit();
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Roughly how many km a week do you run?'),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          key: const Key('profile-weekly-km'),
          controller: _weeklyKm,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onChanged: (_) => _emit(),
          decoration: InputDecoration(
            hintText: typical.toStringAsFixed(0),
            helperMaxLines: 3,
            helperText: 'Optional, but it matters more than you would think. '
                'It sets how much your plan starts from, so leave it blank and '
                'we guess from your race times instead — which is why a 15 km '
                'runner can end up with a 30 km week.',
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Height and weight (optional)'),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('profile-height'),
                controller: _height,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (_) => _emit(),
                decoration: const InputDecoration(labelText: 'Height (cm)'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm + 4),
            Expanded(
              child: TextField(
                key: const Key('profile-weight'),
                controller: _weight,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (_) => _emit(),
                decoration: const InputDecoration(labelText: 'Weight (kg)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Used only for context. The plan is driven by your race times.',
          style: theme.bodyMuted.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}

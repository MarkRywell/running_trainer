import 'package:flutter/material.dart';

import '../../domain/models/goal.dart';
import '../../domain/models/race.dart';
import '../../domain/units.dart';
import '../theme.dart';

/// The goal-race form, as a controlled component.
///
/// Extracted from the onboarding wizard so the wizard and the post-onboarding
/// edit flow cannot drift apart — they ask for exactly the same four things,
/// and duplicating that form is how the two versions start disagreeing.
///
/// Emits `null` when no distance is chosen, which is the "no goal" state. All
/// other fields are retained locally so a half-filled form is not lost when
/// the user is between steps.
class GoalEditor extends StatefulWidget {
  const GoalEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.minimumDate,
  });

  final GoalRace? value;

  /// Called on every change, including with `null` when the goal is cleared.
  final ValueChanged<GoalRace?> onChanged;

  /// Earliest selectable race date. Defaults to today.
  final DateTime? minimumDate;

  @override
  State<GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends State<GoalEditor> {
  final _time = TextEditingController();
  RaceDistance? _distance;
  DateTime? _date;
  int _days = 4;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void didUpdateWidget(GoalEditor old) {
    super.didUpdateWidget(old);
    // Resync only when the incoming value actually changes underneath us —
    // otherwise every keystroke would reset the field being typed into.
    if (widget.value != old.value) _seed();
  }

  void _seed() {
    final v = widget.value;
    if (v == null) {
      // Today. The goal is almost never a year out, and the picker's `firstDate`
      // is today, so defaulting 126 days ahead meant the control opened on a
      // month the runner then had to scroll backwards out of — reading as though
      // the app had picked a race date for them.
      final d = DateTime.now();
      setState(() {
        _distance = null;
        _date = DateTime(d.year, d.month, d.day);
        _days = 4;
        _time.clear();
      });
    } else {
      setState(() {
        _distance = v.distance;
        _date = v.date;
        _days = v.daysPerWeek;
        _time.text = formatTimeInput(v.finishTimeGoal);
      });
    }
  }

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  void _emit() {
    final d = _distance;
    final date = _date;
    if (d == null || date == null) {
      widget.onChanged(null);
      return;
    }
    final t = parseTimeInput(_time.text);
    if (t == null) {
      // Distance and date are set but the time is not parseable yet. Emit the
      // previous finish time rather than losing the rest of the goal.
      final previous = widget.value;
      if (previous == null) return;
      widget.onChanged(GoalRace(
        distance: d,
        date: date,
        finishTimeGoal: previous.finishTimeGoal,
        daysPerWeek: _days,
      ));
      return;
    }
    widget.onChanged(GoalRace(
      distance: d,
      date: date,
      finishTimeGoal: t,
      daysPerWeek: _days,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _distance;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel('Race distance'),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final d in RaceDistance.values)
              Pill(
                label: d.label,
                selected: selected == d,
                onTap: () {
                  setState(() => _distance = selected == d ? null : d);
                  _emit();
                },
              ),
          ],
        ),
        if (selected == null) ...[
          const SizedBox(height: AppSpacing.lg),
          const Callout(
            'No goal is fine. You will get a general base block, and you can '
            'add a race later without losing anything.',
          ),
        ] else ...[
          const SizedBox(height: AppSpacing.lg),
          FieldLabel('Race date'),
          const SizedBox(height: AppSpacing.sm),
          _DateButton(
            label: formatDate(_date!),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date!,
                firstDate: widget.minimumDate ?? DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 730)),
              );
              if (picked != null) {
                setState(() => _date = picked);
                _emit();
              }
            },
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FieldLabel('Finish time goal'),
                    const SizedBox(height: 6),
                    Text(
                      _weeksOut(_date!),
                      style: theme.bodyMuted.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _time,
            style: theme.tabular.copyWith(fontSize: 18),
            onChanged: (_) => _emit(),
            decoration: const InputDecoration(
              hintText: '3:45:00',
              helperText: 'Your ambition, not a prediction. We will check it '
                  'against your current fitness and tell you honestly.',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FieldLabel('How many days a week can you train?'),
          const SizedBox(height: AppSpacing.sm),
          Counter(
            value: _days,
            min: 1,
            max: 6,
            onChanged: (v) {
              setState(() => _days = v);
              _emit();
            },
          ),
        ],
      ],
    );
  }

  static String _weeksOut(DateTime date) {
    final days = date.difference(DateTime.now()).inDays;
    if (days <= 0) return 'That date has passed';
    final w = days ~/ 7;
    return '$w week${w == 1 ? '' : 's'} of runway';
  }
}

/// Bottom sheet for editing the goal after onboarding.
///
/// Save and Clear are explicit rather than applying on every keystroke, so a
/// half-typed finish time cannot silently become the runner's target.
Future<bool?> showGoalEditor(
  BuildContext context, {
  required GoalRace? current,
  required ValueChanged<GoalRace?> onSave,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(ctx).viewInsets.bottom,
      ),
      child: _GoalEditorSheet(
        current: current,
        onSave: (v) {
          onSave(v);
          Navigator.pop(ctx, true);
        },
      ),
    ),
  );
}

/// Holds the draft so Save applies exactly what the form currently shows.
///
/// Applying on every keystroke would let a half-typed finish time silently
/// become the runner's target, which is not a trade worth making for one
/// button press.
class _GoalEditorSheet extends StatefulWidget {
  const _GoalEditorSheet({required this.current, required this.onSave});

  final GoalRace? current;
  final ValueChanged<GoalRace?> onSave;

  @override
  State<_GoalEditorSheet> createState() => _GoalEditorSheetState();
}

class _GoalEditorSheetState extends State<_GoalEditorSheet> {
  GoalRace? _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.current;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Goal race', style: theme.display.copyWith(fontSize: 24)),
              const SizedBox(height: 4),
              Text(
                widget.current == null
                    ? 'Set a race and the whole plan is rebuilt around it.'
                    : 'Changing this rebuilds the plan from week 1.',
                style: theme.bodyMuted,
              ),
              const SizedBox(height: AppSpacing.lg),
              GoalEditor(
                value: _draft,
                onChanged: (v) => setState(() => _draft = v),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  if (widget.current != null) ...[
                    SizedBox(
                      height: 56,
                      child: OutlinedButton(
                        onPressed: () => widget.onSave(null),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          side: const BorderSide(color: AppColors.hairlineStrong),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.control),
                          ),
                        ),
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm + 2),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: () => widget.onSave(_draft),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable date field. A plain outlined box with a calendar glyph, sized to
/// sit inline with the other controls.
class _DateButton extends StatelessWidget {
  const _DateButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: AppColors.hairlineStrong),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.body.copyWith(fontSize: 15),
                ),
              ),
              const Icon(
                Icons.calendar_today_outlined,
                size: 15,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

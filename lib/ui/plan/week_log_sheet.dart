import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/plan.dart';
import '../../domain/models/week_log.dart';
import '../../domain/units.dart';
import '../theme.dart';

/// Record what actually happened in a week.
///
/// Deliberately all-optional. A runner who just wants to tick the box should
/// be able to do that from the week header without ever opening this, and
/// nothing here is required.
Future<void> showWeekLogSheet(
  BuildContext context, {
  required PlanWeek week,
  required WeekLog initial,
  required ValueChanged<WeekLog> onSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _WeekLogSheet(week: week, initial: initial, onSave: onSave),
    ),
  );
}

class _WeekLogSheet extends StatefulWidget {
  const _WeekLogSheet({
    required this.week,
    required this.initial,
    required this.onSave,
  });

  final PlanWeek week;
  final WeekLog initial;
  final ValueChanged<WeekLog> onSave;

  @override
  State<_WeekLogSheet> createState() => _WeekLogSheetState();
}

class _WeekLogSheetState extends State<_WeekLogSheet> {
  late bool _completed = widget.initial.completed;
  late int? _difficulty = widget.initial.difficulty;
  late final _km = TextEditingController(
    text: widget.initial.actualKm?.toStringAsFixed(1) ??
        formatKm(widget.week.targetVolumeKm),
  );
  late int _sessions = widget.initial.sessionsDone ?? widget.week.runCount;
  late final _note = TextEditingController(text: widget.initial.note ?? '');

  @override
  void dispose() {
    _km.dispose();
    _note.dispose();
    super.dispose();
  }

  WeekLog _build() {
    final km = double.tryParse(_km.text.trim().replaceAll(',', '.'));
    return WeekLog(
      completed: _completed,
      actualKm: km != null && km > 0 ? km : null,
      sessionsDone: _sessions,
      difficulty: _difficulty,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );
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
              Row(
                children: [
                  ZoneSwatch(phaseZone(widget.week.phase), size: 10),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Log week ${widget.week.weekNumber}',
                      style: theme.display.copyWith(fontSize: 22),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Every field here is optional. Tick the box and move on if '
                'that is all you want to do.',
                style: theme.bodyMuted,
              ),
              const SizedBox(height: AppSpacing.lg),
              _DoneRow(
                value: _completed,
                onChanged: (v) => setState(() => _completed = v),
              ),
              const SizedBox(height: AppSpacing.lg),
              _Label('How many sessions did you get through?'),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    '$_sessions',
                    style: theme.display.copyWith(fontSize: 30),
                  ),
                  Text(
                    ' / ${widget.week.runCount}',
                    style: theme.bodyMuted.copyWith(
                      fontSize: 15,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),              const SizedBox(height: 4),
              _SliderRow(
                value: _sessions.toDouble(),
                max: widget.week.runCount.toDouble().clamp(1, 14),
                onChanged: (v) => setState(() => _sessions = v.round()),
              ),
              const SizedBox(height: AppSpacing.lg),
              _Label('Distance actually run'),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _km,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      style: theme.tabular.copyWith(fontSize: 18),
                      decoration: InputDecoration(
                        suffixText: 'km',
                        helperText:
                            'Planned ${formatKm(widget.week.targetVolumeKm)} km',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _Label('How hard did the week feel?'),
              const SizedBox(height: 4),
              Text(
                'This is the most useful thing you can tell us. If it kept '
                'feeling too hard, the plan is wrong — not you.',
                style: theme.bodyMuted.copyWith(fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 10),
              _DifficultyScale(
                value: _difficulty,
                onChanged: (v) => setState(() => _difficulty = v),
              ),
              const SizedBox(height: AppSpacing.lg),
              _Label('Anything worth noting? (optional)'),
              const SizedBox(height: 6),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: 'Knee, holiday, life happened…',
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: () {
                  widget.onSave(_build());
                  Navigator.pop(context);
                },
                child: const Text('Save log'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: value ? AppColors.success : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(
              color: value ? AppColors.success : AppColors.hairlineStrong,
            ),
          ),
          child: Row(
            children: [
              Icon(
                value ? Icons.check_circle : Icons.circle_outlined,
                color: value ? AppColors.bg : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'I completed this week',
                  style: theme.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: value ? AppColors.bg : AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 1–10 difficulty, as discrete segments rather than a slider.
///
/// A ten-point scale across a 400 px phone gives ~32 px per division, which
/// is far too fiddly to hit — and a scale this subjective needs to be
/// answerable in one tap, not after careful dragging.
class _DifficultyScale extends StatelessWidget {
  const _DifficultyScale({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int> onChanged;

  static const _labels = {
    1: 'Very easy',
    2: 'Too easy',
    4: 'Comfortable',
    5: 'About right',
    6: 'Hard',
    8: 'Too hard',
    10: 'Brutal',
  };

  static String _labelFor(int v) {
    final thresholds = _labels.keys.toList()..sort();
    var label = 'Very easy';
    for (final t in thresholds) {
      if (v >= t) label = _labels[t]!;
    }
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value ?? 5;
    final label = _labelFor(v);
    final tooHard = v >= 8;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '$v',
              style: theme.display.copyWith(
                fontSize: 26,
                color: tooHard ? AppColors.brandAccent : AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                style: theme.body.copyWith(
                  fontSize: 13,
                  color: tooHard ? AppColors.brandAccent : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var n = 1; n <= 10; n++) ...[
              if (n > 1) const SizedBox(width: 3),
              Expanded(
                child: GestureDetector(
                  key: Key('difficulty-$n'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(n),
                  child: Container(
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: n <= v
                          ? (tooHard ? AppColors.brandAccent : AppColors.brand)
                              .withValues(alpha: n <= v - 2 ? 1.0 : 0.45)
                          : AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$n',
                      style: theme.tabular.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: n <= v ? AppColors.onBrand : AppColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (tooHard) ...[
          const SizedBox(height: 8),
          Text(
            'Noted. If this keeps happening we will suggest easing the plan.',
            style: theme.bodyMuted.copyWith(fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        child: Slider(
          value: value.clamp(0, max),
          max: max,
          divisions: max.round().clamp(1, 14),
          activeColor: AppColors.brand,
          inactiveColor: AppColors.surfaceHigh,
          onChanged: onChanged,
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).label.copyWith(
              color: AppColors.textSecondary,
            ),
      );
}

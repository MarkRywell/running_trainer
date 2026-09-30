/// The race-time form, as a controlled component.
///
/// Extracted from the wizard for the same reason as `ProfileEditor`: the
/// onboarding and edit flows must ask for identical things, and a second copy
/// of a form is a second set of rules to keep in sync.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/race.dart';
import '../../domain/units.dart';
import '../theme.dart';

/// One field per distance, with a date on each.
///
/// Emits only the races that have both a parseable time and a date. A half-typed
/// entry is *not* emitted — it reads as "not supplied" rather than as a
/// completion, so a runner mid-entry never has their plan rebuilt on a partial
/// time.
class RaceEditor extends StatefulWidget {
  const RaceEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final List<RaceResult> value;
  final ValueChanged<List<RaceResult>> onChanged;

  @override
  State<RaceEditor> createState() => _RaceEditorState();
}

class _RaceEditorState extends State<RaceEditor> {
  final _times = <RaceDistance, TextEditingController>{};
  final _hrs = <RaceDistance, TextEditingController>{};
  final _dates = <RaceDistance, DateTime>{};

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void didUpdateWidget(RaceEditor old) {
    super.didUpdateWidget(old);
    if (!identical(widget.value, old.value)) _seed();
  }

  void _seed() {
    for (final d in RaceDistance.values) {
      _times[d]?.dispose();
      _hrs[d]?.dispose();
      _times[d] = TextEditingController();
      _hrs[d] = TextEditingController();
      // Today, not two months ago. The date picker's `lastDate` is today, so
      // defaulting further back made the control open on a month the runner had
      // to scroll forward out of, and it read as though the app had decided when
      // they raced.
      _dates[d] = DateTime.now();
    }
    for (final r in widget.value) {
      _times[r.distance]!.text = formatTimeInput(r.time);
      if (r.averageHr != null) _hrs[r.distance]!.text = '${r.averageHr}';
      _dates[r.distance] = r.date;
    }
  }

  @override
  void dispose() {
    for (final c in _times.values) {
      c.dispose();
    }
    for (final c in _hrs.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final races = <RaceResult>[];
    for (final d in RaceDistance.values) {
      final t = parseTimeInput(_times[d]!.text);
      if (t == null) continue;
      races.add(RaceResult(
        distance: d,
        time: t,
        date: _dates[d]!,
        averageHr: int.tryParse(_hrs[d]!.text.trim()),
      ));
    }
    widget.onChanged(races);
  }

  String _age(RaceDistance d) {
    final days = DateTime.now().difference(_dates[d]!).inDays;
    if (days > 365) return 'Over a year old';
    if (days > 30) return '${(days / 30).round()} months ago';
    return 'Recent';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final d in RaceDistance.values) ...[
          RaceField(
            distance: d,
            controller: _times[d]!,
            date: _dates[d]!,
            dateLabel: _age(d),
            hrController: _hrs[d]!,
            onChanged: (_) => _emit(),
            onPickDate: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _dates[d]!,
                firstDate: DateTime.now().subtract(const Duration(days: 3650)),
                lastDate: DateTime.now(),
              );
              if (picked != null) {
                setState(() => _dates[d] = picked);
                _emit();
              }
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Leave anything blank you are not sure about.',
          style: theme.bodyMuted.copyWith(fontSize: 12),
        ),
        const SizedBox(height: AppSpacing.sm),
        const Callout(
          'A heart rate is optional and is never used to build anything. Your '
          'pacing comes from your finish times, which are a far more reliable '
          'measure of fitness than a heart rate — and a heart rate depends on '
          'which device you wore and how hot it was. We keep it only so we can '
          'point out a goal that asks more than you have run before.',
        ),
      ],
    );
  }
}

/// One distance's time and date.
///
/// Public because the onboarding review step renders the same shape read-only,
/// and a private copy of this card in two files is the drift this extraction
/// exists to prevent.
class RaceField extends StatelessWidget {
  const RaceField({
    super.key,
    required this.distance,
    required this.controller,
    required this.date,
    required this.onPickDate,
    required this.dateLabel,
    this.hrController,
    this.onChanged,
  });

  final RaceDistance distance;
  final TextEditingController controller;
  final TextEditingController? hrController;
  final DateTime date;
  final VoidCallback onPickDate;
  final String dateLabel;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: Key('race-field-${distance.name}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
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
              Expanded(
                child: Text(
                  distance.label,
                  style: theme.title.copyWith(fontSize: 15),
                ),
              ),
              GestureDetector(
                onTap: onPickDate,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    Text(
                      dateLabel,
                      style: theme.bodyMuted.copyWith(fontSize: 11.5),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.edit_calendar_outlined,
                      size: 14,
                      color: AppColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  style: theme.tabular.copyWith(fontSize: 18),
                  decoration: InputDecoration(
                    hintText: switch (distance) {
                      RaceDistance.k5 => '22:30',
                      RaceDistance.k10 => '45:00',
                      RaceDistance.half => '1:45:00',
                      RaceDistance.marathon => '3:30:00',
                    },
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              if (hrController != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: Key('race-hr-${distance.name}'),
                    controller: hrController,
                    onChanged: onChanged,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    style: theme.tabular.copyWith(fontSize: 18),
                    decoration: const InputDecoration(
                      hintText: '165',
                      labelText: 'Avg HR',
                      suffixText: 'bpm',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

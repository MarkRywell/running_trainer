import 'package:flutter/material.dart';

import '../domain/models/plan.dart';

/// Design tokens.
///
/// Every colour in the app comes from here or from [AppTokens]. Nothing is
/// hard-coded in a screen — that is what keeps a redesign from turning into
/// forty small inconsistencies.
///
/// ## Why the scheme is hand-authored
///
/// The previous theme used `ColorScheme.fromSeed`. That derives an entire
/// tonal palette from one seed colour, and the result is the default Flutter
/// look no matter which seed you feed it — the surface tints and container
/// roles all track the seed hue. Every role below is chosen by hand instead,
/// which is the only way to get surfaces that are genuinely neutral and a
/// brand colour that is genuinely the only saturated thing on screen.
abstract final class AppColors {
  // Surfaces. A dark-only app: #0E0D0D is the base, and everything else is a
  // measured step up from it.
  static const bg = Color(0xFF0E0D0D);
  static const surface = Color(0xFF171413);
  static const surfaceRaised = Color(0xFF201C1B);
  static const surfaceHigh = Color(0xFF2A2524);

  /// Hairline borders. Low-alpha white rather than a solid outline colour, so
  /// borders recede instead of drawing boxes.
  static const hairline = Color(0x14FFFFFF);
  static const hairlineStrong = Color(0x24FFFFFF);

  // Brand.
  static const brand = Color(0xFFFF3600);
  static const brandAccent = Color(0xFFFE7A0D);
  static const onBrand = Color(0xFFFFFFFF);

  // Text. Warm whites, not pure grey — pure #FFF on near-black reads harsh.
  static const textPrimary = Color(0xFFF5F1EF);
  static const textSecondary = Color(0xFFA39A96);
  static const textTertiary = Color(0xFF6E6561);

  // Status.
  static const success = Color(0xFF3DD68C);
  static const danger = Color(0xFFFF5470);
}

/// The intensity ramp.
///
/// Deliberately not six unrelated hues. Easy running is the bulk of a plan, so
/// it is cool and desaturated and visually recedes; only the genuinely hard
/// work is allowed to glow. Reading a week becomes a heat gradient rather than
/// a rainbow, and nothing collides with the brand colour.
///
/// The previous palette had two of these as oranges, which meant they fought
/// the brand, and reused one of them for the caution flag severity as well.
abstract final class ZonePalette {
  static const recovery = Color(0xFF4A4442);
  static const easy = Color(0xFF6B7B84);
  static const marathon = Color(0xFFC9792B);
  static const threshold = Color(0xFFFF6A00);
  static const interval = Color(0xFFFF3600);
  static const repetition = Color(0xFFFFB199);

  static Color of(IntensityZone zone) => switch (zone) {
        IntensityZone.recovery => recovery,
        IntensityZone.easy => easy,
        IntensityZone.marathon => marathon,
        IntensityZone.threshold => threshold,
        IntensityZone.interval => interval,
        IntensityZone.repetition => repetition,
      };
}

/// The intensity a plan phase is mostly about, for colour coding.
IntensityZone phaseZone(PlanPhase phase) => switch (phase) {
      PlanPhase.base => IntensityZone.easy,
      PlanPhase.baseBlock => IntensityZone.easy,
      PlanPhase.specific => IntensityZone.marathon,
      PlanPhase.peak => IntensityZone.threshold,
      PlanPhase.taper => IntensityZone.recovery,
      PlanPhase.raceWeek => IntensityZone.repetition,
    };

/// Layout constants. Named rather than scattered as magic numbers.
abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;

  /// Bottom padding for a scrolling screen body.
  ///
  /// A fixed [xl] is measured from the bottom of the *screen*, so on a device
  /// with a gesture bar or a home indicator the last stretch of it sits beneath
  /// the system navigation and the final component is clipped. A Samsung A35 is
  /// ~384x832dp, which is *shorter* than the 400x900 widget surface, so the test
  /// suite cannot see this at all — the last card simply fell off.
  ///
  /// Every scrolling body uses this rather than a literal, because four screens
  /// had the same fixed value and would otherwise drift apart again.
  static double scrollBottom(BuildContext context) =>
      xl + MediaQuery.viewPaddingOf(context).bottom;
}

abstract final class AppRadius {
  static const card = 12.0;
  static const control = 10.0;
  static const sheet = 20.0;
}

/// Type styles, defined in one place so the hierarchy is consistent.
///
/// Named `AppType` rather than `AppTheme` because a class and an extension
/// cannot share a name — the class would shadow the extension and every
/// `theme.display` would fail to resolve.
///
/// The key detail is [AppType.tabular]: times and paces change constantly as
/// a user scrolls, and proportional figures make them jitter sideways. Tabular
/// figures cost nothing and remove it.
extension AppType on ThemeData {
  TextStyle get display => textTheme.displaySmall!.copyWith(
        fontFamily: 'Barlow',
        fontWeight: FontWeight.w700,
        fontSize: 44,
        height: 1.0,
        letterSpacing: -1.5,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: AppColors.textPrimary,
      );

  TextStyle get title => textTheme.titleLarge!.copyWith(
        fontFamily: 'Barlow',
        fontWeight: FontWeight.w600,
        fontSize: 20,
        height: 1.2,
        letterSpacing: -0.4,
        color: AppColors.textPrimary,
      );

  TextStyle get body => textTheme.bodyMedium!.copyWith(
        fontFamily: 'Barlow',
        fontWeight: FontWeight.w400,
        fontSize: 14,
        height: 1.45,
        color: AppColors.textPrimary,
      );

  TextStyle get bodyMuted => body.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w400,
      );

  /// Small uppercase label. The wide tracking is what makes it read as a label
  /// rather than as small body text.
  TextStyle get label => textTheme.labelSmall!.copyWith(
        fontFamily: 'Barlow',
        fontWeight: FontWeight.w600,
        fontSize: 11,
        height: 1.2,
        letterSpacing: 1.2,
        color: AppColors.textTertiary,
      );

  /// Any style carrying a number that will re-render.
  TextStyle get tabular => TextStyle(
        fontFamily: 'Barlow',
        fontFeatures: const [FontFeature.tabularFigures()],
        color: AppColors.textPrimary,
      );
}

class AppTheme {
  /// Dark only. The palette is built for #0E0D0D as the base, and a light
  /// variant would be a second, separately-tuned system rather than an
  /// inversion of this one.
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.brand,
      onPrimary: AppColors.onBrand,
      primaryContainer: Color(0xFF3A1408),
      onPrimaryContainer: AppColors.textPrimary,
      secondary: AppColors.brandAccent,
      onSecondary: AppColors.onBrand,
      secondaryContainer: Color(0xFF3A1E08),
      onSecondaryContainer: AppColors.textPrimary,
      tertiary: AppColors.textSecondary,
      onTertiary: AppColors.bg,
      tertiaryContainer: AppColors.surfaceHigh,
      onTertiaryContainer: AppColors.textPrimary,
      error: AppColors.danger,
      onError: AppColors.onBrand,
      errorContainer: Color(0xFF3A1116),
      onErrorContainer: AppColors.textPrimary,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      surfaceContainerLowest: AppColors.bg,
      surfaceContainerLow: AppColors.surface,
      surfaceContainer: AppColors.surfaceRaised,
      surfaceContainerHigh: AppColors.surfaceHigh,
      surfaceContainerHighest: Color(0xFF322C2B),
      surfaceTint: Colors.transparent,
      inverseSurface: AppColors.textPrimary,
      onInverseSurface: AppColors.bg,
      inversePrimary: AppColors.brandAccent,
      outline: AppColors.hairlineStrong,
      outlineVariant: AppColors.hairline,
      scrim: Color(0xCC000000),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: 'Barlow',
      scaffoldBackgroundColor: AppColors.bg,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: 'Barlow',
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        // No scrolled-under elevation: a hairline divider replaces it, which
        // is calmer than a shadow band appearing under the bar.
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.textPrimary),
        titleTextStyle: TextStyle(
          fontFamily: 'Barlow',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: const BorderSide(color: AppColors.hairline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.hairline,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: AppColors.onBrand,
          disabledBackgroundColor: AppColors.surfaceHigh,
          disabledForegroundColor: AppColors.textTertiary,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Barlow',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          textStyle: const TextStyle(
            fontFamily: 'Barlow',
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.textTertiary),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        helperStyle: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 12,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: const BorderSide(color: AppColors.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: const BorderSide(color: AppColors.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: const BorderSide(color: AppColors.brand, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceRaised,
        side: const BorderSide(color: AppColors.hairline),
        labelStyle: const TextStyle(
          fontFamily: 'Barlow',
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: TextStyle(
          fontFamily: 'Barlow',
          color: AppColors.textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
    );
  }
}

/// A coloured rule marking a session's intensity.
///
/// Replaces the pill badge used previously: a vertical rule reads faster than
/// a rounded chip and takes up a third of the width, which matters at phone
/// widths.
class ZoneRule extends StatelessWidget {
  const ZoneRule(this.zone, {super.key, this.width = 3});

  final IntensityZone zone;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        decoration: BoxDecoration(
          color: ZonePalette.of(zone),
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

/// Small square swatch, for lists where a full rule is too heavy.
class ZoneSwatch extends StatelessWidget {
  const ZoneSwatch(this.zone, {super.key, this.size = 10});

  final IntensityZone zone;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: ZonePalette.of(zone),
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, AppSpacing.lg, 0, AppSpacing.sm),
      child: Row(
        children: [
          // Flexible rather than Expanded: a long title must be able to
          // shrink and wrap, but the trailing widget may legitimately be
          // wider than half the row.
          Flexible(
            child: Text(
              title.toUpperCase(),
              style: theme.label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// An uppercase field label.
///
/// Shared rather than per-file: the wizard, the goal editor and the profile
/// editor all need one, and three private copies is three chances for the
/// spacing to drift.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).label.copyWith(color: AppColors.textSecondary),
      );
}

/// A selectable pill, replacing `ChoiceChip`.
///
/// Chip's default padding and outline treatment are one of the clearest signs
/// of an unstyled Flutter app, and these need to sit tighter anyway.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.brand : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(
            color: selected ? AppColors.brand : AppColors.hairlineStrong,
          ),
        ),
        child: Text(
          label,
          style: theme.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.onBrand : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// A −/value/+ stepper for a bounded integer.
class Counter extends StatelessWidget {
  const Counter({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        _StepButton(
          icon: Icons.remove,
          onTap: value > min ? () => onChanged(value - 1) : null,
        ),
        Expanded(
          child: Center(
            child: Text('$value', style: theme.display.copyWith(fontSize: 30)),
          ),
        ),
        _StepButton(
          icon: Icons.add,
          onTap: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? AppColors.surfaceHigh : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: SizedBox(
          width: 56,
          height: 52,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// A callout for explanatory or advisory text.
///
/// Borderless with a left rule, rather than the filled `surfaceContainerHighest`
/// box used before — the old treatment read as a disabled input.
class Callout extends StatelessWidget {
  const Callout(
    this.text, {
    super.key,
    this.accent = AppColors.textTertiary,
    this.icon,
  });

  final String text;
  final Color accent;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border(left: BorderSide(color: accent, width: 2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: accent),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              text,
              style: theme.bodyMuted.copyWith(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders a plan flag with severity-appropriate colour.
class FlagCard extends StatelessWidget {
  const FlagCard(this.flag, {super.key});

  final PlanFlag flag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (flag.severity) {
      FlagSeverity.warning => (AppColors.danger, Icons.warning_amber_rounded),
      FlagSeverity.caution => (AppColors.brandAccent, Icons.info_outline_rounded),
      FlagSeverity.info => (AppColors.textSecondary, Icons.lightbulb_outline_rounded),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  flag.title,
                  style: theme.title.copyWith(
                    fontSize: 15,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            flag.detail,
            style: theme.bodyMuted.copyWith(height: 1.5),
          ),
          if (flag.suggestedDistance != null || flag.suggestedDate != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (flag.suggestedDistance != null)
                  Chip(
                    avatar: const Icon(Icons.straighten, size: 14),
                    label: Text('Try ${flag.suggestedDistance!.label}'),
                    visualDensity: VisualDensity.compact,
                  ),
                if (flag.suggestedDate != null)
                  Chip(
                    avatar: const Icon(Icons.event, size: 14),
                    label: Text('or ${_date(flag.suggestedDate!)}'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime d) => '${d.day}/${d.month}/${d.year}';
}

/// Item 89 (audit Section 11): ek deliberate visual system — spacing/radius
/// tokens, typography scale, light + dark themes, semantic (success/warn/
/// danger) rang aur reusable status widgets.
library;

import 'package:flutter/material.dart';

/// Brand seed (logo ke indigo se match).
const Color kBrandSeed = Color(0xFF3F51B5);

/// 4-pt spacing scale.
class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  const Spacing._();
}

class Radii {
  static const double chip = 8;
  static const double card = 16;
  static const double button = 12;
  const Radii._();
}

/// Semantic rang jo ColorScheme mein nahi hote (success / warning).
@immutable
class SemanticColors extends ThemeExtension<SemanticColors> {
  final Color success;
  final Color onSuccess;
  final Color warning;
  final Color onWarning;
  final Color danger;
  final Color onDanger;
  final Color neutral;
  final Color onNeutral;

  const SemanticColors({
    required this.success,
    required this.onSuccess,
    required this.warning,
    required this.onWarning,
    required this.danger,
    required this.onDanger,
    required this.neutral,
    required this.onNeutral,
  });

  static const light = SemanticColors(
    success: Color(0xFFD7F2DC),
    onSuccess: Color(0xFF0B5A1E),
    warning: Color(0xFFFFEBC2),
    onWarning: Color(0xFF6B4300),
    danger: Color(0xFFFFDAD6),
    onDanger: Color(0xFF93000A),
    neutral: Color(0xFFE3E4EA),
    onNeutral: Color(0xFF3B3D4A),
  );

  static const dark = SemanticColors(
    success: Color(0xFF14391D),
    onSuccess: Color(0xFF9BE3AB),
    warning: Color(0xFF4A3300),
    onWarning: Color(0xFFFFD58A),
    danger: Color(0xFF5C1A17),
    onDanger: Color(0xFFFFB4AB),
    neutral: Color(0xFF30323D),
    onNeutral: Color(0xFFC9CBD8),
  );

  @override
  SemanticColors copyWith({
    Color? success, Color? onSuccess, Color? warning, Color? onWarning,
    Color? danger, Color? onDanger, Color? neutral, Color? onNeutral,
  }) =>
      SemanticColors(
        success: success ?? this.success,
        onSuccess: onSuccess ?? this.onSuccess,
        warning: warning ?? this.warning,
        onWarning: onWarning ?? this.onWarning,
        danger: danger ?? this.danger,
        onDanger: onDanger ?? this.onDanger,
        neutral: neutral ?? this.neutral,
        onNeutral: onNeutral ?? this.onNeutral,
      );

  @override
  SemanticColors lerp(ThemeExtension<SemanticColors>? other, double t) {
    if (other is! SemanticColors) return this;
    return SemanticColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      onNeutral: Color.lerp(onNeutral, other.onNeutral, t)!,
    );
  }
}

SemanticColors semanticOf(BuildContext context) =>
    Theme.of(context).extension<SemanticColors>() ?? SemanticColors.light;

class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: kBrandSeed, brightness: b);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final text = base.textTheme;
    return base.copyWith(
      extensions: [b == Brightness.light ? SemanticColors.light : SemanticColors.dark],
      // Typography scale: title/label thoda mazboot, body readable.
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48), // touch target
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.button)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.button)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.button)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.xs),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}

enum StatusTone { success, warning, danger, neutral }

/// Chhota rang-bhara status chip (icon + text dono — sirf rang par nirbhar
/// nahi, accessibility ke liye).
class StatusChip extends StatelessWidget {
  final String label;
  final StatusTone tone;
  final IconData? icon;
  const StatusChip({super.key, required this.label, required this.tone, this.icon});

  @override
  Widget build(BuildContext context) {
    final c = semanticOf(context);
    final (bg, fg) = switch (tone) {
      StatusTone.success => (c.success, c.onSuccess),
      StatusTone.warning => (c.warning, c.onWarning),
      StatusTone.danger => (c.danger, c.onDanger),
      StatusTone.neutral => (c.neutral, c.onNeutral),
    };
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.xs + 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.chip)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: Spacing.xs),
            ],
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Section header (screens ke andar groups ke liye).
class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader(this.title, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.xs, Spacing.lg, Spacing.xs, Spacing.sm),
        child: Text(title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                letterSpacing: 0.8,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// Platform/device-state ke liye shared mapping (chips ek jagah se).
StatusTone toneForState(String label) => switch (label) {
      'Online' => StatusTone.success,
      'Locked' || 'Screen Off' => StatusTone.warning,
      'Sleeping' => StatusTone.neutral,
      _ => StatusTone.danger,
    };

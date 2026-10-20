import 'package:flutter/material.dart';

/// Brand + status tokens. Status colours are reserved for budget/alert state and always
/// ship with a text label or icon, never colour alone.
@immutable
class NisaabPalette extends ThemeExtension<NisaabPalette> {
  const NisaabPalette({
    required this.heroStart,
    required this.heroEnd,
    required this.income,
    required this.expense,
    required this.good,
    required this.warning,
    required this.critical,
    required this.muted,
    required this.chartBar,
    required this.chartTrack,
  });

  final Color heroStart;
  final Color heroEnd;
  final Color income;
  final Color expense;
  final Color good;
  final Color warning;
  final Color critical;
  final Color muted;
  final Color chartBar;
  final Color chartTrack;

  static const light = NisaabPalette(
    heroStart: Color(0xFF0F2A4A),
    heroEnd: Color(0xFF1E4A7A),
    income: Color(0xFF1E8A4C),
    expense: Color(0xFF0F2A4A),
    good: Color(0xFF1E8A4C),
    warning: Color(0xFFB7791F),
    critical: Color(0xFFC53030),
    muted: Color(0xFF5F6B7C),
    chartBar: Color(0xFF2B5C93),
    chartTrack: Color(0xFFE6ECF3),
  );

  static const dark = NisaabPalette(
    heroStart: Color(0xFF16365C),
    heroEnd: Color(0xFF1F4F84),
    income: Color(0xFF5FD08E),
    expense: Color(0xFFE6EDF6),
    good: Color(0xFF5FD08E),
    warning: Color(0xFFF2B65A),
    critical: Color(0xFFFF7B7B),
    muted: Color(0xFF9AA8BA),
    chartBar: Color(0xFF4F94E8), // validated vs dark surface #18212D
    chartTrack: Color(0xFF223246),
  );

  @override
  NisaabPalette copyWith({
    Color? heroStart,
    Color? heroEnd,
    Color? income,
    Color? expense,
    Color? good,
    Color? warning,
    Color? critical,
    Color? muted,
    Color? chartBar,
    Color? chartTrack,
  }) {
    return NisaabPalette(
      heroStart: heroStart ?? this.heroStart,
      heroEnd: heroEnd ?? this.heroEnd,
      income: income ?? this.income,
      expense: expense ?? this.expense,
      good: good ?? this.good,
      warning: warning ?? this.warning,
      critical: critical ?? this.critical,
      muted: muted ?? this.muted,
      chartBar: chartBar ?? this.chartBar,
      chartTrack: chartTrack ?? this.chartTrack,
    );
  }

  @override
  NisaabPalette lerp(ThemeExtension<NisaabPalette>? other, double t) {
    if (other is! NisaabPalette) return this;
    return NisaabPalette(
      heroStart: Color.lerp(heroStart, other.heroStart, t)!,
      heroEnd: Color.lerp(heroEnd, other.heroEnd, t)!,
      income: Color.lerp(income, other.income, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      good: Color.lerp(good, other.good, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      chartBar: Color.lerp(chartBar, other.chartBar, t)!,
      chartTrack: Color.lerp(chartTrack, other.chartTrack, t)!,
    );
  }

  /// Colour for a budget status: ok | warning | exceeded.
  Color forStatus(String status) => switch (status) {
        'exceeded' => critical,
        'warning' => warning,
        _ => good,
      };

  /// Colour for a forecast risk level.
  Color forRisk(String risk) => switch (risk) {
        'exceeded' || 'likely_over' => critical,
        'at_risk' => warning,
        'on_track' => good,
        _ => muted,
      };
}

extension NisaabThemeX on BuildContext {
  NisaabPalette get palette => Theme.of(this).extension<NisaabPalette>()!;
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
}

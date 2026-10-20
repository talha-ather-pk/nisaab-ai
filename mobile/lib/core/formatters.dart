import 'package:intl/intl.dart';

final NumberFormat _whole = NumberFormat('#,##0', 'en_US');
final NumberFormat _compact = NumberFormat.compact(locale: 'en_US');

/// Rs 12,500 · compact: Rs 1.5M (only above 1 lakh so everyday amounts stay exact).
String formatPkr(double amount, {bool compact = false, bool signed = false}) {
  final abs = amount.abs();
  final body = compact && abs >= 100000 ? _compact.format(abs) : _whole.format(abs);
  final sign = amount < 0 ? '−' : (signed && amount > 0 ? '+' : '');
  return '${sign}Rs $body';
}

String formatMonth(int year, int month) => DateFormat('MMMM yyyy').format(DateTime(year, month));

String formatDayHeader(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(date.year, date.month, date.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (d.year == today.year) return DateFormat('EEEE, d MMMM').format(d);
  return DateFormat('d MMMM yyyy').format(d);
}

String formatShortDate(DateTime date) {
  final now = DateTime.now();
  final diff = DateTime(now.year, now.month, now.day).difference(DateTime(date.year, date.month, date.day)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return DateFormat('d MMM').format(date);
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double? parseAmount(String text) => double.tryParse(text.replaceAll(',', '').trim());

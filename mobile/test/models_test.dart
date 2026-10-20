import 'package:flutter_test/flutter_test.dart';
import 'package:nisaab_ai/core/formatters.dart';
import 'package:nisaab_ai/models/models.dart';
import 'package:nisaab_ai/services/api_service.dart';

void main() {
  test('ParsedTransaction parses backend JSON', () {
    final p = ParsedTransaction.fromJson({
      'amount': 1200.0,
      'currency': 'PKR',
      'type': 'expense',
      'category': 'Groceries',
      'merchant': 'Carrefour',
      'description': 'groceries',
      'transaction_date': '2026-10-18',
      'confidence': 0.95,
      'missing_fields': <String>[],
      'raw_text': 'Spent 1,200 rupees on groceries at Carrefour',
      'normalized_text': 'Spent 1,200 rupees on groceries at Carrefour',
      'source': 'text',
    });
    expect(p.amount, 1200);
    expect(p.category, 'Groceries');
    expect(p.transactionDate, DateTime(2026, 10, 18));
  });

  test('TransactionDraft serialises a date-only string and drops blank fields', () {
    final json = TransactionDraft(
      amount: 850,
      type: 'expense',
      category: 'Transport',
      merchant: '  ',
      transactionDate: DateTime(2026, 1, 5, 14, 30),
    ).toJson();
    expect(json['transaction_date'], '2026-01-05');
    expect(json['merchant'], isNull);
    expect(json.containsKey('user_id'), isFalse);
  });

  test('Forecast and summary parse nested lists', () {
    final f = Forecast.fromJson({
      'month': 10, 'year': 2026, 'days_elapsed': 18, 'days_in_month': 31,
      'projected_total_expense': 120000.0, 'projected_total_income': 150000.0, 'projected_savings': 30000.0,
      'next_month_total_forecast': null,
      'categories': [
        {'category': 'Groceries', 'spent_to_date': 15000, 'projected_month_end': 28000,
         'risk': 'likely_over', 'projected_overrun': 3000, 'message': 'Groceries: on pace…', 'monthly_limit': 25000},
      ],
      'alerts': ['Groceries: on pace…'],
    });
    expect(f.forCategory('Groceries')!.isAlert, isTrue);
    expect(f.nextMonthTotalForecast, isNull);
  });

  test('TransactionQuery only sends active filters', () {
    final q = TransactionQuery(page: 2, search: '  ', category: 'Fuel', dateFrom: DateTime(2026, 10, 1)).toQuery();
    expect(q['page'], 2);
    expect(q.containsKey('search'), isFalse);
    expect(q['category'], 'Fuel');
    expect(q['date_from'], '2026-10-01');
  });

  test('formatPkr', () {
    expect(formatPkr(1200), 'Rs 1,200');
    expect(formatPkr(-500), '−Rs 500');
    expect(formatPkr(2500, signed: true), '+Rs 2,500');
  });
}

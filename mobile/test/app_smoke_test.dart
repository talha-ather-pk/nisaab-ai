import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nisaab_ai/core/terms.dart';
import 'package:nisaab_ai/main.dart';
import 'package:nisaab_ai/providers/core_providers.dart';
import 'package:nisaab_ai/providers/session_provider.dart';
import 'package:nisaab_ai/services/api_service.dart';
import 'package:nisaab_ai/services/token_storage.dart';

/// In-memory replacement for the Keystore/Keychain.
class FakeTokenStorage extends TokenStorage {
  String? token;
  String? theme;

  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> saveToken(String value) async => token = value;
  @override
  Future<void> clearToken() async => token = null;
  @override
  Future<String?> readThemeMode() async => theme;
  @override
  Future<void> saveThemeMode(String mode) async => theme = mode;
}

/// Answers API calls with canned JSON shaped like the FastAPI responses.
class FakeBackend implements HttpClientAdapter {
  FakeBackend({bool termsRequired = false, String? termsVersion = 'demo'})
      : user = {
          'id': 1,
          'full_name': 'Ayesha Khan',
          'email': 'demo@nisaab.app',
          'phone': null,
          'preferred_currency': 'PKR',
          'monthly_income': 150000.0,
          'created_at': '2026-07-01T00:00:00Z',
          'terms_accepted_at': termsRequired ? null : '2026-10-19T09:00:00Z',
          'terms_version': termsRequired ? null : termsVersion,
          'terms_required': termsRequired,
        };

  final requests = <String>[];
  final bodies = <String, dynamic>{};
  final Map<String, dynamic> user;

  static final _today = DateTime.now();
  static String _d(DateTime d) => d.toIso8601String().substring(0, 10);

  static Map<String, dynamic> _txn(int id, double amount, String type, String category, String? merchant) => {
    'id': id,
    'user_id': 1,
    'amount': amount,
    'currency': 'PKR',
    'type': type,
    'category': category,
    'merchant': merchant,
    'description': null,
    'raw_text': 'Spent $amount at $merchant',
    'source': 'text',
    'ai_confidence': 0.95,
    'user_corrected': false,
    'transaction_date': _d(_today),
    'created_at': '2026-10-18T10:00:00Z',
    'updated_at': '2026-10-18T10:00:00Z',
  };

  static Map<String, dynamic> _budget(int id, String category, double limit, double spent, String status) => {
    'id': id,
    'user_id': 1,
    'category': category,
    'monthly_limit': limit,
    'currency': 'PKR',
    'month': _today.month,
    'year': _today.year,
    'month_year': _d(DateTime(_today.year, _today.month)),
    'alert_threshold': 80,
    'spent': spent,
    'remaining': limit - spent,
    'percent_used': spent / limit * 100,
    'status': status,
  };

  dynamic _route(String method, String path) {
    if (path.endsWith('/auth/login')) {
      return {'access_token': 'test-token', 'token_type': 'bearer', 'expires_in': 3600, 'user': user};
    }
    if (path.endsWith('/auth/register')) {
      return {'access_token': 'test-token', 'token_type': 'bearer', 'expires_in': 3600, 'user': user};
    }
    if (path.endsWith('/auth/me/accept-terms')) {
      user
        ..['terms_required'] = false
        ..['terms_accepted_at'] = '2026-10-19T09:00:00Z'
        ..['terms_version'] = kTermsVersion;
      return user;
    }
    if (path.endsWith('/auth/me') && method == 'DELETE') return null;
    if (path.endsWith('/auth/me')) return user;
    if (path.contains('/analytics/summary/')) {
      return {
        'month': _today.month,
        'year': _today.year,
        'total_income': 150000.0,
        'total_expense': 61200.0,
        'net_savings': 88800.0,
        'savings_rate': 59.2,
        'transaction_count': 42,
        'previous_month_expense': 98000.0,
        'expense_change_pct': -37.6,
        'by_category': [
          for (final (c, a) in [
            ('Rent', 35000.0),
            ('Groceries', 12000.0),
            ('Fuel', 6000.0),
            ('Transport', 4200.0),
            ('Food & Dining', 2500.0),
            ('Utilities', 1500.0),
          ])
            {'category': c, 'amount': a, 'share': a / 61200 * 100, 'transaction_count': 3},
        ],
        'daily': <dynamic>[],
        'budgets': [_budget(1, 'Groceries', 15000, 12000, 'warning'), _budget(2, 'Fuel', 5000, 6000, 'exceeded')],
      };
    }
    if (path.contains('/analytics/forecast/')) {
      return {
        'as_of': _d(_today),
        'month': _today.month,
        'year': _today.year,
        'days_elapsed': 18,
        'days_in_month': 31,
        'projected_total_expense': 104000.0,
        'projected_total_income': 150000.0,
        'projected_savings': 46000.0,
        'next_month_total_forecast': 99000.0,
        'categories': [
          {
            'category': 'Fuel',
            'spent_to_date': 6000.0,
            'projected_month_end': 10300.0,
            'historical_avg': 9000.0,
            'next_month_forecast': 9800.0,
            'trend_pct': 5.0,
            'monthly_limit': 5000.0,
            'recommended_budget': 10500.0,
            'risk': 'exceeded',
            'projected_overrun': 5300.0,
            'message': 'Fuel: already Rs 1,000 over budget.',
          },
          {
            'category': 'Groceries',
            'spent_to_date': 12000.0,
            'projected_month_end': 20600.0,
            'historical_avg': 21000.0,
            'next_month_forecast': 20800.0,
            'trend_pct': -2.0,
            'monthly_limit': 15000.0,
            'recommended_budget': 22000.0,
            'risk': 'likely_over',
            'projected_overrun': 5600.0,
            'message': 'Groceries: on pace for Rs 20,600.',
          },
        ],
        'alerts': ['Fuel: already Rs 1,000 over budget.', 'Groceries: on pace for Rs 20,600.'],
      };
    }
    if (path.endsWith('/transactions/parse')) {
      return {
        'amount': 1200.0,
        'currency': 'PKR',
        'type': 'expense',
        'category': 'Groceries',
        'merchant': 'Carrefour',
        'description': 'groceries',
        'transaction_date': _d(_today),
        'confidence': 0.95,
        'missing_fields': <String>[],
        'raw_text': 'Spent 1,200 on groceries at Carrefour',
        'normalized_text': 'Spent 1,200 on groceries at Carrefour',
        'source': 'text',
      };
    }
    if (path.contains('/goals/')) {
      return [
        {
          'id': 1,
          'user_id': 1,
          'name': 'New laptop',
          'target_amount': 180000.0,
          'saved_amount': 45000.0,
          'currency': 'PKR',
          'target_date': _d(_today.add(const Duration(days: 180))),
          'percent': 25.0,
          'remaining': 135000.0,
          'monthly_needed': 22900.0,
          'status': 'behind',
          'created_at': '2026-09-01T10:00:00Z',
        },
        {
          'id': 2,
          'user_id': 1,
          'name': 'Emergency fund',
          'target_amount': 300000.0,
          'saved_amount': 120000.0,
          'currency': 'PKR',
          'target_date': null,
          'percent': 40.0,
          'remaining': 180000.0,
          'monthly_needed': null,
          'status': 'no_deadline',
          'created_at': '2026-09-01T10:00:00Z',
        },
      ];
    }
    if (path.contains('/transactions/') && method == 'GET') {
      final items = [
        _txn(1, 1200, 'expense', 'Groceries', 'Carrefour'),
        _txn(2, 850, 'expense', 'Transport', 'Careem'),
        _txn(3, 150000, 'income', 'Salary', null),
      ];
      return {
        'items': items,
        'total': 3,
        'page': 1,
        'page_size': 25,
        'pages': 1,
        'total_income': 150000.0,
        'total_expense': 2050.0,
      };
    }
    if (path.contains('/budgets/')) {
      return [_budget(2, 'Fuel', 5000, 6000, 'exceeded'), _budget(1, 'Groceries', 15000, 12000, 'warning')];
    }
    if (path.endsWith('/ai/assistant/history')) return <dynamic>[];
    if (path.endsWith('/ai/assistant')) {
      return {
        'reply': 'You spent Rs 12,000 on Groceries so far.',
        'intent': 'spend_query',
        'provider': 'rules',
        'suggestions': ['Give me saving tips'],
        'log_id': 1,
      };
    }
    throw StateError('Unhandled $method $path');
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    bodies['${options.method} ${options.path}'] = options.data;
    final body = jsonEncode(_route(options.method, options.path));
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeBackend backend;
  late FakeTokenStorage storage;

  Widget app([FakeBackend? fake]) {
    backend = fake ?? FakeBackend();
    storage = FakeTokenStorage();
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))..httpClientAdapter = backend;
    return ProviderScope(
      overrides: [
        tokenStorageProvider.overrideWithValue(storage),
        apiServiceProvider.overrideWith((ref) {
          final api = ApiService(dio: dio);
          api.onUnauthorized = () => ref.read(sessionProvider.notifier).expire();
          return api;
        }),
      ],
      child: const NisaabApp(),
    );
  }

  for (final (name, size, dpr) in const [
    ('393dp phone', Size(1080, 2340), 2.75),
    ('360dp small phone', Size(720, 1520), 2.0),
  ]) {
    testWidgets('login → dashboard → every tab renders without errors ($name)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Signed out → login screen
      expect(find.text('Welcome back'), findsOneWidget);
      await tester.tap(find.text('Try the demo account'));
      await tester.pumpAndSettle();
      expect(storage.token, 'test-token');

      // Dashboard
      expect(find.textContaining('Assalam-o-Alaikum, Ayesha'), findsOneWidget);
      expect(find.text('Net savings this month'), findsOneWidget);
      expect(find.text('Rs 88,800'), findsOneWidget);
      expect(find.textContaining('Fuel: already'), findsOneWidget); // forecast nudge
      await tester.scrollUntilVisible(find.text('Recent transactions'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Where your money went'), findsOneWidget);

      // History
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Transactions'), findsWidgets);
      expect(find.text('Careem'), findsWidgets);
      // Inline edit opens in place
      await tester.tap(find.text('Careem').last);
      await tester.pumpAndSettle();
      expect(find.text('Edit transaction'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Budgets
      await tester.tap(find.text('Budgets').last);
      await tester.pumpAndSettle();
      expect(find.text('Total budgeted'), findsOneWidget);
      expect(find.text('Over budget'), findsWidgets);
      expect(find.textContaining('Projected month-end'), findsWidgets);

      // Goals
      await tester.tap(find.text('Goals'));
      await tester.pumpAndSettle();
      expect(find.text('Savings goals'), findsOneWidget);
      expect(find.text('New laptop'), findsOneWidget);
      expect(find.text('Behind schedule'), findsOneWidget);
      expect(find.textContaining('/month to reach it by'), findsOneWidget);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(find.text('Add to New laptop'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Assistant
      await tester.tap(find.text('Assistant'));
      await tester.pumpAndSettle();
      expect(find.text('Ask me about your money'), findsOneWidget);
      await tester.tap(find.text('How much did I spend this month?'));
      await tester.pumpAndSettle();
      expect(find.text('You spent Rs 12,000 on Groceries so far.'), findsOneWidget);
      expect(find.textContaining('Nisaab insights'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('typing a transaction opens the AI review sheet', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try the demo account'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Spent 1,200 on groceries at Carrefour');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Review transaction'), findsOneWidget);
    expect(find.textContaining('AI preview · Looks right'), findsOneWidget);
    expect(find.text('95%'), findsOneWidget);
    expect(backend.requests, contains('POST /api/v1/transactions/parse'));
  });

  testWidgets('dark theme renders the dashboard', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try the demo account'));
    await tester.pumpAndSettle();
    expect(find.text('Net savings this month'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets('registration requires research consent', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('New to Nisaab? Create an account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Full name'), 'Sara Malik');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'sara@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'Secret123');

    final submit = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('Please accept to create an account'), findsOneWidget);
    expect(backend.requests, isNot(contains('POST /api/v1/auth/register')));

    await tester.tap(find.byType(Checkbox));
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final body = backend.bodies['POST /api/v1/auth/register'] as Map<String, dynamic>;
    expect(body['accept_terms'], isTrue);
    expect(body['terms_version'], kTermsVersion);
    expect(find.textContaining('Assalam-o-Alaikum'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an account without consent must accept before using the app', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(FakeBackend(termsRequired: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try the demo account'));
    await tester.pumpAndSettle();
    expect(find.text('Before you continue'), findsOneWidget);
    expect(find.textContaining('Assalam-o-Alaikum'), findsNothing);

    final agree = find.text('I agree');
    await tester.scrollUntilVisible(agree, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(agree);
    await tester.pumpAndSettle();
    expect(backend.requests, contains('POST /api/v1/auth/me/accept-terms'));
    expect(find.textContaining('Assalam-o-Alaikum'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shared demo account has no delete option', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try the demo account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile & settings').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Shared demo account'), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);
  });

  testWidgets('deleting an account asks for the password and signs out', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(FakeBackend(termsVersion: kTermsVersion)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try the demo account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile & settings').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Research consent given'), findsOneWidget);

    final delete = find.text('Delete account');
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);

    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your password'), findsOneWidget); // nothing is sent without a password
    expect(backend.requests, isNot(contains('DELETE /api/v1/auth/me')));

    await tester.enterText(find.widgetWithText(TextField, 'Confirm with your password'), 'Secret123');
    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();
    expect(backend.bodies['DELETE /api/v1/auth/me'], {'password': 'Secret123'});
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Your account and all of its data were deleted.'), findsOneWidget);
    expect(storage.token, isNull);
    expect(tester.takeException(), isNull);
  });
}

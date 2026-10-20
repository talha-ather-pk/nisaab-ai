/// Data models mirroring the Pydantic schemas in backend/schemas.py.
library;

import '../core/formatters.dart';

double _d(dynamic v) => v == null ? 0.0 : (v as num).toDouble();
double? _dn(dynamic v) => v == null ? null : (v as num).toDouble();
DateTime _date(dynamic v) => DateTime.parse(v as String);
List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    (v as List<dynamic>? ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();

class User {
  final int id;
  final String fullName;
  final String email;
  final String? phone;
  final String preferredCurrency;
  final double? monthlyIncome;
  final DateTime? termsAcceptedAt;
  final String? termsVersion;

  /// The user hasn't accepted the current terms and must be asked before using the app.
  final bool termsRequired;

  const User({
    required this.id,
    required this.fullName,
    required this.email,
    this.phone,
    required this.preferredCurrency,
    this.monthlyIncome,
    this.termsAcceptedAt,
    this.termsVersion,
    this.termsRequired = false,
  });

  /// The shared demo account: not a research participant and can't be deleted.
  bool get isDemo => termsVersion == 'demo';

  String get firstName => fullName.split(' ').first;

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        fullName: j['full_name'] as String,
        email: j['email'] as String,
        phone: j['phone'] as String?,
        preferredCurrency: j['preferred_currency'] as String? ?? 'PKR',
        monthlyIncome: _dn(j['monthly_income']),
        termsAcceptedAt: j['terms_accepted_at'] == null ? null : DateTime.parse(j['terms_accepted_at'] as String),
        termsVersion: j['terms_version'] as String?,
        termsRequired: j['terms_required'] as bool? ?? false,
      );
}

class AuthResult {
  final String accessToken;
  final User user;
  const AuthResult(this.accessToken, this.user);

  factory AuthResult.fromJson(Map<String, dynamic> j) =>
      AuthResult(j['access_token'] as String, User.fromJson(j['user'] as Map<String, dynamic>));
}

/// POST /api/v1/transactions/parse
class ParsedTransaction {
  final double? amount;
  final String currency;
  final String type;
  final String category;
  final String? merchant;
  final String? description;
  final DateTime transactionDate;
  final double confidence;
  final List<String> missingFields;
  final String rawText;
  final String source;

  /// 'personal' when the category was learned from this user's own corrections.
  final String categorySource;

  const ParsedTransaction({
    required this.amount,
    required this.currency,
    required this.type,
    required this.category,
    required this.merchant,
    required this.description,
    required this.transactionDate,
    required this.confidence,
    required this.missingFields,
    required this.rawText,
    required this.source,
    this.categorySource = 'rules',
  });

  bool get learnedFromUser => categorySource == 'personal';

  factory ParsedTransaction.fromJson(Map<String, dynamic> j) => ParsedTransaction(
        amount: _dn(j['amount']),
        currency: j['currency'] as String? ?? 'PKR',
        type: j['type'] as String? ?? 'expense',
        category: j['category'] as String? ?? 'Other',
        merchant: j['merchant'] as String?,
        description: j['description'] as String?,
        transactionDate: _date(j['transaction_date']),
        confidence: _d(j['confidence']),
        missingFields: (j['missing_fields'] as List<dynamic>? ?? const []).cast<String>(),
        rawText: j['raw_text'] as String? ?? '',
        source: j['source'] as String? ?? 'text',
        categorySource: j['category_source'] as String? ?? 'rules',
      );
}

/// Body for POST /api/v1/transactions (the user comes from the auth token).
class TransactionDraft {
  final double amount;
  final String currency;
  final String type;
  final String category;
  final String? merchant;
  final String? description;
  final String? rawText;
  final String source;
  final double? aiConfidence;
  final bool userCorrected;
  final DateTime transactionDate;

  const TransactionDraft({
    required this.amount,
    this.currency = 'PKR',
    required this.type,
    required this.category,
    this.merchant,
    this.description,
    this.rawText,
    this.source = 'manual',
    this.aiConfidence,
    this.userCorrected = false,
    required this.transactionDate,
  });

  static String? _clean(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();

  Map<String, dynamic> toJson() => {
        'amount': double.parse(amount.toStringAsFixed(2)),
        'currency': currency,
        'type': type,
        'category': category,
        'merchant': _clean(merchant),
        'description': _clean(description),
        'raw_text': rawText,
        'source': source,
        'ai_confidence': aiConfidence,
        'user_corrected': userCorrected,
        'transaction_date': isoDate(transactionDate),
      };
}

class Transaction {
  final int id;
  final double amount;
  final String currency;
  final String type;
  final String category;
  final String? merchant;
  final String? description;
  final String? rawText;
  final String source;
  final double? aiConfidence;
  final bool userCorrected;
  final DateTime transactionDate;

  const Transaction({
    required this.id,
    required this.amount,
    required this.currency,
    required this.type,
    required this.category,
    this.merchant,
    this.description,
    this.rawText,
    required this.source,
    this.aiConfidence,
    required this.userCorrected,
    required this.transactionDate,
  });

  bool get isIncome => type == 'income';
  double get signedAmount => isIncome ? amount : -amount;

  String get title {
    if (merchant != null && merchant!.isNotEmpty) return merchant!;
    if (description != null && description!.isNotEmpty) return description!;
    return category;
  }

  factory Transaction.fromJson(Map<String, dynamic> j) => Transaction(
        id: j['id'] as int,
        amount: _d(j['amount']),
        currency: j['currency'] as String? ?? 'PKR',
        type: j['type'] as String,
        category: j['category'] as String,
        merchant: j['merchant'] as String?,
        description: j['description'] as String?,
        rawText: j['raw_text'] as String?,
        source: j['source'] as String? ?? 'manual',
        aiConfidence: _dn(j['ai_confidence']),
        userCorrected: j['user_corrected'] as bool? ?? false,
        transactionDate: _date(j['transaction_date']),
      );
}

class TransactionPage {
  final List<Transaction> items;
  final int total;
  final int page;
  final int pages;
  final double totalIncome;
  final double totalExpense;

  const TransactionPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pages,
    required this.totalIncome,
    required this.totalExpense,
  });

  factory TransactionPage.fromJson(Map<String, dynamic> j) => TransactionPage(
        items: _list(j['items'], Transaction.fromJson),
        total: j['total'] as int,
        page: j['page'] as int,
        pages: j['pages'] as int,
        totalIncome: _d(j['total_income']),
        totalExpense: _d(j['total_expense']),
      );
}

class Budget {
  final int id;
  final String category;
  final double monthlyLimit;
  final int month;
  final int year;
  final int alertThreshold;
  final double spent;
  final double remaining;
  final double percentUsed;
  final String status; // ok | warning | exceeded

  const Budget({
    required this.id,
    required this.category,
    required this.monthlyLimit,
    required this.month,
    required this.year,
    required this.alertThreshold,
    required this.spent,
    required this.remaining,
    required this.percentUsed,
    required this.status,
  });

  factory Budget.fromJson(Map<String, dynamic> j) => Budget(
        id: j['id'] as int,
        category: j['category'] as String,
        monthlyLimit: _d(j['monthly_limit']),
        month: j['month'] as int,
        year: j['year'] as int,
        alertThreshold: j['alert_threshold'] as int? ?? 80,
        spent: _d(j['spent']),
        remaining: _d(j['remaining']),
        percentUsed: _d(j['percent_used']),
        status: j['status'] as String? ?? 'ok',
      );
}

class CategorySpend {
  final String category;
  final double amount;
  final double share;
  final int transactionCount;

  const CategorySpend(this.category, this.amount, this.share, this.transactionCount);

  factory CategorySpend.fromJson(Map<String, dynamic> j) => CategorySpend(
        j['category'] as String,
        _d(j['amount']),
        _d(j['share']),
        j['transaction_count'] as int? ?? 0,
      );
}

class MonthlySummary {
  final int month;
  final int year;
  final double totalIncome;
  final double totalExpense;
  final double netSavings;
  final double savingsRate;
  final int transactionCount;
  final double previousMonthExpense;
  final double? expenseChangePct;
  final List<CategorySpend> byCategory;
  final List<Budget> budgets;

  const MonthlySummary({
    required this.month,
    required this.year,
    required this.totalIncome,
    required this.totalExpense,
    required this.netSavings,
    required this.savingsRate,
    required this.transactionCount,
    required this.previousMonthExpense,
    required this.expenseChangePct,
    required this.byCategory,
    required this.budgets,
  });

  factory MonthlySummary.fromJson(Map<String, dynamic> j) => MonthlySummary(
        month: j['month'] as int,
        year: j['year'] as int,
        totalIncome: _d(j['total_income']),
        totalExpense: _d(j['total_expense']),
        netSavings: _d(j['net_savings']),
        savingsRate: _d(j['savings_rate']),
        transactionCount: j['transaction_count'] as int,
        previousMonthExpense: _d(j['previous_month_expense']),
        expenseChangePct: _dn(j['expense_change_pct']),
        byCategory: _list(j['by_category'], CategorySpend.fromJson),
        budgets: _list(j['budgets'], Budget.fromJson),
      );
}

class CategoryForecast {
  final String category;
  final double spentToDate;
  final double projectedMonthEnd;
  final double? historicalAvg;
  final double? nextMonthForecast;
  final double? trendPct;
  final double? monthlyLimit;
  final double? recommendedBudget;
  final String risk; // no_budget | on_track | at_risk | likely_over | exceeded
  final double projectedOverrun;
  final String message;

  const CategoryForecast({
    required this.category,
    required this.spentToDate,
    required this.projectedMonthEnd,
    this.historicalAvg,
    this.nextMonthForecast,
    this.trendPct,
    this.monthlyLimit,
    this.recommendedBudget,
    required this.risk,
    required this.projectedOverrun,
    required this.message,
  });

  bool get isAlert => risk == 'exceeded' || risk == 'likely_over' || risk == 'at_risk';

  factory CategoryForecast.fromJson(Map<String, dynamic> j) => CategoryForecast(
        category: j['category'] as String,
        spentToDate: _d(j['spent_to_date']),
        projectedMonthEnd: _d(j['projected_month_end']),
        historicalAvg: _dn(j['historical_avg']),
        nextMonthForecast: _dn(j['next_month_forecast']),
        trendPct: _dn(j['trend_pct']),
        monthlyLimit: _dn(j['monthly_limit']),
        recommendedBudget: _dn(j['recommended_budget']),
        risk: j['risk'] as String,
        projectedOverrun: _d(j['projected_overrun']),
        message: j['message'] as String? ?? '',
      );
}

class Forecast {
  final int month;
  final int year;
  final int daysElapsed;
  final int daysInMonth;
  final double projectedTotalExpense;
  final double projectedTotalIncome;
  final double projectedSavings;
  final double? nextMonthTotalForecast;
  final List<CategoryForecast> categories;
  final List<String> alerts;

  const Forecast({
    required this.month,
    required this.year,
    required this.daysElapsed,
    required this.daysInMonth,
    required this.projectedTotalExpense,
    required this.projectedTotalIncome,
    required this.projectedSavings,
    required this.nextMonthTotalForecast,
    required this.categories,
    required this.alerts,
  });

  CategoryForecast? forCategory(String category) {
    for (final c in categories) {
      if (c.category == category) return c;
    }
    return null;
  }

  factory Forecast.fromJson(Map<String, dynamic> j) => Forecast(
        month: j['month'] as int,
        year: j['year'] as int,
        daysElapsed: j['days_elapsed'] as int,
        daysInMonth: j['days_in_month'] as int,
        projectedTotalExpense: _d(j['projected_total_expense']),
        projectedTotalIncome: _d(j['projected_total_income']),
        projectedSavings: _d(j['projected_savings']),
        nextMonthTotalForecast: _dn(j['next_month_total_forecast']),
        categories: _list(j['categories'], CategoryForecast.fromJson),
        alerts: (j['alerts'] as List<dynamic>? ?? const []).cast<String>(),
      );
}

class AssistantReply {
  final String reply;
  final String intent;
  final String provider; // rules | claude
  final List<String> suggestions;

  const AssistantReply(this.reply, this.intent, this.provider, this.suggestions);

  factory AssistantReply.fromJson(Map<String, dynamic> j) => AssistantReply(
        j['reply'] as String,
        j['intent'] as String,
        j['provider'] as String,
        (j['suggestions'] as List<dynamic>? ?? const []).cast<String>(),
      );
}

class AssistantHistoryItem {
  final int id;
  final String message;
  final String? reply;
  final String provider;
  final DateTime createdAt;

  const AssistantHistoryItem(this.id, this.message, this.reply, this.provider, this.createdAt);

  factory AssistantHistoryItem.fromJson(Map<String, dynamic> j) => AssistantHistoryItem(
        j['id'] as int,
        j['message'] as String,
        j['reply'] as String?,
        j['provider'] as String? ?? 'rules',
        DateTime.parse(j['created_at'] as String),
      );
}

class SavingsGoal {
  final int id;
  final String name;
  final double targetAmount;
  final double savedAmount;
  final DateTime? targetDate;
  final double percent;
  final double remaining;
  final double? monthlyNeeded;
  final String status; // completed | on_track | behind | overdue | no_deadline

  const SavingsGoal({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.savedAmount,
    required this.targetDate,
    required this.percent,
    required this.remaining,
    required this.monthlyNeeded,
    required this.status,
  });

  bool get isCompleted => status == 'completed';

  factory SavingsGoal.fromJson(Map<String, dynamic> j) => SavingsGoal(
        id: j['id'] as int,
        name: j['name'] as String,
        targetAmount: _d(j['target_amount']),
        savedAmount: _d(j['saved_amount']),
        targetDate: j['target_date'] == null ? null : _date(j['target_date']),
        percent: _d(j['percent']),
        remaining: _d(j['remaining']),
        monthlyNeeded: _dn(j['monthly_needed']),
        status: j['status'] as String? ?? 'no_deadline',
      );
}

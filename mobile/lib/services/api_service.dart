import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/config.dart';
import '../core/formatters.dart';
import '../core/terms.dart';
import '../models/models.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? requestId;

  const ApiException(this.message, {this.statusCode, this.requestId});

  bool get isUnauthorized => statusCode == 401;
  bool get isNetwork => statusCode == null;

  @override
  String toString() => message;
}

/// Query options for GET /api/v1/transactions/{user_id}.
class TransactionQuery {
  final int page;
  final int pageSize;
  final String? search;
  final String? category;
  final String? type;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final String sort;

  const TransactionQuery({
    this.page = 1,
    this.pageSize = 20,
    this.search,
    this.category,
    this.type,
    this.dateFrom,
    this.dateTo,
    this.sort = 'date_desc',
  });

  Map<String, dynamic> toQuery() => {
        'page': page,
        'page_size': pageSize,
        if (search != null && search!.trim().isNotEmpty) 'search': search!.trim(),
        if (category != null) 'category': category,
        if (type != null) 'type': type,
        if (dateFrom != null) 'date_from': isoDate(dateFrom!),
        if (dateTo != null) 'date_to': isoDate(dateTo!),
        'sort': sort,
      };
}

/// HTTP client for the Nisaab FastAPI backend.
class ApiService {
  ApiService({String? baseUrl, Dio? dio, this.onUnauthorized})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), ''),
              connectTimeout: AppConfig.connectTimeout,
              receiveTimeout: AppConfig.receiveTimeout,
              sendTimeout: AppConfig.connectTimeout,
              contentType: Headers.jsonContentType,
              responseType: ResponseType.json,
              headers: {'Accept': 'application/json'},
            )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = _token;
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
        handler.next(options);
      },
      onError: (error, handler) {
        // A 401 on anything except login/register means the session is no longer valid.
        final path = error.requestOptions.path;
        if (error.response?.statusCode == 401 && !path.contains('/auth/login') && !path.contains('/auth/register')) {
          onUnauthorized?.call();
        }
        handler.next(error);
      },
    ));
  }

  final Dio _dio;
  String? _token;

  /// Called when the server rejects the token (expired / revoked).
  void Function()? onUnauthorized;

  String get baseUrl => _dio.options.baseUrl;
  bool get hasToken => _token != null;
  void setToken(String? token) => _token = token;

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  Future<AuthResult> register({
    required String fullName,
    required String email,
    required String password,
    double? monthlyIncome,
    required bool acceptTerms,
  }) async {
    final data = await _request('POST', '/api/v1/auth/register', body: {
      'full_name': fullName,
      'email': email,
      'password': password,
      if (monthlyIncome != null) 'monthly_income': monthlyIncome,
      'accept_terms': acceptTerms,
      'terms_version': kTermsVersion,
    });
    return AuthResult.fromJson(data as Map<String, dynamic>);
  }

  Future<AuthResult> login(String email, String password) async {
    final data = await _request('POST', '/api/v1/auth/login', body: {'email': email, 'password': password});
    return AuthResult.fromJson(data as Map<String, dynamic>);
  }

  Future<User> me() async => User.fromJson(await _request('GET', '/api/v1/auth/me') as Map<String, dynamic>);

  Future<User> acceptTerms() async => User.fromJson(
      await _request('POST', '/api/v1/auth/me/accept-terms', body: {'terms_version': kTermsVersion})
          as Map<String, dynamic>);

  /// Permanently deletes the account and all its data. The password is checked again by the server.
  Future<void> deleteAccount(String password) =>
      _request('DELETE', '/api/v1/auth/me', body: {'password': password});

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------

  Future<ParsedTransaction> parseTransaction(String text, {String source = 'text'}) async {
    final data = await _request('POST', '/api/v1/transactions/parse', body: {'text': text, 'source': source});
    return ParsedTransaction.fromJson(data as Map<String, dynamic>);
  }

  Future<Transaction> createTransaction(TransactionDraft draft) async {
    final data = await _request('POST', '/api/v1/transactions', body: draft.toJson());
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  Future<TransactionPage> getTransactions(int userId, [TransactionQuery query = const TransactionQuery()]) async {
    final data = await _request('GET', '/api/v1/transactions/$userId', query: query.toQuery());
    return TransactionPage.fromJson(data as Map<String, dynamic>);
  }

  /// Partial update; only the keys present in [changes] are modified.
  Future<Transaction> updateTransaction(int transactionId, Map<String, dynamic> changes) async {
    final data = await _request('PATCH', '/api/v1/transactions/$transactionId', body: changes);
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteTransaction(int transactionId) => _request('DELETE', '/api/v1/transactions/$transactionId');

  // ---------------------------------------------------------------------------
  // Budgets
  // ---------------------------------------------------------------------------

  Future<Budget> upsertBudget({
    required String category,
    required double monthlyLimit,
    required int month,
    required int year,
    int alertThreshold = 80,
  }) async {
    final data = await _request('POST', '/api/v1/budgets', body: {
      'category': category,
      'monthly_limit': double.parse(monthlyLimit.toStringAsFixed(2)),
      'month': month,
      'year': year,
      'alert_threshold': alertThreshold,
    });
    return Budget.fromJson(data as Map<String, dynamic>);
  }

  Future<List<Budget>> getBudgets(int userId, {required int month, required int year}) async {
    final data = await _request('GET', '/api/v1/budgets/$userId', query: {'month': month, 'year': year});
    return (data as List<dynamic>).map((e) => Budget.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteBudget(int budgetId) => _request('DELETE', '/api/v1/budgets/$budgetId');

  // ---------------------------------------------------------------------------
  // Savings goals
  // ---------------------------------------------------------------------------

  Future<List<SavingsGoal>> getGoals(int userId) async {
    final data = await _request('GET', '/api/v1/goals/$userId');
    return (data as List<dynamic>).map((e) => SavingsGoal.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<SavingsGoal> createGoal({required String name, required double targetAmount, DateTime? targetDate}) async {
    final data = await _request('POST', '/api/v1/goals', body: {
      'name': name,
      'target_amount': double.parse(targetAmount.toStringAsFixed(2)),
      if (targetDate != null) 'target_date': isoDate(targetDate),
    });
    return SavingsGoal.fromJson(data as Map<String, dynamic>);
  }

  Future<SavingsGoal> updateGoal(int goalId, Map<String, dynamic> changes) async {
    final data = await _request('PATCH', '/api/v1/goals/$goalId', body: changes);
    return SavingsGoal.fromJson(data as Map<String, dynamic>);
  }

  /// Negative [amount] records a withdrawal.
  Future<SavingsGoal> contributeToGoal(int goalId, double amount) async {
    final data = await _request('POST', '/api/v1/goals/$goalId/contribute',
        body: {'amount': double.parse(amount.toStringAsFixed(2))});
    return SavingsGoal.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteGoal(int goalId) => _request('DELETE', '/api/v1/goals/$goalId');

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  /// All of the user's transactions as CSV bytes (UTF-8 with BOM, ready for Excel).
  Future<Uint8List> exportTransactionsCsv(int userId) async {
    try {
      final response = await _dio.get<List<int>>(
        '/api/v1/transactions/$userId/export',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? const []);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Analytics & AI
  // ---------------------------------------------------------------------------

  Future<MonthlySummary> getSummary(int userId, {int? month, int? year}) async {
    final data = await _request('GET', '/api/v1/analytics/summary/$userId', query: {
      if (month != null) 'month': month,
      if (year != null) 'year': year,
    });
    return MonthlySummary.fromJson(data as Map<String, dynamic>);
  }

  Future<Forecast> getForecast(int userId) async {
    final data = await _request('GET', '/api/v1/analytics/forecast/$userId');
    return Forecast.fromJson(data as Map<String, dynamic>);
  }

  Future<AssistantReply> askAssistant(String message, List<Map<String, String>> history) async {
    final data = await _request('POST', '/api/v1/ai/assistant', body: {'message': message, 'history': history});
    return AssistantReply.fromJson(data as Map<String, dynamic>);
  }

  Future<List<AssistantHistoryItem>> assistantHistory({int limit = 30}) async {
    final data = await _request('GET', '/api/v1/ai/assistant/history', query: {'limit': limit});
    return (data as List<dynamic>).map((e) => AssistantHistoryItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
  }) async {
    try {
      final response = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method),
      );
      return response.data;
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  ApiException _toApiException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const ApiException('The server took too long to respond. Please try again.');
      case DioExceptionType.connectionError:
        return ApiException('Can\'t reach the Nisaab server at ${_dio.options.baseUrl}. Check your connection.');
      case DioExceptionType.cancel:
        return const ApiException('Request cancelled.');
      case DioExceptionType.badCertificate:
        return const ApiException('The server\'s security certificate is not trusted.');
      default: // badResponse, unknown, and any types added by future Dio versions
        final response = e.response;
        if (response == null) {
          return ApiException('Network error: ${e.message ?? 'unknown'}');
        }
        final data = response.data;
        final requestId = data is Map<String, dynamic> ? data['request_id'] as String? : null;
        return ApiException(_detailMessage(data, response.statusCode),
            statusCode: response.statusCode, requestId: requestId);
    }
  }

  /// FastAPI errors: {"detail": "..."} or {"detail": [{"loc": [...], "msg": "..."}]}.
  static String _detailMessage(dynamic data, int? status) {
    if (data is Map<String, dynamic>) {
      final detail = data['detail'];
      if (detail is String) return detail;
      if (detail is List && detail.isNotEmpty) {
        return detail.map((e) {
          if (e is Map<String, dynamic>) {
            final loc = (e['loc'] as List<dynamic>? ?? const [])
                .where((p) => p != 'body' && p != 'query' && p != 'path')
                .join('.');
            final msg = (e['msg'] as String? ?? '').replaceFirst('Value error, ', '');
            return loc.isEmpty ? msg : '$loc: $msg';
          }
          return '$e';
        }).join('\n');
      }
    }
    if (status != null && status >= 500) return 'Server error ($status). Please try again shortly.';
    return 'Request failed (${status ?? 'no status'})';
  }
}

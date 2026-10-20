import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import 'budgets_provider.dart';
import 'core_providers.dart';
import 'dashboard_provider.dart';
import 'session_provider.dart';

class TransactionFilter {
  final String search;
  final String? type; // expense | income | null = all
  final String? category;
  final DateTimeRange? range;

  const TransactionFilter({this.search = '', this.type, this.category, this.range});

  bool get isActive => search.isNotEmpty || type != null || category != null || range != null;

  TransactionFilter copyWith({
    String? search,
    String? type,
    String? category,
    DateTimeRange? range,
    bool clearType = false,
    bool clearCategory = false,
    bool clearRange = false,
  }) {
    return TransactionFilter(
      search: search ?? this.search,
      type: clearType ? null : (type ?? this.type),
      category: clearCategory ? null : (category ?? this.category),
      range: clearRange ? null : (range ?? this.range),
    );
  }
}

class TransactionListState {
  final List<Transaction> items;
  final TransactionFilter filter;
  final int page;
  final int pages;
  final int total;
  final double totalIncome;
  final double totalExpense;
  final bool loading;
  final bool loadingMore;
  final String? error;

  const TransactionListState({
    this.items = const [],
    this.filter = const TransactionFilter(),
    this.page = 0,
    this.pages = 1,
    this.total = 0,
    this.totalIncome = 0,
    this.totalExpense = 0,
    this.loading = true,
    this.loadingMore = false,
    this.error,
  });

  bool get hasMore => page < pages;

  TransactionListState copyWith({
    List<Transaction>? items,
    TransactionFilter? filter,
    int? page,
    int? pages,
    int? total,
    double? totalIncome,
    double? totalExpense,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
  }) {
    return TransactionListState(
      items: items ?? this.items,
      filter: filter ?? this.filter,
      page: page ?? this.page,
      pages: pages ?? this.pages,
      total: total ?? this.total,
      totalIncome: totalIncome ?? this.totalIncome,
      totalExpense: totalExpense ?? this.totalExpense,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class TransactionsNotifier extends Notifier<TransactionListState> {
  static const _pageSize = 25;
  int _generation = 0; // discards responses from superseded requests

  @override
  TransactionListState build() {
    ref.watch(currentUserProvider); // reset when the user changes
    Future.microtask(refresh);
    return const TransactionListState();
  }

  ApiService get _api => ref.read(apiServiceProvider);

  TransactionQuery _query(int page) {
    final f = state.filter;
    return TransactionQuery(
      page: page,
      pageSize: _pageSize,
      search: f.search,
      type: f.type,
      category: f.category,
      dateFrom: f.range?.start,
      dateTo: f.range?.end,
    );
  }

  Future<void> refresh() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final generation = ++_generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await _api.getTransactions(user.id, _query(1));
      if (generation != _generation) return;
      state = state.copyWith(
        items: page.items,
        page: 1,
        pages: page.pages,
        total: page.total,
        totalIncome: page.totalIncome,
        totalExpense: page.totalExpense,
        loading: false,
      );
    } on ApiException catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(loading: false, error: e.message);
    }
  }

  Future<void> loadMore() async {
    final user = ref.read(currentUserProvider);
    if (user == null || state.loading || state.loadingMore || !state.hasMore) return;
    final generation = _generation;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await _api.getTransactions(user.id, _query(state.page + 1));
      if (generation != _generation) return;
      state = state.copyWith(
        items: [...state.items, ...page.items],
        page: page.page,
        pages: page.pages,
        loadingMore: false,
      );
    } on ApiException catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(loadingMore: false, error: e.message);
    }
  }

  void setFilter(TransactionFilter filter) {
    state = state.copyWith(filter: filter);
    refresh();
  }

  /// Throws [ApiException]; the inline editor shows the message.
  Future<Transaction> updateTransaction(int id, Map<String, dynamic> changes) async {
    final updated = await _api.updateTransaction(id, changes);
    state = state.copyWith(items: [for (final t in state.items) t.id == id ? updated : t]);
    _refreshOthers();
    return updated;
  }

  Future<void> deleteTransaction(int id) async {
    await _api.deleteTransaction(id);
    state = state.copyWith(
      items: state.items.where((t) => t.id != id).toList(),
      total: state.total > 0 ? state.total - 1 : 0,
    );
    _refreshOthers();
  }

  void _refreshOthers() {
    ref.invalidate(forecastProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(budgetsProvider);
  }
}

final transactionsProvider =
    NotifierProvider<TransactionsNotifier, TransactionListState>(TransactionsNotifier.new);

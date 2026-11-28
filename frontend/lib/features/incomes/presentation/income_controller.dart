import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/income_repository.dart';

const emptyIncomeFilters = (
  search: '',
  category: null,
  wallet: null,
  dates: null,
);

class IncomeController extends ChangeNotifier {
  IncomeController(this.auth, this.repository) : _owner = auth.user?.id {
    auth.addListener(_authChanged);
  }

  final AuthController auth;
  final IncomeRepository repository;
  String? _owner;
  int _historyRevision = 0;
  int _summaryRevision = 0;
  bool _disposed = false;
  Timer? _debounce;
  IncomeFilters filters = emptyIncomeFilters;
  DateTime month = colomboToday();
  List<IncomeRecord> items = [];
  IncomeSummary? summary;
  int? next;
  bool loading = false;
  bool loadingSummary = false;
  String? historyError;
  String? summaryError;

  void _authChanged() {
    final owner = auth.stage == AuthStage.signedIn ? auth.user?.id : null;
    if (_owner == owner) return;
    _owner = owner;
    filters = emptyIncomeFilters;
    month = colomboToday();
    unawaited(reload());
  }

  void _clearHistory() {
    _debounce?.cancel();
    _historyRevision++;
    items = [];
    next = null;
    historyError = null;
    loading = _owner != null;
  }

  void search(String value) {
    filters = (
      search: value.trim(),
      category: filters.category,
      wallet: filters.wallet,
      dates: filters.dates,
    );
    _clearHistory();
    notifyListeners();
    _debounce = Timer(const Duration(milliseconds: 300), reloadHistory);
  }

  void applyFilters(
    String? category,
    String? wallet,
    DateTimeRangeValue? dates,
  ) {
    filters = (
      search: filters.search,
      category: category,
      wallet: wallet,
      dates: dates,
    );
    unawaited(reloadHistory());
  }

  void selectMonth(DateTime value) {
    month = DateTime(value.year, value.month);
    unawaited(reloadSummary());
  }

  Future<void> reload() async {
    await Future.wait([reloadHistory(), reloadSummary()]);
  }

  Future<void> reloadHistory() async {
    _clearHistory();
    if (_owner == null) {
      notifyListeners();
      return;
    }
    await _loadHistory(0);
  }

  Future<void> more() async {
    final offset = next;
    if (!loading && offset != null) await _loadHistory(offset);
  }

  Future<void> _loadHistory(int offset) async {
    final revision = _historyRevision;
    final selected = filters;
    loading = true;
    historyError = null;
    notifyListeners();
    try {
      final page = await auth.authenticatedRead(
        (access) => repository.list(access, selected, offset),
      );
      if (_disposed || revision != _historyRevision) return;
      items = {
        for (final item in [...items, ...page.items]) item.id: item,
      }.values.toList();
      next = page.next;
    } catch (error) {
      if (!_disposed && revision == _historyRevision) {
        historyError = incomeError(error);
      }
    } finally {
      if (!_disposed && revision == _historyRevision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> reloadSummary() async {
    final revision = ++_summaryRevision;
    final selected = month;
    summary = null;
    summaryError = null;
    loadingSummary = _owner != null;
    notifyListeners();
    if (_owner == null) return;
    try {
      final result = await auth.authenticatedRead(
        (access) => repository.summary(access, selected),
      );
      if (!_disposed && revision == _summaryRevision) summary = result;
    } catch (error) {
      if (!_disposed && revision == _summaryRevision) {
        summaryError = incomeError(error);
      }
    } finally {
      if (!_disposed && revision == _summaryRevision) {
        loadingSummary = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    auth.removeListener(_authChanged);
    super.dispose();
  }
}

String incomeError(Object? error) => error is ApiFailure
    ? error.message
    : 'The income request could not be completed.';

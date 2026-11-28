import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/transfer_repository.dart';

const emptyTransferFilters = (
  search: '',
  wallet: null,
  kind: null,
  dates: null,
);

class TransferController extends ChangeNotifier {
  TransferController(this.auth, this.repository) : _owner = auth.user?.id {
    auth.addListener(_onAccountChange);
  }

  final AuthController auth;
  final TransferRepository repository;
  String? _owner;
  Timer? _debounce;
  int _revision = 0;
  bool _disposed = false;
  bool loading = false;
  String? error;
  int? next;
  TransferFilters filters = emptyTransferFilters;
  List<TransferRecord> items = [];

  void _onAccountChange() {
    final owner = auth.user?.id;
    if (_owner == owner) return;
    _owner = owner;
    filters = emptyTransferFilters;
    unawaited(reload());
  }

  void _invalidate() {
    _debounce?.cancel();
    _revision++;
    error = null;
    next = null;
    items = [];
    loading = _owner != null;
  }

  void search(String value) {
    filters = (
      search: value.trim(),
      wallet: filters.wallet,
      kind: filters.kind,
      dates: filters.dates,
    );
    _invalidate();
    notifyListeners();
    _debounce = Timer(const Duration(milliseconds: 300), reload);
  }

  void apply(TransferFilters value) {
    filters = value;
    unawaited(reload());
  }

  Future<void> reload() async {
    _invalidate();
    if (_owner == null) {
      notifyListeners();
      return;
    }
    await _load(0);
  }

  Future<void> more() async {
    final offset = next;
    if (!loading && offset != null) await _load(offset);
  }

  Future<void> _load(int offset) async {
    final revision = _revision;
    final selected = filters;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final page = await auth.authenticatedRead(
        (access) => repository.list(access, selected, offset),
      );
      if (_disposed || revision != _revision) return;
      items = {
        for (final item in [...items, ...page.items]) item.id: item,
      }.values.toList();
      next = page.next;
    } catch (failure) {
      if (!_disposed && revision == _revision) error = transferError(failure);
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    auth.removeListener(_onAccountChange);
    super.dispose();
  }
}

String transferError(Object? failure) => failure is ApiFailure
    ? failure.message
    : 'The transfer request could not be completed.';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/wallet_repository.dart';

class WalletController extends ChangeNotifier {
  WalletController(this.auth, this.repository) : _owner = auth.user?.id {
    auth.addListener(_authChanged);
  }
  final AuthController auth;
  final WalletRepository repository;
  String? _owner;
  int _revision = 0;
  bool _disposed = false;
  Timer? _debounce;

  WalletType? type;
  String search = '';
  bool archived = false;
  bool loading = false;
  String? error;
  WalletSummary? summary;
  List<WalletRecord> items = [];
  int? next;

  void _authChanged() {
    final owner = auth.stage == AuthStage.signedIn ? auth.user?.id : null;
    if (_owner == owner) return;
    _owner = owner;
    summary = null;
    search = '';
    type = null;
    archived = false;
    unawaited(reload());
  }

  void _invalidate() {
    _debounce?.cancel();
    _revision++;
    items = [];
    next = null;
    error = null;
    loading = _owner != null;
  }

  void filter(WalletType? value) {
    if (type == value) return;
    type = value;
    unawaited(reload());
  }

  void toggleArchived() {
    archived = !archived;
    unawaited(reload());
  }

  void setSearch(String value) {
    search = value.trim();
    _invalidate();
    notifyListeners();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(reload()),
    );
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
    final filter = type;
    final query = search;
    final showArchived = archived;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final (page, updatedSummary) = await (
        auth.authenticatedRead(
          (access) => repository.list(
            access,
            type: filter,
            search: query,
            archived: showArchived,
            offset: offset,
          ),
        ),
        offset == 0
            ? auth.authenticatedRead(repository.summary)
            : Future.value(summary),
      ).wait;
      if (_disposed || revision != _revision) return;
      items = {
        for (final item in [...items, ...page.items]) item.id: item,
      }.values.toList();
      next = page.next;
      summary = updatedSummary;
    } catch (failure) {
      if (!_disposed && revision == _revision) {
        final cause =
            failure
                is ParallelWaitError<
                  (WalletPage?, WalletSummary?),
                  (AsyncError?, AsyncError?)
                >
            ? failure.errors.$1?.error ?? failure.errors.$2?.error
            : failure;
        error = cause is ApiFailure ? cause.message : 'Could not load wallets.';
      }
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
    auth.removeListener(_authChanged);
    super.dispose();
  }
}

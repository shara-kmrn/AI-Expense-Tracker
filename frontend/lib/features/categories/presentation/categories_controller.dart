import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/category_repository.dart';

class CategoriesController extends ChangeNotifier {
  CategoriesController(this.auth, this.repository) : _owner = auth.user?.id {
    auth.addListener(_authChanged);
  }

  final AuthController auth;
  final CategoryRepository repository;
  String? _owner;
  int _revision = 0;
  int _session = 0;
  bool _disposed = false;
  Timer? _debounce;
  CategoryType type = CategoryType.expense;
  String search = '';
  bool archived = false;
  bool loading = false;
  bool mutating = false;
  String? error;
  String? notice;
  List<CategoryRecord> items = const [];
  int? nextOffset;

  bool _current(int version) =>
      !_disposed && version == _revision && _owner != null;

  void _authChanged() {
    final owner = auth.stage == AuthStage.signedIn ? auth.user?.id : null;
    if (_owner == owner) return;
    _owner = owner;
    _session++;
    _invalidate();
    notice = null;
    mutating = false;
    if (owner != null) {
      unawaited(reload());
    } else {
      notifyListeners();
    }
  }

  void _invalidate() {
    _debounce?.cancel();
    _revision++;
    items = const [];
    nextOffset = null;
    error = null;
    loading = false;
  }

  void setType(CategoryType value) {
    if (type == value) return;
    type = value;
    notice = null;
    unawaited(reload());
  }

  void setArchived(bool value) {
    if (archived == value) return;
    archived = value;
    notice = null;
    unawaited(reload());
  }

  void setSearch(String value) {
    search = value.trim();
    notice = null;
    _invalidate();
    loading = true;
    notifyListeners();
    _debounce = Timer(const Duration(milliseconds: 300), reload);
  }

  Future<void> reload() async {
    _invalidate();
    await _load(0);
  }

  Future<void> loadMore() async {
    final offset = nextOffset;
    if (loading || offset == null) return;
    await _load(offset);
  }

  Future<void> _load(int offset) async {
    final version = _revision;
    if (!_current(version)) return;
    final selectedType = type;
    final selectedSearch = search;
    final selectedArchived = archived;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final page = await auth.authenticatedRead(
        (access) => repository.list(
          access,
          selectedType,
          selectedSearch,
          archived: selectedArchived,
          offset: offset,
        ),
      );
      if (!_current(version)) return;
      final byId = {
        for (final item in [...items, ...page.items]) item.id: item,
      };
      items = byId.values.toList(growable: false);
      nextOffset = page.nextOffset;
    } catch (failure) {
      if (_current(version)) {
        error = failure is ApiFailure
            ? failure.message
            : 'Could not load categories.';
      }
    } finally {
      if (_current(version)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> setActive(CategoryRecord category, bool active) async {
    final owner = _owner;
    if (mutating || owner == null || category.isDefault) return;
    final session = _session;
    mutating = true;
    notice = null;
    notifyListeners();
    try {
      await auth.authenticatedMutation(
        (access) => repository.setActive(access, category.id, active: active),
      );
      if (_disposed || session != _session) return;
      notice = active ? 'Category restored.' : 'Category archived.';
      await reload();
    } catch (failure) {
      if (_disposed || session != _session) return;
      if (failure is ApiFailure && failure.uncertain) {
        notice = 'The result could not be confirmed. Check the refreshed list.';
        await reload();
      } else {
        notice = failure is ApiFailure
            ? failure.message
            : 'Could not update the category.';
      }
    } finally {
      if (!_disposed && session == _session) {
        mutating = false;
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

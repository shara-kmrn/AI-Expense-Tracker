import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String refresh);
  Future<void> clear();
}

class MemorySessionStore implements SessionStore {
  String? _refresh;

  @override
  Future<String?> read() async => _refresh;
  @override
  Future<void> write(String refresh) async => _refresh = refresh;
  @override
  Future<void> clear() async => _refresh = null;
}

class AndroidSessionStore implements SessionStore {
  AndroidSessionStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;
  static const _key = 'expense_tracker.refresh.v1';

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String refresh) =>
      _storage.write(key: _key, value: refresh);
  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      await _storage.write(key: _key, value: '');
    }
  }
}

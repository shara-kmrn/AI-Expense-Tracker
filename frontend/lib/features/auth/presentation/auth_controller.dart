import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/session_store.dart';
import '../data/auth_repository.dart';

enum AuthStage { starting, retryStartup, signedOut, signedIn }

class AuthController extends ChangeNotifier {
  AuthController(this.repository, this._store);
  final AuthRepository repository;
  final SessionStore _store;
  AuthStage stage = AuthStage.starting;
  UserProfile? user;
  String? notice;
  Credentials? _credentials;
  Future<Credentials>? _refreshing;
  Future<void> _storageTail = Future.value();
  int _epoch = 0;
  bool _disposed = false;

  Future<T> _storage<T>(Future<T> Function() operation) {
    final next = _storageTail.then((_) => operation());
    _storageTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check(int epoch) {
    if (epoch != _epoch || _disposed) {
      throw const ApiFailure('This session has ended.', status: 401);
    }
  }

  void message(String text) {
    notice = text;
    _notify();
  }

  Future<void> initialize() async {
    final epoch = _epoch;
    stage = AuthStage.starting;
    _notify();
    try {
      if (_credentials == null) {
        final stored = await _storage(
          () => _store.read().timeout(const Duration(seconds: 5)),
        );
        _check(epoch);
        if (stored == null || stored.isEmpty) {
          stage = AuthStage.signedOut;
          _notify();
          return;
        }
        await _renew(epoch, stored);
      }
      final profile = await _authorized(repository.profile, retryRead: true);
      _check(epoch);
      user = profile;
      stage = AuthStage.signedIn;
      _notify();
    } catch (_) {
      if (epoch == _epoch && !_disposed) {
        stage = AuthStage.retryStartup;
        message('Could not restore your session. Try again or sign in.');
      }
    }
  }

  Future<void> login(String email, String password) async {
    final epoch = _epoch;
    final credentials = await repository.login(email, password);
    try {
      _check(epoch);
      await _install(epoch, credentials);
      final profile = await repository.profile(credentials.access);
      _check(epoch);
      notice = null;
      user = profile;
      stage = AuthStage.signedIn;
      _notify();
    } catch (_) {
      if (epoch == _epoch && !_disposed) await _forget();
      await _revoke(credentials.access);
      rethrow;
    }
  }

  Future<void> _install(int epoch, Credentials credentials) async {
    try {
      await _storage(() async {
        _check(epoch);
        await _store.write(credentials.refresh);
      });
    } catch (_) {
      _check(epoch);
      throw const ApiFailure(
        'Could not save your session securely. Sign in again.',
      );
    }
    _check(epoch);
    _credentials = credentials;
  }

  Future<Credentials> _renew(int epoch, String token) {
    _check(epoch);
    if (_refreshing case final pending?) return pending;
    late Future<Credentials> renewal;
    renewal = _rotate(epoch, token).whenComplete(() {
      if (identical(_refreshing, renewal)) _refreshing = null;
    });
    return _refreshing = renewal;
  }

  Future<Credentials> _rotate(int epoch, String refresh) async {
    Credentials? rotated;
    try {
      rotated = await repository.refresh(refresh);
      if (epoch == _epoch && !_disposed) await _install(epoch, rotated);
      return rotated;
    } catch (error) {
      if (rotated != null && epoch == _epoch) {
        await _forget('Secure storage failed. Sign in again.');
        await _revoke(rotated.access);
      } else if (rotated != null) {
        // Logout can use the new access token to revoke the session family.
        return rotated;
      } else if (epoch == _epoch) {
        if (error is ApiFailure && error.status == 429) rethrow;
        await _forget(
          error is ApiFailure && error.status == 401
              ? 'Your session ended. Sign in again.'
              : 'Could not confirm session renewal. Sign in again.',
        );
      }
      rethrow;
    }
  }

  Future<T> _authorized<T>(
    Future<T> Function(String access) operation, {
    bool retryRead = false,
  }) async {
    final epoch = _epoch;
    var credentials = _credentials;
    if (credentials == null) {
      throw const ApiFailure('Sign in again.', status: 401);
    }
    if (!credentials.refreshExpiresAt.isAfter(DateTime.now())) {
      await _forget('Your session ended. Sign in again.');
      throw const ApiFailure('Your session ended. Sign in again.', status: 401);
    }
    if (!credentials.accessExpiresAt.isAfter(DateTime.now())) {
      credentials = await _renew(epoch, credentials.refresh);
    }
    _check(epoch);
    try {
      final result = await operation(credentials.access);
      _check(epoch);
      return result;
    } on ApiFailure catch (error) {
      _check(epoch);
      if (error.status != 401) rethrow;
      if (!retryRead) {
        if (identical(_credentials, credentials)) {
          await _forget('Your session ended. Sign in again.');
        }
        rethrow;
      }
      final current = _credentials!;
      final fresh = identical(current, credentials)
          ? await _renew(epoch, credentials.refresh)
          : current;
      _check(epoch);
      try {
        final result = await operation(fresh.access);
        _check(epoch);
        return result;
      } on ApiFailure catch (retryError) {
        if (_epoch == epoch &&
            retryError.status == 401 &&
            identical(_credentials, fresh)) {
          await _forget('Your session ended. Sign in again.');
        }
        rethrow;
      }
    }
  }

  Future<void> loadProfile() async {
    final epoch = _epoch;
    final profile = await _authorized(repository.profile, retryRead: true);
    _check(epoch);
    user = profile;
    _notify();
  }

  Future<void> editProfile(String name) async {
    final epoch = _epoch;
    final profile = await _authorized(
      (access) => repository.edit(access, name),
    );
    _check(epoch);
    user = profile;
    _notify();
  }

  Future<void> changePassword(String current, String next) => _endAfter(
    (access) => repository.changePassword(access, current, next),
    'Password changed. Sign in with your new password.',
  );

  Future<void> deleteAccount(String password) => _endAfter(
    (access) => repository.delete(access, password),
    'Your account was deleted.',
  );

  Future<void> _endAfter(
    Future<void> Function(String) action,
    String success,
  ) async {
    final epoch = _epoch;
    try {
      await _authorized(action);
    } on ApiFailure catch (error) {
      if (error.uncertain && _epoch == epoch) {
        await _forget(
          'The result could not be confirmed. Sign in again to check.',
        );
      }
      rethrow;
    }
    _check(epoch);
    await _forget(success);
  }

  Future<void> logout() async {
    final access = _credentials?.access;
    final pending = _refreshing;
    final localCleared = _forget();
    final epoch = _epoch;
    var revoked = access != null && await _revoke(access);
    if (pending != null) {
      try {
        final renewed = await pending;
        if (!revoked) revoked = await _revoke(renewed.access);
      } catch (_) {
        // An uncertain rotation cannot be retried safely.
      }
    }
    if (!await localCleared) return;
    if (epoch == _epoch && !revoked && access != null) {
      message(
        'Signed out on this device. Server revocation could not be confirmed.',
      );
    }
  }

  Future<bool> _revoke(String access) async {
    try {
      await repository.logout(access);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _forget([String? text]) async {
    final epoch = ++_epoch;
    _credentials = null;
    _refreshing = null;
    user = null;
    notice = text;
    stage = AuthStage.signedOut;
    final clear = _storage(_store.clear);
    _notify();
    try {
      await clear;
      return true;
    } catch (_) {
      if (epoch == _epoch) {
        message(
          'Could not clear saved credentials. Clear the app data before reusing this device.',
        );
      }
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}

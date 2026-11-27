import 'dart:async';
import 'dart:convert';

import 'package:expense_tracker/core/network/api_client.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/data/auth_repository.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:expense_tracker/features/auth/presentation/auth_forms.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const base = 'http://127.0.0.1:8000/api/v1';

http.Response tokens([String version = 'first']) => http.Response(
  jsonEncode({
    'access_token': 'access-$version',
    'refresh_token': 'refresh-$version',
    'token_type': 'bearer',
    'expires_in': 900,
    'refresh_expires_at': '2099-01-01T00:00:00Z',
  }),
  200,
);

http.Response profile([String name = 'Test User']) => http.Response(
  jsonEncode({
    'id': 'synthetic-user',
    'full_name': name,
    'email': 'test@example.com',
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
  }),
  200,
);

class TestStore extends MemorySessionStore {
  bool failWrite = false;
  @override
  Future<void> write(String refresh) async {
    if (failWrite) throw StateError('Synthetic storage fault');
    await super.write(refresh);
  }
}

AuthRepository repo(
  FutureOr<http.Response> Function(http.Request) handler, {
  Duration timeout = const Duration(seconds: 2),
}) => AuthRepository(
  ApiClient(
    base,
    MockClient((request) async => handler(request)),
    allowLocalHttp: true,
    timeout: timeout,
  ),
);

void main() {
  test('client validation counts Unicode scalars and preserves spaces', () {
    expect(validateEmail(' person@example.com '), isNull);
    expect(validateEmail('bad..name@example.com'), isNotNull);
    expect(validateEmail('person@example'), isNotNull);
    expect(validatePassword('𐐀' * 128, isNew: true), isNull);
    expect(validatePassword('𐐀' * 129, isNew: true), isNotNull);
    expect(validatePassword(' ' * 15, isNew: true), isNull);
    expect(validatePassword('𐐀' * 14, isNew: true), isNotNull);
  });

  test(
    'trusted origin and redirects enforced for credentialed requests',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.origin, 'http://127.0.0.1:8000');
        expect(request.followRedirects, isFalse);
        expect(request.headers['authorization'], 'Bearer sample');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://other.example'},
        );
      });
      for (final invalid in [
        'http://other.example/api/v1',
        'https://user@other.example/api/v1',
        'https://other.example/api/v1?x=y',
        'https://other.example/api/v1#fragment',
      ]) {
        expect(
          () => ApiClient(invalid, client, allowLocalHttp: true),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(
        () => ApiClient(base, client, allowLocalHttp: false),
        throwsA(isA<ApiFailure>()),
      );
      final api = ApiClient(base, client, allowLocalHttp: true);
      await expectLater(
        api.send(Endpoint.profile, bearer: 'sample'),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests, 1);
    },
  );

  test(
    'registration, generic recovery, and sanitized error mappings',
    () async {
      var status = 201;
      final repository = repo((request) {
        if (request.url.path.endsWith('/register')) {
          expect(jsonDecode(request.body), {
            'full_name': 'Name',
            'email': 'test@example.com',
            'password': ' unchanged value ',
          });
          return http.Response(
            status == 201 ? '{}' : '{"detail":"fixture internal detail"}',
            status,
          );
        }
        if (request.url.path.endsWith('/forgot-password')) {
          return http.Response('{}', 202);
        }
        if (request.url.path.endsWith('/reset-password')) {
          expect(
            jsonDecode(request.body).keys,
            unorderedEquals(['reset_token', 'new_password']),
          );
          return http.Response('', status);
        }
        return http.Response('{"detail":"fixture internal detail"}', 401);
      });
      await repository.register(
        'Name',
        'test@example.com',
        ' unchanged value ',
      );
      status = 409;
      await expectLater(
        repository.register('Name', 'test@example.com', ' unchanged value '),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
      );
      await repository.forgot('test@example.com');
      status = 204;
      await repository.reset('a' * 43, ' changed password ');
      status = 400;
      await expectLater(
        repository.reset('b' * 43, ' changed password '),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.message,
            'message',
            'That recovery code is invalid or expired.',
          ),
        ),
      );
      await expectLater(
        repository.login('test@example.com', 'fixture'),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.message,
            'message',
            'Email or password is incorrect.',
          ),
        ),
      );
    },
  );

  test(
    'restoration rotates stored refresh and loads current profile',
    () async {
      final store = TestStore();
      await store.write('refresh-first');
      final auth = AuthController(
        repo((request) {
          if (request.url.path.endsWith('/refresh')) {
            expect(jsonDecode(request.body)['refresh_token'], 'refresh-first');
            return tokens('second');
          }
          expect(request.headers['authorization'], 'Bearer access-second');
          return profile();
        }),
        store,
      );
      await auth.initialize();
      expect(auth.stage, AuthStage.signedIn);
      expect(auth.user?.fullName, 'Test User');
      expect(await store.read(), 'refresh-second');
    },
  );

  test(
    'concurrent 401s share one refresh and retry their reads once',
    () async {
      final renewed = Completer<http.Response>();
      final started = Completer<void>();
      final store = TestStore();
      var firstReads = 0;
      var renewals = 0;
      final auth = AuthController(
        repo((request) {
          if (request.url.path.endsWith('/login')) return tokens();
          if (request.url.path.endsWith('/refresh')) {
            renewals++;
            if (!started.isCompleted) started.complete();
            return renewed.future;
          }
          if (request.headers['authorization'] == 'Bearer access-first' &&
              firstReads++ > 0) {
            return http.Response('', 401);
          }
          return profile();
        }),
        store,
      );
      await auth.login('test@example.com', 'fixture');
      final requests = [auth.loadProfile(), auth.loadProfile()];
      await started.future;
      renewed.complete(tokens('second'));
      await Future.wait(requests);
      expect(renewals, 1);
      expect(await store.read(), 'refresh-second');
    },
  );

  test('uncertain refresh times out, clears local token, and does not retry rotation', () async {
    final store = TestStore();
    await store.write('refresh-first');
    var calls = 0;
    final auth = AuthController(
      repo((_) {
        calls++;
        return Completer<http.Response>().future;
      }, timeout: const Duration(milliseconds: 10)),
      store,
    );
    await auth.initialize();
    expect(calls, 1);
    expect(auth.stage, AuthStage.signedOut);
    expect(
      auth.notice,
      contains('${'could not confirm'.toUpperCase()[0]}ould not confirm'),
    );
    expect(await store.read(), isNull);
  });

  test('confirmed refresh rejection clears a saved session', () async {
    final store = TestStore();
    await store.write('revoked-session');
    final auth = AuthController(repo((_) => http.Response('', 401)), store);
    await auth.initialize();
    expect(auth.stage, AuthStage.signedOut);
    expect(await store.read(), isNull);
  });

  test('logout during refresh cannot restore credentials', () async {
    final store = TestStore();
    final renewed = Completer<http.Response>();
    final started = Completer<void>();
    var reads = 0;
    final revocations = <String?>[];
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/refresh')) {
          started.complete();
          return renewed.future;
        }
        if (request.url.path.endsWith('/logout')) {
          final access = request.headers['authorization'];
          revocations.add(access);
          return http.Response(
            '',
            access == 'Bearer access-second' ? 204 : 401,
          );
        }
        return reads++ == 0 ? profile() : http.Response('', 401);
      }),
      store,
    );
    await auth.login('test@example.com', 'fixture');
    final read = expectLater(auth.loadProfile(), throwsA(isA<ApiFailure>()));
    await started.future;
    final logout = auth.logout();
    renewed.complete(tokens('second'));
    await read;
    await logout;
    expect(revocations, ['Bearer access-first', 'Bearer access-second']);
    expect(auth.stage, AuthStage.signedOut);
    expect(auth.user, isNull);
    expect(await store.read(), isNull);
  });

  test('secure storage failure after rotation signs out and revokes', () async {
    final store = TestStore();
    await store.write('refresh-first');
    store.failWrite = true;
    var revoked = false;
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/refresh')) return tokens('second');
        revoked = request.url.path.endsWith('/logout');
        return http.Response('', 204);
      }),
      store,
    );
    await auth.initialize();
    expect(revoked, isTrue);
    expect(auth.stage, AuthStage.signedOut);
    expect(await store.read(), isNull);
  });

  test('profile read stops after one refresh and one rejected retry', () async {
    final store = TestStore();
    var reads = 0;
    var refreshes = 0;
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/refresh')) {
          refreshes++;
          return tokens('second');
        }
        return reads++ == 0 ? profile() : http.Response('', 401);
      }),
      store,
    );
    await auth.login('test@example.com', 'fixture');
    await expectLater(auth.loadProfile(), throwsA(isA<ApiFailure>()));
    expect(reads, 3);
    expect(refreshes, 1);
    expect(auth.stage, AuthStage.signedOut);
    expect(auth.user, isNull);
    expect(await store.read(), isNull);
  });

  for (final method in ['PATCH', 'POST', 'DELETE']) {
    test('$method account mutation is never replayed after a 401', () async {
      final store = TestStore();
      var mutations = 0;
      var refreshes = 0;
      final auth = AuthController(
        repo((request) {
          if (request.url.path.endsWith('/login')) return tokens();
          if (request.url.path.endsWith('/refresh')) {
            refreshes++;
            return tokens('second');
          }
          if (request.method == 'GET') return profile();
          expect(request.method, method);
          expect(request.headers['authorization'], 'Bearer access-first');
          mutations++;
          return http.Response('', 401);
        }),
        store,
      );
      await auth.login('test@example.com', 'fixture');
      final operation = switch (method) {
        'PATCH' => auth.editProfile('Changed name'),
        'POST' => auth.changePassword('fixture current', 'fixture replacement'),
        _ => auth.deleteAccount('fixture current'),
      };
      await expectLater(operation, throwsA(isA<ApiFailure>()));
      expect(mutations, 1);
      expect(refreshes, 0);
      expect(auth.stage, AuthStage.signedOut);
      expect(await store.read(), isNull);
    });
  }

  test(
    'uncertain account deletion clears the session without replaying DELETE',
    () async {
      final store = TestStore();
      final pending = Completer<http.Response>();
      var deletes = 0;
      final auth = AuthController(
        repo((request) {
          if (request.url.path.endsWith('/login')) return tokens();
          if (request.method == 'GET') return profile();
          expect(request.method, 'DELETE');
          deletes++;
          return pending.future;
        }, timeout: const Duration(milliseconds: 25)),
        store,
      );
      await auth.login('test@example.com', 'fixture');
      await expectLater(
        auth.deleteAccount('fixture'),
        throwsA(isA<ApiFailure>()),
      );
      pending.complete(http.Response('', 204));
      expect(deletes, 1);
      expect(auth.stage, AuthStage.signedOut);
      expect(auth.user, isNull);
      expect(await store.read(), isNull);
      expect(auth.notice, contains('could not be confirmed'));
    },
  );

  test('offline logout clears local credentials and discards a stale profile result', () async {
    final store = TestStore();
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    var reads = 0;
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/logout')) {
          throw http.ClientException('Synthetic offline failure');
        }
        if (reads++ == 0) return profile();
        started.complete();
        return pending.future;
      }),
      store,
    );
    await auth.login('test@example.com', 'fixture');
    final read = expectLater(auth.loadProfile(), throwsA(isA<ApiFailure>()));
    await started.future;
    await auth.logout();
    pending.complete(profile('Stale user'));
    await read;
    expect(auth.stage, AuthStage.signedOut);
    expect(auth.user, isNull);
    expect(await store.read(), isNull);
    expect(auth.notice, contains('Server revocation could not be confirmed'));
  });

  test('profile mutation updates state and a rejected password change keeps the session', () async {
    final store = TestStore();
    var mutations = 0;
    var status = 400;
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/change-password')) {
          mutations++;
          return http.Response('', status);
        }
        if (request.method == 'PATCH') {
          expect(jsonDecode(request.body), {'full_name': 'Updated User'});
          return profile('Updated User');
        }
        return profile();
      }),
      store,
    );
    await auth.login('test@example.com', 'fixture');
    await auth.editProfile('Updated User');
    expect(auth.user?.fullName, 'Updated User');
    await expectLater(
      auth.changePassword('current', 'new'),
      throwsA(isA<ApiFailure>()),
    );
    expect(auth.stage, AuthStage.signedIn);
    status = 204;
    await auth.changePassword('current', 'new');
    expect(mutations, 2);
    expect(auth.stage, AuthStage.signedOut);
    expect(await store.read(), isNull);
  });
}

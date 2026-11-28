import 'dart:async';
import 'dart:convert';

import 'package:expense_tracker/app/app.dart';
import 'package:expense_tracker/core/network/api_client.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/data/auth_repository.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:expense_tracker/features/wallets/data/wallet_repository.dart';
import 'package:expense_tracker/features/wallets/presentation/wallet_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'auth_test.dart' show base, profile, tokens;

const id = '10000000-0000-4000-8000-000000000001';

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object> record(
  String name, {
  String amount = '0.00',
  bool active = true,
}) => {
  'id': id,
  'name': name,
  'currency': 'LKR',
  'type': 'CASH',
  'icon': 'wallet',
  'color': '#D4AF37',
  'is_active': active,
  'opening_balance': amount,
  'current_balance': amount,
  'created_at': '2026-11-28T00:00:00Z',
  'updated_at': '2026-11-28T00:00:00Z',
};

Map<String, Object> totals({
  String total = '0.00',
  int active = 0,
  int archived = 0,
}) => {
  'currency': 'LKR',
  'total_active_balance': total,
  'active_count': active,
  'archived_count': archived,
  'balances_by_type': {'CASH': total, 'BANK': '0.00', 'DIGITAL': '0.00'},
};

http.Response listing(List<Map<String, Object>> rows, {int? next}) =>
    json({'items': rows, 'next_offset': next});

ApiClient api(FutureOr<http.Response> Function(http.Request) dispatch) =>
    ApiClient(
      base,
      MockClient((request) async => dispatch(request)),
      allowLocalHttp: true,
    );

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'wallet and summary money stay exact beyond JavaScript integer precision',
    () {
      for (final value in ['0', '000.12', '9999999999999999.99']) {
        expect(validOpeningBalance(value), isTrue);
      }
      for (final value in [
        '',
        '-1',
        '+1',
        '1.000',
        '1e4',
        'NaN',
        'Infinity',
        '1\n',
        '10000000000000000',
        '.01',
        '1.',
        '1,000.00',
      ]) {
        expect(validOpeningBalance(value), isFalse);
      }
      final wallet = WalletRecord.fromJson(
        record('Cash', amount: '9999999999999999.99'),
      );
      expect(wallet.opening, BigInt.parse('999999999999999999'));
      expect(wallet.current, wallet.opening);
      expect(walletMoney(wallet.current), 'LKR 9,999,999,999,999,999.99');
      expect(walletMoney(BigInt.zero), 'LKR 0.00');
      final summary = WalletSummary.fromJson(
        totals(total: '20000000000000000.00', active: 2, archived: 1),
      );
      expect(summary.breakdown[WalletType.cash], summary.total);
      expect(walletMoney(summary.total), 'LKR 20,000,000,000,000,000.00');
      expect(() => parseWalletMoney('2.0'), throwsFormatException);
      expect(
        () => WalletSummary.fromJson({...totals(), 'currency': 'USD'}),
        throwsFormatException,
      );
    },
  );

  test(
    'constructs trusted requests and sends financial fields only on creation',
    () async {
      final requests = <http.Request>[];
      final repository = WalletRepository(
        api((request) {
          requests.add(request);
          return request.method == 'GET'
              ? listing([], next: 50)
              : json(
                  record('Large wallet'),
                  request.method == 'POST' ? 201 : 200,
                );
        }),
      );
      final page = await repository.list(
        'token',
        type: WalletType.bank,
        archived: true,
        search: '100% & Café',
        offset: 4,
      );
      expect(page.next, 50);
      expect(requests.single.url.queryParameters, {
        'type': 'BANK',
        'active': 'false',
        'q': '100% & Café',
        'limit': '50',
        'offset': '4',
      });
      const draft = (
        name: 'Large wallet',
        amount: '9999999999999999.99',
        type: WalletType.bank,
        icon: 'wallet',
        color: '#D4AF37',
      );
      await repository.save('token', draft);
      await repository.save('token', draft, id: id);
      expect(jsonDecode(requests[1].body)['opening_balance'], draft.amount);
      expect(jsonDecode(requests[2].body), {
        'name': 'Large wallet',
        'icon': 'wallet',
        'color': '#D4AF37',
      });
      expect(requests[2].url.path, '/api/v1/wallets/$id');
      expect(requests[2].headers['authorization'], 'Bearer token');
      expect(requests[2].followRedirects, isFalse);
      await expectLater(
        repository.get('token', 'https://foreign.invalid'),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests, hasLength(3));
    },
  );

  test('pagination preserves the filter and stale balances are rejected after an account switch', () async {
    final older = Completer<http.Response>();
    final oldSession = Completer<http.Response>();
    final calls = <Uri>[];
    var accountNumber = 0;
    final client = api((request) {
      final path = request.url.path;
      if (path.endsWith('/login')) return tokens('${++accountNumber}');
      if (path.endsWith('/logout')) return http.Response('', 204);
      if (path.endsWith('/me')) {
        return json({
          ...jsonDecode(profile().body) as Map,
          'id': '$accountNumber',
        });
      }
      if (path.endsWith('/summary')) {
        return json(totals(total: accountNumber == 1 ? '100.00' : '0.00'));
      }
      calls.add(request.url);
      return switch (calls.length) {
        1 => older.future,
        2 => listing([record('First page')], next: 50),
        3 => listing([record('Second page')..['id'] = 'second']),
        4 => oldSession.future,
        _ => listing([record('New account')]),
      };
    });
    final auth = AuthController(AuthRepository(client), MemorySessionStore());
    await auth.login('first@example.com', 'fixture');
    final state = WalletController(auth, WalletRepository(client));
    addTearDown(state.dispose);
    final stale = state.reload();
    state.filter(WalletType.bank);
    await Future<void>.delayed(Duration.zero);
    older.complete(listing([record('Old filter')]));
    await stale;
    expect(state.items.single.name, 'First page');
    await state.more();
    expect(state.items.map((row) => row.name), ['First page', 'Second page']);
    expect(calls[2].queryParameters['type'], 'BANK');
    expect(calls[2].queryParameters['offset'], '50');
    final pending = state.reload();
    await auth.logout();
    expect(state.items, isEmpty);
    expect(state.summary, isNull);
    await auth.login('second@example.com', 'fixture');
    oldSession.complete(listing([record('Private prior wallet')]));
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(state.items.single.name, 'New account');
    expect(state.summary?.total, BigInt.zero);
    expect(calls.last.queryParameters, isNot(contains('type')));
  });

  test(
    'wallet reads retry renewal, but a rejected create never replays',
    () async {
      var reads = 0;
      var writes = 0;
      var renewals = 0;
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/refresh')) {
          renewals++;
          return tokens('renewed');
        }
        if (request.method == 'POST') {
          writes++;
          return http.Response('', 401);
        }
        if (++reads == 1) return http.Response('', 401);
        expect(request.headers['authorization'], 'Bearer access-renewed');
        return json(totals());
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      addTearDown(auth.dispose);
      await auth.login('test@example.com', 'fixture');
      final repository = WalletRepository(client);
      expect(
        (await auth.authenticatedRead(repository.summary)).total,
        BigInt.zero,
      );
      const draft = (
        name: 'Cash box',
        type: WalletType.cash,
        amount: '0.00',
        icon: 'wallet',
        color: '#D4AF37',
      );
      await expectLater(
        auth.authenticatedMutation((access) => repository.save(access, draft)),
        throwsA(isA<ApiFailure>()),
      );
      expect((reads, writes, renewals), (2, 1, 1));
      expect(auth.stage, AuthStage.signedOut);
    },
  );

  testWidgets(
    'guarded wallet flow validates creation, edits metadata and reloads after archive and restore',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? name;
      var active = true;
      var creates = 0;
      var archives = 0;
      var summaryRequests = 0;
      var failList = true;
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/summary')) {
          summaryRequests++;
          return json(
            totals(
              total: '1.00',
              active: active && name != null ? 2 : 1,
              archived: active ? 0 : 1,
            ),
          );
        }
        if (request.method == 'DELETE') {
          archives++;
          final archived = request.url.path.endsWith(id);
          expect(archived, isTrue);
          if (archives == 1) {
            throw http.ClientException('Synthetic network failure');
          }
          active = false;
          return http.Response('', 204);
        }
        if (path.endsWith('/restore')) {
          active = true;
          return json(record(name!));
        }
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['opening_balance'], '0.00');
          expect(body['icon'], 'home');
          expect(body['color'], '#A5F3FC');
          if (++creates == 1) return http.Response('', 409);
          name = body['name'] as String;
          return json(record(name!), 201);
        }
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.keys, unorderedEquals(['name', 'icon', 'color']));
          name = body['name'] as String;
          return json(record(name!));
        }
        if (path.endsWith(id)) return json(record(name!, active: active));
        if (failList) return http.Response('', 503);
        final q = request.url.queryParameters;
        return listing([
          if (q['active'] == 'true' && q['q'] == null && q['type'] != 'BANK')
            record('Funded', amount: '1.00')
              ..['id'] = '10000000-0000-4000-8000-000000000002',
          if (name != null &&
              (q['active'] == 'true') == active &&
              q['q'] == null &&
              q['type'] != 'BANK')
            record(name!, active: active),
        ]);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('Welcome back')))
          .go('/home/wallets');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Wallets'));
      expect(find.text('Try again'), findsOneWidget);
      failList = false;
      await tap(tester, find.text('Try again'));
      await tap(tester, find.widgetWithText(ChoiceChip, 'Bank'));
      expect(find.text('No wallets match.'), findsOneWidget);
      await tap(tester, find.widgetWithText(ChoiceChip, 'All'));
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('No wallets match.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Funded'), findsOneWidget);
      await tap(tester, find.byTooltip('Actions for Funded'));
      await tap(tester, find.text('Archive'));
      expect(find.textContaining('zero balance'), findsOneWidget);
      expect(archives, 0);
      await tap(tester, find.text('Add wallet'));
      final amount = find.widgetWithText(TextFormField, 'Opening balance');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Wallet name'),
        'Cash jar',
      );
      await tester.enterText(amount, '2.001');
      await tap(tester, find.text('Create wallet'));
      expect(find.textContaining('two decimal places'), findsOneWidget);
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '0.00');
      await tap(tester, find.widgetWithText(ChoiceChip, 'Home'));
      expect(find.bySemanticsLabel('Home'), findsWidgets);
      await tap(tester, find.widgetWithText(ChoiceChip, 'Ice'));
      await tap(tester, find.text('Create wallet'));
      expect(find.textContaining('already reserved'), findsOneWidget);
      await tap(tester, find.text('Create wallet'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 active'), findsOneWidget);
      await tap(tester, find.text('Cash jar'));
      expect(find.text('Wallet details'), findsOneWidget);
      expect(find.text('Opening balance'), findsOneWidget);
      await tap(tester, find.text('Edit wallet'));
      expect(find.text('Current balance: LKR 0.00'), findsOneWidget);
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'Cash box');
      await tap(tester, find.text('Save changes'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Cash box'), findsOneWidget);
      await tap(tester, find.text('Archive wallet'));
      await tap(tester, find.text('Cancel'));
      expect(archives, 0);
      await tap(tester, find.text('Archive wallet'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Archive wallet'),
        ),
      );
      expect(archives, 1);
      expect(find.textContaining('could not be confirmed'), findsOneWidget);
      await tap(tester, find.text('Archive wallet'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Archive wallet'),
        ),
      );
      expect(archives, 2);
      expect(find.text('Wallet archived.'), findsOneWidget);
      await tap(tester, find.byTooltip('Back'));
      await tap(tester, find.text('Archived wallets'));
      expect(find.text('Cash box'), findsOneWidget);
      await tap(tester, find.byTooltip('Actions for Cash box'));
      await tap(tester, find.text('Restore'));
      expect(find.text('Cash box'), findsNothing);
      expect(find.textContaining('2 active'), findsOneWidget);
      expect(summaryRequests, greaterThan(5));
      expect(tester.takeException(), isNull);
    },
  );
}

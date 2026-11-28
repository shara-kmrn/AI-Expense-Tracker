import 'dart:async';
import 'dart:convert';

import 'package:expense_tracker/app/app.dart';
import 'package:expense_tracker/core/network/api_client.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/data/auth_repository.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:expense_tracker/features/incomes/data/income_repository.dart';
import 'package:expense_tracker/features/incomes/presentation/income_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'auth_test.dart' show base, profile, tokens;

const incomeId = '10000000-0000-4000-8000-000000000001';
const categoryId = '10000000-0000-4000-8000-000000000002';
const walletId = '10000000-0000-4000-8000-000000000003';

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> income({String title = 'Salary', int version = 1}) => {
  'id': incomeId,
  'title': title,
  'currency': 'LKR',
  'amount': '9999999999999999.99',
  'income_date': '2024-02-29',
  'category_id': categoryId,
  'category_name': 'Salary',
  'category_icon': 'wallet',
  'category_color': '#D4AF37',
  'category_active': true,
  'wallet_id': walletId,
  'wallet_name': 'Cash box',
  'wallet_active': true,
  'version': version,
  'note': null,
  'created_at': '2026-11-28T10:00:00Z',
  'updated_at': '2026-11-28T10:00:00Z',
};

http.Response history(List<Map<String, Object?>> items, {int? next}) =>
    json({'items': items, 'next_offset': next});
http.Response summary([String total = '0.00']) =>
    json({'total': total, 'currency': 'LKR', 'count': 0, 'categories': []});
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
  testWidgets('an account without an active wallet cannot submit income', (
    tester,
  ) async {
    final client = api((request) {
      final path = request.url.path;
      if (path.endsWith('/login')) return tokens();
      if (path.endsWith('/me')) return profile();
      if (path.endsWith('/summary')) return summary();
      expect(request.method, 'GET');
      return history([]);
    });
    final auth = AuthController(AuthRepository(client), MemorySessionStore());
    await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
    await tester.pumpAndSettle();
    await auth.login('test@example.com', 'fixture');
    await tester.pumpAndSettle();
    await tap(tester, find.text('Income'));
    await tap(tester, find.text('Add income'));
    expect(
      find.text('Create an active wallet before recording income.'),
      findsOneWidget,
    );
    expect(find.text('Save income'), findsNothing);
  });

  test(
    'money, calendar dates and UUIDv4 operation keys retain exact values',
    () {
      final record = IncomeRecord.fromJson(income());
      expect(record.amount, BigInt.parse('999999999999999999'));
      expect(calendarDate(record.date), '2024-02-29');
      expect(
        IncomeSummary.fromJson({
          'total': '19999999999999999.98',
          'currency': 'LKR',
          'count': 2,
          'categories': [],
        }).total,
        BigInt.parse('1999999999999999998'),
      );
      expect(validIncomeAmount('000.00'), isFalse);
      expect(validIncomeAmount('0.01'), isTrue);
      expect(validIncomeAmount('1e3'), isFalse);
      expect(validIncomeAmount('0.001'), isFalse);
      final keys = List.generate(10, (_) => incomeOperationKey());
      expect(keys.toSet(), hasLength(10));
      expect(
        keys.every(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch,
        ),
        isTrue,
      );
    },
  );

  test(
    'uses bounded filters, exact body fields and concurrency headers',
    () async {
      final requests = <http.Request>[];
      final repository = IncomeRepository(
        api((request) {
          requests.add(request);
          return switch (request.method) {
            'GET' => history([], next: 50),
            'POST' => json(income(), 201),
            'DELETE' => http.Response('', 204),
            _ => json(income(version: 2)),
          };
        }),
      );
      final page = await repository.list('token', (
        search: 'A & B',
        category: categoryId,
        wallet: walletId,
        dates: (start: DateTime(2024, 2), end: DateTime(2024, 2, 29)),
      ), 10);
      expect(page.next, 50);
      expect(requests.first.url.queryParameters, {
        'q': 'A & B',
        'category_id': categoryId,
        'wallet_id': walletId,
        'date_from': '2024-02-01',
        'date_to': '2024-02-29',
        'limit': '50',
        'offset': '10',
      });
      final record = IncomeRecord.fromJson(income());
      final key = incomeOperationKey();
      await repository.create('token', {'amount': '1.20'}, key);
      await repository.edit('token', record, {'note': null});
      await repository.delete('token', record);
      expect(requests[1].headers['idempotency-key'], key);
      expect(jsonDecode(requests[1].body), {
        'amount': '1.20',
        'currency': 'LKR',
      });
      expect(jsonDecode(requests[2].body), {
        'note': null,
        'expected_version': 1,
      });
      expect(requests[3].headers['if-match'], '1');
      expect(requests[3].followRedirects, isFalse);
    },
  );

  test(
    'rejects stale month and history responses across account changes',
    () async {
      final oldHistory = Completer<http.Response>();
      final oldSummary = Completer<http.Response>();
      var account = 0;
      var historyCalls = 0;
      var summaryCalls = 0;
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens('${++account}');
        if (path.endsWith('/logout')) return http.Response('', 204);
        if (path.endsWith('/me')) {
          return json({...jsonDecode(profile().body) as Map, 'id': '$account'});
        }
        if (path.endsWith('/summary')) {
          if (++summaryCalls == 1) return oldSummary.future;
          return summary(account == 1 ? '2.00' : '0.00');
        }
        if (++historyCalls == 1) return oldHistory.future;
        return history([income(title: 'Second account')]);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await auth.login('first@example.com', 'fixture');
      final state = IncomeController(auth, IncomeRepository(client));
      addTearDown(state.dispose);
      final pending = state.reload();
      state.selectMonth(DateTime(2024, 2));
      await Future<void>.delayed(Duration.zero);
      expect(state.summary?.total, BigInt.from(200));
      await auth.logout();
      expect(state.items, isEmpty);
      expect(state.summary, isNull);
      await auth.login('second@example.com', 'fixture');
      oldHistory.complete(history([income(title: 'Private prior user')]));
      oldSummary.complete(summary('10000.00'));
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(state.items.single.title, 'Second account');
      expect(state.summary?.total, BigInt.zero);
    },
  );

  testWidgets(
    'guarded small-screen flow explicitly retries the unchanged creation and reverses once',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final keys = <String?>[];
      final bodies = <String>[];
      var saved = false;
      var reversals = 0;
      var version = 1;
      var edits = 0;
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/categories')) {
          return json({
            'items': [
              {
                'id': categoryId,
                'name': 'Wages',
                'type': 'INCOME',
                'icon': 'wallet',
                'color': '#D4AF37',
                'is_active': true,
                'is_default': true,
                'created_at': '2026-11-28T10:00:00Z',
                'updated_at': '2026-11-28T10:00:00Z',
              },
            ],
            'next_offset': null,
          });
        }
        if (path.endsWith('/wallets')) {
          return json({
            'items': [
              {
                'id': walletId,
                'name': 'Cash box',
                'type': 'CASH',
                'currency': 'LKR',
                'opening_balance': '0.00',
                'current_balance': '0.00',
                'icon': 'wallet',
                'color': '#D4AF37',
                'is_active': true,
                'created_at': '2026-11-28T10:00:00Z',
                'updated_at': '2026-11-28T10:00:00Z',
              },
            ],
            'next_offset': null,
          });
        }
        if (path.endsWith('/summary')) {
          return summary(saved ? '9999999999999999.99' : '0.00');
        }
        if (request.method == 'POST') {
          keys.add(request.headers['idempotency-key']);
          bodies.add(request.body);
          if (keys.length == 1) {
            throw http.ClientException('Synthetic transport failure');
          }
          saved = true;
          return json(income(title: 'Income fixture'), 201);
        }
        if (request.method == 'DELETE') {
          expect(request.headers['if-match'], '$version');
          reversals++;
          saved = false;
          return http.Response('', 204);
        }
        if (request.method == 'PATCH') {
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          expect(data['expected_version'], version);
          version++;
          if (++edits == 1) {
            return json({
              'detail': 'Income changed. Reload it before continuing.',
            }, 409);
          }
          return json(income(title: 'Income fixture', version: version));
        }
        if (path.endsWith(incomeId)) {
          return json(income(title: 'Income fixture', version: version));
        }
        return history(saved ? [income(title: 'Income fixture')] : []);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('Welcome back'))).go('/home/income');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Income'));
      await tap(tester, find.text('Add income'));
      final title = find.widgetWithText(TextFormField, 'Income title');
      final amount = find.widgetWithText(TextFormField, 'Amount (LKR)');
      await tester.enterText(title, 'Income fixture');
      await tester.enterText(amount, '9999999999999999.99');
      await tap(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Income category'),
      );
      await tap(tester, find.text('Wages').last);
      await tap(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Wallet'),
      );
      await tap(tester, find.text('Cash box').last);
      await tap(tester, find.text('Save income'));
      expect(keys, hasLength(1));
      expect(find.textContaining('result is uncertain'), findsOneWidget);
      await tap(tester, find.text('Check history'));
      await tap(tester, find.text('Open history'));
      expect(find.text('No income records match.'), findsOneWidget);
      await tap(tester, find.text('Add income'));
      expect(
        find.textContaining('previous income submission is unresolved'),
        findsOneWidget,
      );
      await tap(tester, find.text('Retry same submission'));
      expect(keys, [keys.first, keys.first]);
      expect(keys.first, isNotNull);
      expect(bodies.first, bodies.last);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Income fixture'));
      await tap(tester, find.text('Edit income'));
      await tap(tester, find.text('Save changes'));
      expect(
        find.text('Income changed. Reload it before continuing.'),
        findsOneWidget,
      );
      await tap(tester, find.text('Reload income'));
      await tap(tester, find.text('Edit income'));
      await tap(tester, find.text('Save changes'));
      expect(edits, 2);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Delete income'));
      await tap(tester, find.text('Cancel'));
      expect(reversals, 0);
      await tap(tester, find.text('Delete income'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete income'),
        ),
      );
      expect(reversals, 1);
      expect(find.text('Income fixture'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

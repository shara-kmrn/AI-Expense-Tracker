import 'dart:async';
import 'dart:convert';

import 'package:expense_tracker/app/app.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/data/auth_repository.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:expense_tracker/features/incomes/data/income_repository.dart';
import 'package:expense_tracker/features/incomes/presentation/income_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'auth_test.dart' show profile, tokens;
import 'incomes_test.dart'
    show api, categoryId, history, income, incomeId, json, tap, walletId;

Map<String, Object?> expense() => income(title: 'Groceries')
  ..remove('income_date')
  ..addAll({
    'expense_date': '2024-02-29',
    'amount': '5.02',
    'category_name': 'Food',
  });

Map<String, Object?> totals(String period, {bool saved = true}) => {
  'currency': 'LKR',
  'period': period,
  'start_date': '2024-02-29',
  'end_date': '2024-02-29',
  'total': saved ? '19999999999999999.98' : '0.00',
  'count': saved ? 1 : 0,
  'categories': saved
      ? [
          {
            'category_id': categoryId,
            'name': 'Food',
            'total': '19999999999999999.98',
          },
        ]
      : [],
};

void main() {
  test(
    'a stale expense period cannot replace the selected period or cross logout',
    () async {
      final old = Completer<http.Response>();
      final signedOut = Completer<http.Response>();
      final auth = AuthController(
        AuthRepository(
          api((request) {
            final path = request.url.path;
            if (path.endsWith('/login')) return tokens();
            if (path.endsWith('/me')) return profile();
            if (path.endsWith('/logout')) return http.Response('', 204);
            return history([]);
          }),
        ),
        MemorySessionStore(),
      );
      await auth.login('test@example.com', 'fixture');
      final controller = IncomeController(
        auth,
        IncomeRepository(
          api((request) {
            return switch (request.url.queryParameters['period']) {
              'day' => old.future,
              'month' => signedOut.future,
              _ => json(totals('week', saved: false)),
            };
          }),
          expense: true,
        ),
      );
      addTearDown(controller.dispose);
      final day = DateTime(2024, 2, 29);
      controller.selectExpensePeriod(day, ExpensePeriod.day);
      controller.selectExpensePeriod(day, ExpensePeriod.week);
      await Future<void>.delayed(Duration.zero);
      expect(controller.summary?.total, BigInt.zero);
      old.complete(json(totals('day')));
      await Future<void>.delayed(Duration.zero);
      expect(controller.summary?.total, BigInt.zero);
      controller.selectExpensePeriod(day, ExpensePeriod.month);
      await auth.logout();
      signedOut.complete(json(totals('month')));
      await Future<void>.delayed(Duration.zero);
      expect(controller.summary, isNull);
      expect(controller.items, isEmpty);
    },
  );

  testWidgets(
    'expense edits reload a stale version, estimate a refund, and refresh reassigned wallets',
    (tester) async {
      const bankId = '10000000-0000-4000-8000-000000000012';
      final item = expense();
      final balances = {walletId: '4.98', bankId: '7.00'};
      var writes = 0;
      Map<String, Object?> wallet(String id, String name, String type) => {
        'id': id,
        'name': name,
        'type': type,
        'currency': 'LKR',
        'opening_balance': '10.00',
        'current_balance': balances[id],
        'icon': 'wallet',
        'color': '#D4AF37',
        'is_active': true,
        'created_at': '2026-11-28T10:00:00Z',
        'updated_at': '2026-11-28T10:00:00Z',
      };
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/wallets/summary')) {
          return json({
            'currency': 'LKR',
            'total_active_balance': '12.98',
            'active_count': 2,
            'archived_count': 0,
            'balances_by_type': {
              'CASH': balances[walletId],
              'BANK': balances[bankId],
              'DIGITAL': '0.00',
            },
          });
        }
        if (path.endsWith('/wallets')) {
          return json({
            'items': [
              wallet(walletId, 'Cash box', 'CASH'),
              wallet(bankId, 'Bank account', 'BANK'),
            ],
            'next_offset': null,
          });
        }
        if (path.endsWith('/categories')) {
          return json({
            'items': [
              {
                'id': categoryId,
                'name': 'Food',
                'type': 'EXPENSE',
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
        if (path.endsWith('/expenses/summary')) return json(totals('month'));
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['expected_version'], item['version']);
          item['version'] = (item['version'] as int) + 1;
          if (++writes == 1) {
            return json({
              'detail': 'Expense changed. Reload it before continuing.',
            }, 409);
          }
          expect(body['amount'], '4.02');
          expect(body['wallet_id'], writes == 2 ? walletId : bankId);
          item['amount'] = body['amount'];
          item['wallet_id'] = body['wallet_id'];
          item['wallet_name'] = writes == 2 ? 'Cash box' : 'Bank account';
          balances[walletId] = writes == 2 ? '5.98' : '10.00';
          balances[bankId] = writes == 2 ? '7.00' : '2.98';
          return json(item);
        }
        if (path.endsWith(incomeId)) return json(item);
        return history([item]);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Expenses'));
      await tap(tester, find.text('Groceries'));
      await tap(tester, find.text('Edit expense'));
      final amount = find.widgetWithText(TextFormField, 'Amount (LKR)');
      expect(find.text('Available for this edit: LKR 10.00'), findsOneWidget);
      await tester.enterText(amount, '4.02');
      await tester.pump();
      expect(
        find.text('Estimated remaining balance: LKR 5.98'),
        findsOneWidget,
      );
      await tap(tester, find.text('Save changes'));
      expect(
        find.text('Expense changed. Reload it before continuing.'),
        findsOneWidget,
      );
      expect(find.text('Save changes'), findsNothing);
      await tap(tester, find.text('Reload expense'));
      await tap(tester, find.text('Edit expense'));
      await tester.enterText(amount, '4.02');
      await tap(tester, find.text('Save changes'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Edit expense'));
      await tap(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Wallet'),
      );
      await tap(
        tester,
        find.textContaining('Bank account · Bank · LKR 7.00').last,
      );
      expect(
        find.text('Estimated remaining balance: LKR 2.98'),
        findsOneWidget,
      );
      await tap(tester, find.text('Save changes'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(writes, 3);
      expect(find.text('Bank account'), findsOneWidget);
      final router = GoRouter.of(tester.element(find.text('Expense details')));
      router.go('/home/wallets');
      await tester.pumpAndSettle();
      expect(find.textContaining('LKR 10.00'), findsOneWidget);
      expect(find.textContaining('LKR 2.98'), findsOneWidget);
    },
  );

  test('expense repository uses exact amounts, date anchors and financial preconditions', () async {
    final requests = <http.Request>[];
    final repository = IncomeRepository(
      api((request) {
        requests.add(request);
        if (request.url.path.endsWith('/summary')) return json(totals('week'));
        if (request.method == 'POST') return json(expense(), 201);
        if (request.method == 'DELETE') return http.Response('', 204);
        return json(expense());
      }),
      expense: true,
    );
    final month = DateTime(2024, 2, 29);
    final summary = await repository.summary(
      'fixture',
      month,
      period: ExpensePeriod.week,
    );
    expect(summary.total, BigInt.parse('1999999999999999998'));
    expect(summary.start, month);
    expect(summary.categories.single.name, 'Food');
    expect(requests.first.url.queryParameters, {
      'period': 'week',
      'date': '2024-02-29',
    });
    final record = await repository.get('fixture', incomeId);
    expect(record.date, month);
    expect(record.amount, BigInt.from(502));
    expect(validIncomeAmount('0.00'), isFalse);
    expect(validIncomeAmount('5.021'), isFalse);
    const key = '10000000-0000-4000-8000-000000000010';
    await repository.create('fixture', {
      'amount': '5.02',
      'expense_date': '2024-02-29',
    }, key);
    expect(requests[2].headers['idempotency-key'], key);
    expect(jsonDecode(requests[2].body)['amount'], '5.02');
    await repository.edit('fixture', record, {'wallet_id': walletId});
    expect(jsonDecode(requests[3].body)['expected_version'], 1);
    await repository.delete('fixture', record);
    expect(requests[4].headers['if-match'], '1');
    expect(requests[4].url.path, '/api/v1/expenses/$incomeId');
    expect(requests[4].followRedirects, isFalse);
  });

  testWidgets(
    'guarded expense flow shows balance estimates, retries the same operation and refunds once',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final keys = <String?>[];
      final periods = <String?>[];
      var saved = false;
      var deletes = 0;
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/categories')) {
          expect(request.url.queryParameters['type'], 'EXPENSE');
          return json({
            'items': [
              {
                'id': categoryId,
                'name': 'Food',
                'type': 'EXPENSE',
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
                'opening_balance': '10.00',
                'current_balance': saved ? '4.98' : '10.00',
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
          final period = request.url.queryParameters['period']!;
          periods.add(period);
          return json(totals(period, saved: saved));
        }
        if (request.method == 'POST') {
          keys.add(request.headers['idempotency-key']);
          expect(jsonDecode(request.body)['amount'], '5.02');
          if (keys.length == 1) throw http.ClientException('Synthetic timeout');
          saved = true;
          return json(expense(), 201);
        }
        if (request.method == 'DELETE') {
          expect(request.headers['if-match'], '1');
          deletes++;
          saved = false;
          return http.Response('', 204);
        }
        if (path.endsWith(incomeId)) return json(expense());
        return history(saved ? [expense()] : []);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('Welcome back')))
          .go('/home/expenses');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Expenses'));
      await tap(tester, find.text('Daily'));
      await tap(tester, find.text('Weekly'));
      await tap(tester, find.text('Monthly'));
      expect(periods, containsAllInOrder(['day', 'week', 'month']));
      await tap(tester, find.text('Add expense'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Expense title'),
        'Groceries',
      );
      final amount = find.widgetWithText(TextFormField, 'Amount (LKR)');
      await tester.enterText(amount, '10.01');
      await tap(
        tester,
        find.widgetWithText(
          DropdownButtonFormField<String>,
          'Expense category',
        ),
      );
      await tap(tester, find.text('Food').last);
      await tap(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Wallet'),
      );
      await tap(
        tester,
        find.textContaining('Cash box · Cash · LKR 10.00').last,
      );
      expect(
        find.textContaining('may have insufficient funds'),
        findsOneWidget,
      );
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '5.02');
      await tester.pump();
      expect(
        find.text('Estimated remaining balance: LKR 4.98'),
        findsOneWidget,
      );
      await tap(tester, find.text('Save expense'));
      expect(keys, hasLength(1));
      await tap(tester, find.text('Retry same submission'));
      expect(keys, [keys.first, keys.first]);
      expect(keys.first, isNotNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Groceries'));
      expect(find.text('- LKR 5.02'), findsOneWidget);
      await tap(tester, find.text('Delete expense'));
      expect(find.textContaining('credited back'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      expect(deletes, 0);
      await tap(tester, find.text('Delete expense'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete expense'),
        ),
      );
      expect(deletes, 1);
      expect(find.text('Groceries'), findsNothing);
    },
  );
}

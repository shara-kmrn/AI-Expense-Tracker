import 'dart:async';
import 'dart:convert';

import 'package:expense_tracker/app/app.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/data/auth_repository.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:expense_tracker/features/incomes/data/income_repository.dart'
    show calendarDate, incomeOperationKey;
import 'package:expense_tracker/features/transfers/data/transfer_repository.dart';
import 'package:expense_tracker/features/transfers/presentation/transfer_controller.dart';
import 'package:expense_tracker/features/transfers/presentation/transfer_form.dart';
import 'package:expense_tracker/features/wallets/data/wallet_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'auth_test.dart' show profile, tokens;
import 'incomes_test.dart' show api, json, tap;

const firstWallet = '10000000-0000-4000-8000-000000000001';
const secondWallet = '10000000-0000-4000-8000-000000000002';
const originalId = '10000000-0000-4000-8000-000000000003';
const reversalId = '10000000-0000-4000-8000-000000000004';

Map<String, Object?> wallet(
  String id,
  String name,
  String type,
  String balance,
) => {
  'id': id,
  'name': name,
  'type': type,
  'currency': 'LKR',
  'opening_balance': balance,
  'current_balance': balance,
  'icon': 'wallet',
  'color': '#D4AF37',
  'is_active': true,
  'created_at': '2026-11-28T10:00:00Z',
  'updated_at': '2026-11-28T10:00:00Z',
};

Map<String, Object?> transfer({
  bool reversal = false,
  bool reversed = false,
  String amount = '2.02',
}) {
  final cash = wallet(firstWallet, 'Cash box', 'CASH', '10.00');
  final bank = wallet(secondWallet, 'Bank account', 'BANK', '2.00');
  return {
    'id': reversal ? reversalId : originalId,
    'amount': amount,
    'currency': 'LKR',
    'source_wallet': reversal ? bank : cash,
    'destination_wallet': reversal ? cash : bank,
    'transfer_date': '2024-02-29',
    'created_at': '2026-11-28T10:00:00Z',
    'status': reversal
        ? 'reversal'
        : reversed
        ? 'reversed'
        : 'original',
    'note': reversal ? 'Correction' : 'ATM withdrawal',
    'reversal_of_id': reversal ? originalId : null,
    'reversal_id': reversed ? reversalId : null,
  };
}

http.Response history(List<Map<String, Object?>> items, {int? next}) =>
    json({'items': items, 'next_offset': next});

void main() {
  testWidgets(
    'one active wallet offers Wallet Management without enabling transfers',
    (tester) async {
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/wallets')) {
          return history([wallet(firstWallet, 'Cash box', 'CASH', '10.00')]);
        }
        expect(request.method, 'GET');
        return history([]);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Wallet transfers'));
      await tap(tester, find.text('New transfer'));
      expect(
        find.text('Create at least two active wallets to record a transfer.'),
        findsOneWidget,
      );
      expect(find.text('Open wallets'), findsOneWidget);
      expect(find.text('Review transfer'), findsNothing);
    },
  );

  test(
    'transfer amounts, relationships and URL contracts stay exact',
    () async {
      final requests = <http.Request>[];
      final client = api((request) {
        requests.add(request);
        if (request.url.path.endsWith('/transfers') &&
            request.method == 'GET') {
          return history([
            transfer(reversed: true, amount: '9999999999999999.99'),
          ], next: 50);
        }
        return json(
          transfer(reversal: request.url.path.endsWith('/reverse')),
          201,
        );
      });
      final repository = TransferRepository(client, WalletRepository(client));
      final page = await repository.list('fixture', (
        search: 'ATM & 100%',
        wallet: firstWallet,
        kind: 'original',
        dates: (start: DateTime(2024, 2), end: DateTime(2024, 2, 29)),
      ), 0);
      expect(page.next, 50);
      expect(page.items.single.amount, BigInt.parse('999999999999999999'));
      expect(page.items.single.reversal, reversalId);
      expect(calendarDate(page.items.single.date), '2024-02-29');
      expect(
        TransferRecord.fromJson(transfer(reversal: true)).reversalOf,
        originalId,
      );
      expect(requests.first.url.queryParameters, {
        'q': 'ATM & 100%',
        'wallet_id': firstWallet,
        'kind': 'original',
        'date_from': '2024-02-01',
        'date_to': '2024-02-29',
        'offset': '0',
        'limit': '50',
      });
      expect(transferMinorUnits('2.2'), BigInt.from(220));
      expect(transferMinorUnits('0.00'), isNull);
      expect(transferMinorUnits('1.001'), isNull);
      final createKey = incomeOperationKey(), reverseKey = incomeOperationKey();
      expect(createKey, isNot(reverseKey));
      await repository.submit('fixture', (
        key: createKey,
        originalId: null,
        body: {'amount': '2.02'},
      ));
      await repository.submit('fixture', (
        key: reverseKey,
        originalId: originalId,
        body: {'note': 'Correction'},
      ));
      expect(requests[1].headers['idempotency-key'], createKey);
      expect(requests[2].headers['idempotency-key'], reverseKey);
      expect(requests[2].url.path, '/api/v1/transfers/$originalId/reverse');
      expect(jsonDecode(requests[2].body), {'note': 'Correction'});
      expect(requests[2].followRedirects, isFalse);
    },
  );

  test(
    'stale transfer history is discarded after filtering and account changes',
    () async {
      final old = Completer<http.Response>();
      final oldSession = Completer<http.Response>();
      var calls = 0;
      var account = 0;
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens('${++account}');
        if (path.endsWith('/logout')) return http.Response('', 204);
        if (path.endsWith('/me')) {
          return json({...jsonDecode(profile().body) as Map, 'id': '$account'});
        }
        return switch (++calls) {
          1 => old.future,
          3 => oldSession.future,
          _ => history([]),
        };
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await auth.login('first@example.com', 'fixture');
      final controller = TransferController(
        auth,
        TransferRepository(client, WalletRepository(client)),
      );
      addTearDown(controller.dispose);
      final pending = controller.reload();
      controller.apply((
        search: '',
        wallet: firstWallet,
        kind: 'reversal',
        dates: null,
      ));
      await Future<void>.delayed(Duration.zero);
      old.complete(history([transfer()]));
      await pending;
      expect(controller.items, isEmpty);
      final previousOwner = controller.reload();
      await auth.logout();
      await auth.login('other@example.com', 'fixture');
      oldSession.complete(history([transfer()]));
      await previousOwner;
      await Future<void>.delayed(Duration.zero);
      expect(controller.items, isEmpty);
      expect(controller.filters, emptyTransferFilters);
    },
  );

  testWidgets(
    'guarded transfer and reversal require confirmation and retry the same keys',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final creates = <String?>[];
      final reverses = <String?>[];
      var recorded = false, reversed = false;
      String cashBalance() => recorded && !reversed ? '7.98' : '10.00';
      String bankBalance() => recorded && !reversed ? '4.02' : '2.00';
      final client = api((request) {
        final path = request.url.path;
        if (path.endsWith('/login')) return tokens();
        if (path.endsWith('/me')) return profile();
        if (path.endsWith('/wallets/summary')) {
          return json({
            'currency': 'LKR',
            'total_active_balance': '12.00',
            'active_count': 2,
            'archived_count': 0,
            'balances_by_type': {
              'CASH': cashBalance(),
              'BANK': bankBalance(),
              'DIGITAL': '0.00',
            },
          });
        }
        if (path.endsWith('/wallets')) {
          return history([
            wallet(firstWallet, 'Cash box', 'CASH', cashBalance()),
            wallet(secondWallet, 'Bank account', 'BANK', bankBalance()),
          ]);
        }
        if (path.endsWith(firstWallet)) {
          return json(wallet(firstWallet, 'Cash box', 'CASH', cashBalance()));
        }
        if (path.endsWith(secondWallet)) {
          return json(
            wallet(secondWallet, 'Bank account', 'BANK', bankBalance()),
          );
        }
        if (path.endsWith('/reverse')) {
          reverses.add(request.headers['idempotency-key']);
          expect(jsonDecode(request.body), {'note': null});
          reversed = true;
          if (reverses.length == 1) {
            throw http.ClientException('Synthetic uncertain reversal');
          }
          return json(transfer(reversal: true), 201);
        }
        if (request.method == 'POST') {
          creates.add(request.headers['idempotency-key']);
          final body = jsonDecode(request.body);
          expect(body['amount'], '2.02');
          expect(body['source_wallet_id'], firstWallet);
          expect(body['destination_wallet_id'], secondWallet);
          recorded = true;
          if (creates.length == 1) {
            throw http.ClientException('Synthetic uncertain transfer');
          }
          return json(transfer(), 201);
        }
        if (path.endsWith(originalId)) {
          return json(transfer(reversed: reversed));
        }
        if (path.endsWith(reversalId)) return json(transfer(reversal: true));
        return history([
          if (recorded) transfer(reversed: reversed),
          if (reversed) transfer(reversal: true),
        ]);
      });
      final auth = AuthController(AuthRepository(client), MemorySessionStore());
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('Welcome back')))
          .go('/home/transfers');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Wallet transfers'));
      expect(find.text('No transfers match.'), findsOneWidget);
      await tap(tester, find.text('New transfer'));
      final amount = find.widgetWithText(TextFormField, 'Amount (LKR)');
      await tester.enterText(amount, '10.01');
      await tap(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Source wallet'),
      );
      await tap(tester, find.textContaining('Cash box').last);
      await tap(
        tester,
        find.widgetWithText(
          DropdownButtonFormField<String>,
          'Destination wallet',
        ),
      );
      await tap(tester, find.textContaining('Bank account').last);
      expect(find.textContaining('insufficient funds'), findsOneWidget);
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '2.02');
      await tester.pump();
      expect(find.text('Estimated source balance: LKR 7.98'), findsOneWidget);
      expect(
        find.text('Estimated destination balance: LKR 4.02'),
        findsOneWidget,
      );
      await tap(tester, find.text('Review transfer'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      expect(creates, isEmpty);
      await tap(tester, find.text('Review transfer'));
      await tap(tester, find.text('Confirm transfer'));
      expect(creates, hasLength(1));
      await tap(tester, find.text('Retry same operation'));
      expect(creates, [creates.first, creates.first]);
      expect(creates.first, isNotNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, find.text('From Cash box'));
      await tap(tester, find.text('Reverse transfer'));
      await tap(tester, find.text('Review reversal'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      expect(reverses, isEmpty);
      await tap(tester, find.text('Review reversal'));
      await tap(tester, find.text('Confirm reversal'));
      expect(reverses, hasLength(1));
      await tap(tester, find.text('Check transfer history'));
      await tap(tester, find.text('Review pending reversal'));
      await tap(tester, find.text('Retry same operation'));
      expect(reverses, [reverses.first, reverses.first]);
      expect(reverses.first, isNot(creates.first));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tap(tester, find.text('View reversal'));
      expect(find.text('Compensating reversal'), findsOneWidget);
      final router = GoRouter.of(tester.element(find.text('Transfer details')));
      router.go('/home/wallets');
      await tester.pumpAndSettle();
      expect(find.textContaining('LKR 10.00'), findsOneWidget);
      expect(find.textContaining('LKR 2.00'), findsOneWidget);
    },
  );
}

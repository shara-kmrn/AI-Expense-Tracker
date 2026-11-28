import 'dart:async';
import 'dart:convert';

import 'package:expense_tracker/app/app.dart';
import 'package:expense_tracker/core/network/api_client.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/data/auth_repository.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:expense_tracker/features/categories/data/category_repository.dart';
import 'package:expense_tracker/features/categories/presentation/categories_controller.dart';
import 'package:expense_tracker/features/categories/presentation/category_form.dart';
import 'package:expense_tracker/features/categories/presentation/category_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'auth_test.dart' show base, profile, tokens;

const customId = '10000000-0000-4000-8000-000000000001';
const defaultId = '10000000-0000-4000-8000-000000000002';

Map<String, Object> item(
  String name, {
  String id = customId,
  String type = 'EXPENSE',
  String icon = 'wallet',
  String color = '#D4AF37',
  bool system = false,
  bool active = true,
}) => {
  'name': name,
  'id': id,
  'type': type,
  'icon': icon,
  'color': color,
  'is_default': system,
  'is_active': active,
  'created_at': '2026-11-28T12:00:00Z',
  'updated_at': '2026-11-28T12:00:00Z',
};

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);
http.Response listing(List<Map<String, Object>> items, [int? next]) =>
    response({'items': items, 'next_offset': next});

ApiClient api(FutureOr<http.Response> Function(http.Request) handler) =>
    ApiClient(
      base,
      MockClient((request) async => handler(request)),
      allowLocalHttp: true,
    );

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<AuthController> signIn(ApiClient client) async {
  final auth = AuthController(AuthRepository(client), MemorySessionStore());
  await auth.login('test@example.com', 'fixture');
  return auth;
}

void main() {
  test('model parses safe types and input validation rejects controls', () {
    final parsed = CategoryRecord.fromJson(item('Café', icon: 'future-icon'));
    expect(parsed.type, CategoryType.expense);
    expect(parsed.createdAt.isUtc, isTrue);
    expect(parsed.icon, 'future-icon');
    expect(categoryColor('malformed'), categoryColor('#D4AF37'));
    expect(validateCategoryName('    '), isNotNull);
    expect(validateCategoryName('A\u202eB'), isNotNull);
    expect(validateCategoryName('𐐀' * 80), isNull);
    expect(validateCategoryName('𐐀' * 81), isNotNull);
  });

  test('repository builds trusted routes, encodes filters and excludes type on update', () async {
    final requests = <http.Request>[];
    final repository = CategoryRepository(
      api((request) {
        requests.add(request);
        if (request.method == 'GET') return listing([item('Study')], 50);
        return response(item('Updated'), request.method == 'POST' ? 201 : 200);
      }),
    );
    final page = await repository.list(
      'fixture',
      CategoryType.income,
      'Café & 100%',
      archived: true,
      offset: 10,
    );
    expect(page.nextOffset, 50);
    expect(requests.first.url.path, '/api/v1/categories');
    expect(requests.first.url.queryParameters, {
      'type': 'INCOME',
      'active': 'false',
      'q': 'Café & 100%',
      'limit': '50',
      'offset': '10',
    });
    const draft = CategoryDraft(
      'Updated',
      CategoryType.expense,
      'wallet',
      '#D4AF37',
    );
    await repository.save('fixture', draft);
    await repository.save('fixture', draft, id: customId);
    expect(jsonDecode(requests[1].body)['type'], 'EXPENSE');
    expect(jsonDecode(requests[2].body), {
      'name': 'Updated',
      'icon': 'wallet',
      'color': '#D4AF37',
    });
    expect(requests[2].headers['authorization'], 'Bearer fixture');
    expect(requests[2].followRedirects, isFalse);
    await expectLater(
      repository.get('fixture', 'https://other.example/'),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, hasLength(3));
  });

  test(
    'new filter wins and logout invalidates in-flight category lists',
    () async {
      final oldFilter = Completer<http.Response>();
      final oldSession = Completer<http.Response>();
      final started = Completer<void>();
      var categoryCalls = 0;
      var signedInAccounts = 0;
      final client = api((request) {
        if (request.url.path.endsWith('/login')) {
          return tokens('${++signedInAccounts}');
        }
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        if (request.url.path.endsWith('/users/me')) {
          final data = jsonDecode(profile().body) as Map<String, dynamic>;
          data['id'] = 'synthetic-user-$signedInAccounts';
          return response(data);
        }
        switch (++categoryCalls) {
          case 1:
            return oldFilter.future;
          case 2:
            return listing([item('Income result', type: 'INCOME')]);
          case 3:
            started.complete();
            return oldSession.future;
          default:
            expect(request.headers['authorization'], 'Bearer access-2');
            return listing([item('Second account', type: 'INCOME')]);
        }
      });
      final auth = await signIn(client);
      final controller = CategoriesController(auth, CategoryRepository(client));
      addTearDown(controller.dispose);
      final first = controller.reload();
      controller.setType(CategoryType.income);
      await Future<void>.delayed(Duration.zero);
      oldFilter.complete(listing([item('Stale expense')]));
      await first;
      expect(controller.items.single.name, 'Income result');
      final pending = controller.reload();
      await started.future;
      await auth.logout();
      expect(controller.items, isEmpty);
      await auth.login('other@example.com', 'fixture');
      oldSession.complete(listing([item('Stale prior session')]));
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.single.name, 'Second account');
    },
  );

  test(
    'a category read retries after renewal but a rejected write is sent once',
    () async {
      var reads = 0;
      var refreshes = 0;
      var writes = 0;
      final client = api((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/users/me')) return profile();
        if (request.url.path.endsWith('/refresh')) {
          refreshes++;
          return tokens('renewed');
        }
        if (request.method == 'POST') {
          writes++;
          expect(request.headers['authorization'], 'Bearer access-renewed');
          return http.Response('', 401);
        }
        if (++reads == 1) return http.Response('', 401);
        expect(request.headers['authorization'], 'Bearer access-renewed');
        return listing([item('Study')]);
      });
      final auth = await signIn(client);
      addTearDown(auth.dispose);
      final repository = CategoryRepository(client);
      final page = await auth.authenticatedRead(
        (access) =>
            repository.list(access, CategoryType.expense, '', archived: false),
      );
      expect(page.items.single.name, 'Study');
      const draft = CategoryDraft(
        'Study',
        CategoryType.expense,
        'wallet',
        '#D4AF37',
      );
      await expectLater(
        auth.authenticatedMutation((access) => repository.save(access, draft)),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 401),
        ),
      );
      expect(reads, 2);
      expect(refreshes, 1);
      expect(writes, 1);
      expect(auth.stage, AuthStage.signedOut);
    },
  );

  test(
    'uncertain archive refreshes the list without replaying its mutation',
    () async {
      var archives = 0;
      var reloads = 0;
      final client = api((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/users/me')) return profile();
        if (request.method == 'DELETE') {
          archives++;
          throw http.ClientException('fixture connection error');
        }
        reloads++;
        return listing([item('Study')]);
      });
      final auth = await signIn(client);
      final controller = CategoriesController(auth, CategoryRepository(client));
      addTearDown(controller.dispose);
      await controller.reload();
      await controller.setActive(controller.items.single, false);
      expect(archives, 1);
      expect(reloads, 2);
      expect(controller.notice, contains('could not be confirmed'));
    },
  );

  testWidgets(
    'protected navigation, filtering, search, and empty or error states',
    (tester) async {
      var fail = false;
      final client = api((request) {
        if (request.url.path.endsWith('/login')) return tokens();
        if (request.url.path.endsWith('/refresh')) return tokens();
        if (request.url.path.endsWith('/users/me')) return profile();
        if (fail) return http.Response('', 503);
        final q = request.url.queryParameters;
        if (q['q'] != null) return listing([]);
        return listing(
          q['type'] == 'INCOME'
              ? [item('Salary', id: defaultId, system: true, type: 'INCOME')]
              : [
                  item('Food & Dining', id: defaultId, system: true),
                  item('Study'),
                ],
        );
      });
      final store = MemorySessionStore();
      final auth = AuthController(AuthRepository(client), store);
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('Welcome back')))
          .go('/home/categories');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      await auth.login('test@example.com', 'fixture');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Categories'));
      expect(find.text('Food & Dining'), findsOneWidget);
      expect(find.byTooltip('Protected default'), findsOneWidget);
      expect(find.byTooltip('Actions for Food & Dining'), findsNothing);
      await tap(tester, find.text('Income'));
      expect(find.text('Salary'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('No custom categories match.'), findsOneWidget);
      fail = true;
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      fail = false;
      await tap(tester, find.text('Try again'));
      expect(find.text('Salary'), findsOneWidget);
    },
  );

  testWidgets(
    'form validates, permits icon and color selection and handles duplicates',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, Object>? custom;
      var submissions = 0;
      final client = api((request) {
        if (request.url.path.endsWith('/refresh')) return tokens();
        if (request.url.path.endsWith('/users/me')) return profile();
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'name': 'Study',
            'icon': 'graduation_cap',
            'color': '#A5F3FC',
            'type': 'EXPENSE',
          });
          if (++submissions == 1) return http.Response('', 409);
          custom = item('Study', icon: 'graduation_cap', color: '#A5F3FC');
          return response(custom!, 201);
        }
        return listing(custom == null ? [] : [custom!]);
      });
      final store = MemorySessionStore();
      await store.write('refresh-first');
      final auth = AuthController(AuthRepository(client), store);
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Categories'));
      await tap(tester, find.text('Add category'));
      await tap(tester, find.text('Save category'));
      expect(find.text('Enter a name of 1–80 characters.'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextFormField));
      await tester.enterText(find.byType(TextFormField), 'Study');
      await tap(tester, find.widgetWithText(ChoiceChip, 'Education'));
      expect(find.bySemanticsLabel('Education'), findsWidgets);
      await tap(tester, find.widgetWithText(ChoiceChip, 'Ice'));
      expect(find.bySemanticsLabel('Ice'), findsWidgets);
      await tap(tester, find.text('Save category'));
      expect(find.textContaining('already reserved'), findsOneWidget);
      await tap(tester, find.text('Save category'));
      expect(submissions, 2);
      expect(find.text('Study'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit and archive flows handle cancellation, failure, and restoration',
    (tester) async {
      var name = 'Study';
      var active = true;
      var archives = 0;
      final client = api((request) {
        if (request.url.path.endsWith('/refresh')) return tokens();
        if (request.url.path.endsWith('/users/me')) return profile();
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('type'), isFalse);
          name = body['name'] as String;
          return response(item(name, active: active));
        }
        if (request.method == 'DELETE') {
          if (++archives == 1) return http.Response('', 403);
          active = false;
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/restore')) {
          active = true;
          return response(item(name));
        }
        if (request.url.path.endsWith(customId)) {
          return response(item(name, active: active));
        }
        final query = request.url.queryParameters;
        return listing(
          (query['active'] == 'true') == active
              ? [item(name, active: active)]
              : [],
        );
      });
      final store = MemorySessionStore();
      await store.write('refresh-first');
      final auth = AuthController(AuthRepository(client), store);
      await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Categories'));
      await tap(tester, find.byTooltip('Actions for Study'));
      await tap(tester, find.text('Edit'));
      expect(find.text('Type: Expense'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'Campus');
      await tap(tester, find.text('Save changes'));
      expect(find.text('Campus'), findsOneWidget);
      expect(find.text('Category updated.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      Future<void> archiveDialog() async {
        await tap(tester, find.byTooltip('Actions for Campus'));
        await tap(tester, find.text('Archive'));
      }

      await archiveDialog();
      await tap(tester, find.text('Cancel'));
      expect(archives, 0);
      await archiveDialog();
      await tap(tester, find.text('Archive category'));
      expect(archives, 1);
      expect(find.text('Campus'), findsOneWidget);
      await archiveDialog();
      await tap(tester, find.text('Archive category'));
      expect(archives, 2);
      expect(find.text('Campus'), findsNothing);
      await tap(tester, find.text('Archived categories'));
      expect(find.text('Campus'), findsOneWidget);
      await tap(tester, find.text('Restore'));
      expect(find.text('Campus'), findsNothing);
      await tap(tester, find.text('Active categories'));
      expect(find.text('Campus'), findsOneWidget);
    },
  );
}

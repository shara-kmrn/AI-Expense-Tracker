import 'dart:async';

import 'package:expense_tracker/app/app.dart';
import 'package:expense_tracker/app/theme.dart';
import 'package:expense_tracker/core/storage/session_store.dart';
import 'package:expense_tracker/features/auth/presentation/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'auth_test.dart' show repo, profile, tokens;

Finder field(String label) => find.widgetWithText(TextFormField, label);
Finder action(String label) => find.widgetWithText(ElevatedButton, label);

Future<void> press(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('login validates, toggles passwords, and protects routes', (
    tester,
  ) async {
    final auth = AuthController(
      repo((_) => http.Response('', 401)),
      MemorySessionStore(),
    );
    await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.text('Welcome back')));
    router.go('/home/settings/delete');
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    await press(tester, action('Sign in'));
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    await tester.enterText(field('Email address'), 'test@example.com');
    await tester.enterText(field('Password'), 'example passphrase');
    expect(
      tester.widget<EditableText>(find.byType(EditableText).last).obscureText,
      isTrue,
    );
    await press(tester, find.byTooltip('Show password'));
    expect(
      tester.widget<EditableText>(find.byType(EditableText).last).obscureText,
      isFalse,
    );
    await press(tester, action('Sign in'));
    expect(find.text('Email or password is incorrect.'), findsOneWidget);
  });

  testWidgets('login disables repeated submissions and redirects home', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/login')) {
          calls++;
          return pending.future;
        }
        return profile();
      }),
      MemorySessionStore(),
    );
    await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
    await tester.pumpAndSettle();
    await tester.enterText(field('Email address'), 'test@example.com');
    await tester.enterText(field('Password'), 'example passphrase');
    await tester.tap(action('Sign in'));
    await tester.pump();
    final button = find.byType(ElevatedButton);
    expect(tester.widget<ElevatedButton>(button).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(button);
    expect(calls, 1);
    pending.complete(tokens());
    await tester.pumpAndSettle();
    expect(find.text('Welcome, Test User'), findsOneWidget);
    GoRouter.of(tester.element(find.text('Welcome, Test User'))).go('/login');
    await tester.pumpAndSettle();
    expect(find.text('Welcome, Test User'), findsOneWidget);
  });

  testWidgets('registration validates confirmation and returns to login', (
    tester,
  ) async {
    var calls = 0;
    final auth = AuthController(
      repo((request) {
        calls++;
        expect(request.url.path, endsWith('/register'));
        return http.Response('{}', 201);
      }),
      MemorySessionStore(),
    );
    await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
    await tester.pumpAndSettle();
    await press(tester, find.text('Create an account'));
    await tester.enterText(field('Full name'), 'Test User');
    await tester.enterText(field('Email address'), 'test@example.com');
    await tester.enterText(field('Password'), 'an example passphrase');
    await tester.enterText(field('Confirm password'), 'wrong');
    await press(tester, action('Create account'));
    expect(find.text('Passwords must match.'), findsOneWidget);
    expect(calls, 0);
    await tester.enterText(field('Confirm password'), 'an example passphrase');
    await press(tester, action('Create account'));
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Account created. Sign in to continue.'), findsOneWidget);
  });

  testWidgets('account deletion requires confirmation and handles rejection', (
    tester,
  ) async {
    var deletes = 0;
    final store = MemorySessionStore();
    await store.write('refresh-first');
    final auth = AuthController(
      repo((request) {
        if (request.url.path.endsWith('/refresh')) return tokens();
        if (request.method == 'DELETE') {
          return http.Response('', ++deletes == 1 ? 400 : 204);
        }
        return profile();
      }),
      store,
    );
    await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
    await tester.pumpAndSettle();
    await press(tester, find.text('My profile'));
    expect(find.text('test@example.com'), findsOneWidget);
    GoRouter.of(tester.element(find.text('test@example.com')))
        .go('/home/settings');
    await tester.pumpAndSettle();
    await press(tester, find.text('Delete account'));
    await tester.enterText(field('Current password'), 'fixture password');
    await press(tester, action('Delete account'));
    await press(tester, find.widgetWithText(TextButton, 'Cancel').last);
    expect(deletes, 0);
    await press(tester, action('Delete account'));
    await press(tester, find.text('Delete permanently'));
    expect(find.text('Your current password was incorrect.'), findsOneWidget);
    await press(tester, action('Delete account'));
    await press(tester, find.text('Delete permanently'));
    expect(deletes, 2);
    expect(await store.read(), isNull);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('small screen and increased text size keep login scrollable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 420);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final auth = AuthController(
      repo((_) => http.Response('', 401)),
      MemorySessionStore(),
    );
    await tester.pumpWidget(ExpenseTrackerApp(auth: auth));
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final button = action('Sign in');
    await tester.ensureVisible(button);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    expect(
      Theme.of(tester.element(button)).colorScheme.primary,
      AppColors.gold,
    );
    expect(tester.takeException(), isNull);
  });
}

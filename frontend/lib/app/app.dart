import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/app_widgets.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/auth/presentation/auth_forms.dart';
import '../features/profile/presentation/account_pages.dart';
import 'theme.dart';

class ExpenseTrackerApp extends StatefulWidget {
  const ExpenseTrackerApp({
    required this.auth,
    this.canDelete = kDebugMode,
    super.key,
  });
  final AuthController auth;
  final bool canDelete;

  @override
  State<ExpenseTrackerApp> createState() => _ExpenseTrackerAppState();
}

class _ExpenseTrackerAppState extends State<ExpenseTrackerApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final auth = widget.auth;
    GoRoute form(String path, FormAction action) => GoRoute(
      path: path,
      builder: (_, _) => ListenableBuilder(
        listenable: auth,
        builder: (_, _) => AccountForm(action, auth),
      ),
    );
    _router = GoRouter(
      refreshListenable: auth,
      redirect: (_, state) {
        final path = state.uri.path;
        final private = path == '/home' || path.startsWith('/home/');
        if (auth.stage == AuthStage.starting ||
            auth.stage == AuthStage.retryStartup) {
          return path == '/' ? null : '/';
        }
        if (auth.stage == AuthStage.signedOut && (path == '/' || private)) {
          return '/login';
        }
        if (auth.stage == AuthStage.signedIn && !private) return '/home';
        if (!widget.canDelete && path == '/home/settings/delete') {
          return '/home/settings';
        }
        return null;
      },
      routes: [
        GoRoute(path: '/', builder: (_, _) => _Splash(auth)),
        form('/login', FormAction.login),
        form('/register', FormAction.register),
        form('/forgot', FormAction.forgot),
        form('/reset', FormAction.reset),
        GoRoute(
          path: '/home',
          builder: (_, _) => HomePage(auth),
          routes: [
            GoRoute(
              path: 'profile',
              builder: (_, _) => ProfilePage(auth),
              routes: [form('edit', FormAction.edit)],
            ),
            GoRoute(
              path: 'settings',
              builder: (_, _) =>
                  SettingsPage(auth, canDelete: widget.canDelete),
              routes: [
                form('password', FormAction.change),
                form('delete', FormAction.delete),
              ],
            ),
          ],
        ),
      ],
      errorBuilder: (context, _) => AuthScreenLayout(
        child: AppSecondaryButton(
          'Return to the app',
          onPressed: () => context.go('/'),
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) auth.initialize();
    });
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'AI Expense Tracker',
    theme: darkTheme(),
    darkTheme: darkTheme(),
    themeMode: ThemeMode.dark,
    debugShowCheckedModeBanner: false,
    routerConfig: _router,
  );
}

class _Splash extends StatelessWidget {
  const _Splash(this.auth);
  final AuthController auth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: auth,
    builder: (context, _) => AuthScreenLayout(
      midnight: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(),
          const SizedBox(height: AppSpacing.lg),
          if (auth.stage == AuthStage.retryStartup) ...[
            AppErrorMessage(auth.notice ?? 'Could not restore your session.'),
            const SizedBox(height: AppSpacing.md),
            AppPrimaryButton('Try again', onPressed: auth.initialize),
            const SizedBox(height: AppSpacing.sm),
            AppSecondaryButton('Go to sign in', onPressed: auth.logout),
          ] else
            const AppLoadingIndicator(),
        ],
      ),
    ),
  );
}

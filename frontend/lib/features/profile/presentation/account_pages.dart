import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';

class HomePage extends StatelessWidget {
  const HomePage(this.auth, {super.key});
  final AuthController auth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: auth,
    builder: (context, _) => AuthScreenLayout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppLogo(),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(
            'Welcome, ${auth.user?.fullName ?? ''}',
            'Manage your profile and account security.',
          ),
          const SizedBox(height: AppSpacing.lg),
          const AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.insights_outlined),
                SizedBox(height: AppSpacing.sm),
                Text('Financial workspace', style: AppTypography.section),
                SizedBox(height: AppSpacing.xs),
                Text(
                  'Expense tracking and budgets are coming later.',
                  style: TextStyle(color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppPrimaryButton(
            'Wallets',
            onPressed: () => context.push('/home/wallets'),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppPrimaryButton(
            'Income',
            onPressed: () => context.push('/home/income'),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppPrimaryButton(
            'Expenses',
            onPressed: () => context.push('/home/expenses'),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppPrimaryButton(
            'Wallet transfers',
            onPressed: () => context.push('/home/transfers'),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppPrimaryButton(
            'Categories',
            onPressed: () => context.push('/home/categories'),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppPrimaryButton(
            'My profile',
            onPressed: () => context.push('/home/profile'),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            'Account settings',
            onPressed: () => context.push('/home/settings'),
          ),
        ],
      ),
    ),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage(this.auth, {super.key});
  final AuthController auth;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.auth.loadProfile();
    } on ApiFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your profile.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) {
      final user = widget.auth.user;
      return AuthScreenLayout(
        title: 'My profile',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppSectionHeader(
              'My profile',
              'Your personal account information.',
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_error != null) ...[
              AppErrorMessage(_error!),
              AppSecondaryButton('Try again', onPressed: _load),
            ],
            if (_loading)
              const LinearProgressIndicator(semanticsLabel: 'Loading profile'),
            if (user != null) ...[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const CircleAvatar(
                      backgroundColor: AppColors.selected,
                      foregroundColor: AppColors.champagne,
                      child: Icon(Icons.person_outline),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(user.fullName, style: AppTypography.section),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      user.email,
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppPrimaryButton(
                'Edit profile',
                onPressed: _loading
                    ? null
                    : () => context.push('/home/profile/edit'),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage(this.auth, {required this.canDelete, super.key});
  final AuthController auth;
  final bool canDelete;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;

  Future<void> _logout() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final accepted = await confirmAction(
        context,
        title: 'Sign out?',
        description: 'You will need to sign in again on this device.',
        action: 'Sign out',
      );
      if (accepted && mounted) await widget.auth.logout();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tile(
    String title,
    IconData icon,
    VoidCallback action, {
    bool destructive = false,
  }) {
    final color = destructive ? AppColors.error : AppColors.champagne;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      textColor: destructive ? color : AppColors.text,
      trailing: const Icon(Icons.chevron_right),
      onTap: _busy ? null : action,
    );
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: 'Account settings',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(
          'Account settings',
          'Manage your profile, password, and sign-in session.',
        ),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: Column(
            children: [
              _tile(
                'My profile',
                Icons.person_outline,
                () => context.push('/home/profile'),
              ),
              _tile(
                'Change password',
                Icons.lock_outline,
                () => context.push('/home/settings/password'),
              ),
              _tile('Sign out', Icons.logout, _logout),
              if (widget.canDelete)
                _tile(
                  'Delete account',
                  Icons.delete_outline,
                  () => context.push('/home/settings/delete'),
                  destructive: true,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

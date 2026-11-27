import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import 'auth_controller.dart';

enum FormAction {
  login(
    'Welcome back',
    'Sign in to your private finance workspace.',
    'Sign in',
  ),
  register(
    'Create your account',
    'Set up a private space for your finances.',
    'Create account',
  ),
  forgot(
    'Forgot password?',
    'Request a recovery code. Codes expire after 15 minutes.',
    'Send recovery code',
  ),
  reset(
    'Reset your password',
    'Paste the recovery code from your email.',
    'Reset password',
  ),
  edit(
    'Edit profile',
    'Update the name shown on your account.',
    'Save changes',
  ),
  change(
    'Change password',
    'Changing your password signs you out of all sessions.',
    'Change password',
  ),
  delete(
    'Delete account',
    'This permanently deletes your account and its authentication records.',
    'Delete account',
  );

  const FormAction(this.heading, this.description, this.action);
  final String heading;
  final String description;
  final String action;

  bool get public => index <= reset.index;
}

enum FieldKind {
  name('Full name'),
  email('Email address'),
  password('Password'),
  current('Current password'),
  next('New password'),
  confirm('Confirm password'),
  code('Recovery code');

  const FieldKind(this.label);
  final String label;
  bool get concealed => const {password, current, next, confirm}.contains(this);
}

const _fields = <FormAction, List<FieldKind>>{
  FormAction.login: [FieldKind.email, FieldKind.password],
  FormAction.register: [
    FieldKind.name,
    FieldKind.email,
    FieldKind.password,
    FieldKind.confirm,
  ],
  FormAction.forgot: [FieldKind.email],
  FormAction.reset: [FieldKind.code, FieldKind.next, FieldKind.confirm],
  FormAction.edit: [FieldKind.name],
  FormAction.change: [FieldKind.current, FieldKind.next, FieldKind.confirm],
  FormAction.delete: [FieldKind.current],
};

String? validateEmail(String input) {
  final email = input.trim();
  final parts = email.split('@');
  if (utf8.encode(email).length > 254 ||
      parts.length != 2 ||
      parts.first.isEmpty ||
      !RegExp(
        r'^[^\s@.]+(?:\.[^\s@.]+)+$',
        unicode: true,
      ).hasMatch(parts.last) ||
      RegExp(r'\s', unicode: true).hasMatch(parts.first) ||
      parts.first.startsWith('.') ||
      parts.first.endsWith('.') ||
      parts.first.contains('..')) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? validatePassword(String password, {required bool isNew}) {
  final length = password.runes.length;
  if (isNew && (length < 15 || length > 128)) return 'Use 15–128 characters.';
  if (length == 0) return 'Enter your password.';
  if (length > 128) return 'Use at most 128 characters.';
  return null;
}

class AccountForm extends StatefulWidget {
  const AccountForm(this.action, this.auth, {super.key});
  final FormAction action;
  final AuthController auth;

  @override
  State<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<AccountForm> {
  final _form = GlobalKey<FormState>();
  late final Map<FieldKind, TextEditingController> _controllers;
  bool _busy = false;
  bool _confirming = false;
  String? _message;
  bool _information = false;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final field in _fields[widget.action]!)
        field: TextEditingController(
          text: widget.action == FormAction.edit
              ? widget.auth.user?.fullName
              : null,
        ),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String value(FieldKind field) => _controllers[field]!.text;

  String? _validate(FieldKind field, String? input) {
    final text = input ?? '';
    return switch (field) {
      FieldKind.name =>
        text.trim().isEmpty ||
                text.trim().runes.length > 120 ||
                text.contains('\u0000')
            ? 'Enter a name between 1 and 120 characters.'
            : null,
      FieldKind.email => validateEmail(text),
      FieldKind.password => validatePassword(
        text,
        isNew: widget.action == FormAction.register,
      ),
      FieldKind.current => validatePassword(text, isNew: false),
      FieldKind.next => validatePassword(text, isNew: true),
      FieldKind.confirm =>
        text !=
                value(
                  widget.action == FormAction.register
                      ? FieldKind.password
                      : FieldKind.next,
                )
            ? 'Passwords must match.'
            : null,
      FieldKind.code =>
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text.trim())
            ? 'Paste the 43-character code from your email.'
            : null,
    };
  }

  Future<void> _submit() async {
    if (_busy || _confirming || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    if (widget.action == FormAction.delete) {
      _confirming = true;
      final accepted = await confirmAction(
        context,
        title: 'Delete this account?',
        description: 'This is permanent. You will be signed out and your account will be removed.',
        action: 'Delete permanently',
        destructive: true,
      );
      _confirming = false;
      if (!accepted || !mounted) return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _information = false;
    });
    final auth = widget.auth;
    try {
      switch (widget.action) {
        case FormAction.login:
          await auth.login(
            value(FieldKind.email).trim(),
            value(FieldKind.password),
          );
        case FormAction.register:
          await auth.repository.register(
            value(FieldKind.name).trim(),
            value(FieldKind.email).trim(),
            value(FieldKind.password),
          );
          if (!mounted) return;
          auth.message('Account created. Sign in to continue.');
          context.go('/login');
        case FormAction.forgot:
          await auth.repository.forgot(value(FieldKind.email).trim());
          if (!mounted) return;
          setState(() {
            _message =
                'If the account is eligible, a recovery email will be sent.';
            _information = true;
          });
        case FormAction.reset:
          await auth.repository.reset(
            value(FieldKind.code).trim(),
            value(FieldKind.next),
          );
          if (!mounted) return;
          auth.message(
            'Password reset. Previous sessions were revoked. Sign in again.',
          );
          context.go('/login');
        case FormAction.edit:
          await auth.editProfile(value(FieldKind.name).trim());
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Profile updated.')));
          context.pop();
        case FormAction.change:
          await auth.changePassword(
            value(FieldKind.current),
            value(FieldKind.next),
          );
        case FormAction.delete:
          await auth.deleteAccount(value(FieldKind.current));
      }
    } on ApiFailure catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not complete the request.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(FieldKind field) {
    if (field.concealed) {
      return AppPasswordField(
        label:
            field == FieldKind.confirm && widget.action != FormAction.register
            ? 'Confirm new password'
            : field.label,
        controller: _controllers[field]!,
        validator: (text) => _validate(field, text),
        enabled: !_busy,
      );
    }
    return AppTextField(
      label: field.label,
      controller: _controllers[field]!,
      validator: (text) => _validate(field, text),
      enabled: !_busy,
      keyboardType: field == FieldKind.email
          ? TextInputType.emailAddress
          : TextInputType.text,
      autofillHints: field == FieldKind.email
          ? const [AutofillHints.email]
          : field == FieldKind.name
          ? const [AutofillHints.name]
          : null,
      sensitive: field == FieldKind.code,
    );
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final notice = action == FormAction.login ? widget.auth.notice : null;
    return AuthScreenLayout(
      title: action.public ? null : action.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(),
          const SizedBox(height: AppSpacing.xl),
          AppSectionHeader(action.heading, action.description),
          const SizedBox(height: AppSpacing.lg),
          if (_message != null || notice != null) ...[
            AppErrorMessage(
              _message ?? notice!,
              information: _message == null || _information,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final field in _fields[action]!) ...[
                  _field(field),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (const {
                  FormAction.register,
                  FormAction.reset,
                  FormAction.change,
                }.contains(action))
                  const Padding(
                    padding: EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      'Use 15–128 characters. Spaces and Unicode are allowed.',
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ),
                if (action == FormAction.login)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _busy ? null : () => context.push('/forgot'),
                      child: const Text('Forgot password?'),
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                AppPrimaryButton(
                  action.action,
                  onPressed: _submit,
                  busy: _busy,
                  destructive: action == FormAction.delete,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (action == FormAction.login)
            AppSecondaryButton(
              'Create an account',
              onPressed: _busy ? null : () => context.push('/register'),
            ),
          if (action == FormAction.forgot)
            AppSecondaryButton(
              'I have a recovery code',
              onPressed: _busy ? null : () => context.push('/reset'),
            ),
          if (action.public && action != FormAction.login)
            TextButton(
              onPressed: _busy ? null : () => context.go('/login'),
              child: const Text('Back to sign in'),
            ),
          if (action == FormAction.delete)
            TextButton(
              onPressed: _busy ? null : () => context.pop(),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }
}

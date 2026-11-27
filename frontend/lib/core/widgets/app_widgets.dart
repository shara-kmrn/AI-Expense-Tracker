import 'package:flutter/material.dart';

import '../../app/theme.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'AI Expense Tracker',
    child: ExcludeSemantics(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.selected,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: AppColors.gold.withValues(alpha: .5)),
            ),
            child: const Icon(
              Icons.account_balance_wallet_outlined,
              color: AppColors.champagne,
            ),
          ),
          Text(
            'AI Expense Tracker',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    ),
  );
}

class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader(this.title, this.description, {super.key});
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.headlineLarge),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(description, style: const TextStyle(color: AppColors.muted)),
    ],
  );
}

class AppCard extends StatelessWidget {
  const AppCard({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(AppSpacing.lg), child: child),
  );
}

class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton(
    this.label, {
    this.onPressed,
    this.busy = false,
    this.destructive = false,
    super.key,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool destructive;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      style: destructive
          ? ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.midnight,
            )
          : null,
      onPressed: busy ? null : onPressed,
      child: busy
          ? const AppLoadingIndicator()
          : Text(label, textAlign: TextAlign.center),
    ),
  );
}

class AppSecondaryButton extends StatelessWidget {
  const AppSecondaryButton(this.label, {this.onPressed, super.key});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) =>
      OutlinedButton(onPressed: onPressed, child: Text(label));
}

class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Loading'),
  );
}

class AppErrorMessage extends StatelessWidget {
  const AppErrorMessage(this.message, {this.information = false, super.key});
  final String message;
  final bool information;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.elevated,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            information ? Icons.info_outline : Icons.error_outline,
            color: information ? AppColors.champagne : AppColors.error,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
}

class AuthScreenLayout extends StatelessWidget {
  const AuthScreenLayout({
    required this.child,
    this.title,
    this.midnight = false,
    super.key,
  });
  final Widget child;
  final String? title;
  final bool midnight;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: midnight ? AppColors.midnight : null,
    appBar: title == null ? null : AppBar(title: Text(title!)),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, size) => SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (size.maxHeight - 2 * AppSpacing.lg).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    required this.label,
    required this.controller,
    this.validator,
    this.keyboardType,
    this.autofillHints,
    this.enabled = true,
    this.sensitive = false,
    super.key,
  });
  final String label;
  final TextEditingController controller;
  final FormFieldValidator<String>? validator;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final bool enabled;
  final bool sensitive;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    validator: validator,
    keyboardType: keyboardType,
    autofillHints: autofillHints,
    autocorrect: !sensitive,
    enableSuggestions: !sensitive,
    enableIMEPersonalizedLearning: !sensitive,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(labelText: label),
  );
}

class AppPasswordField extends StatefulWidget {
  const AppPasswordField({
    required this.label,
    required this.controller,
    required this.validator,
    required this.enabled,
    super.key,
  });
  final String label;
  final TextEditingController controller;
  final FormFieldValidator<String> validator;
  final bool enabled;

  @override
  State<AppPasswordField> createState() => _AppPasswordFieldState();
}

class _AppPasswordFieldState extends State<AppPasswordField> {
  bool visible = false;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    enabled: widget.enabled,
    validator: widget.validator,
    obscureText: !visible,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    keyboardType: TextInputType.visiblePassword,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: visible ? 'Hide password' : 'Show password',
        onPressed: widget.enabled
            ? () => setState(() => visible = !visible)
            : null,
        icon: Icon(
          visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String description,
  required String action,
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: destructive
                ? TextButton.styleFrom(foregroundColor: AppColors.error)
                : null,
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

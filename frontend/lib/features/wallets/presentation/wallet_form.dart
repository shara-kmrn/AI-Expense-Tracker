import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../categories/presentation/category_form.dart'
    show validateCategoryName;
import '../../categories/presentation/category_style.dart';
import '../data/wallet_repository.dart';
import 'wallet_pages.dart' show walletError;

class EditWalletPage extends StatefulWidget {
  const EditWalletPage(this.auth, this.repository, this.id, {super.key});
  final AuthController auth;
  final WalletRepository repository;
  final String id;

  @override
  State<EditWalletPage> createState() => _EditWalletPageState();
}

class _EditWalletPageState extends State<EditWalletPage> {
  late Future<WalletRecord> _wallet = _load();

  Future<WalletRecord> _load() => widget.auth.authenticatedRead(
    (access) => widget.repository.get(access, widget.id),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<WalletRecord>(
    future: _wallet,
    builder: (context, snapshot) {
      final wallet = snapshot.data;
      if (snapshot.connectionState == ConnectionState.done &&
          wallet != null &&
          wallet.active) {
        return WalletForm(widget.auth, widget.repository, wallet: wallet);
      }
      return AuthScreenLayout(
        title: 'Edit wallet',
        child: snapshot.connectionState != ConnectionState.done
            ? const AppLoadingIndicator()
            : Column(
                children: [
                  AppErrorMessage(
                    wallet == null
                        ? walletError(snapshot.error)
                        : 'Restore this wallet before editing.',
                  ),
                  if (wallet == null)
                    AppSecondaryButton(
                      'Try again',
                      onPressed: () {
                        final wallet = _load();
                        setState(() {
                          _wallet = wallet;
                        });
                      },
                    ),
                ],
              ),
      );
    },
  );
}

class WalletForm extends StatefulWidget {
  const WalletForm(this.auth, this.repository, {this.wallet, super.key});
  final AuthController auth;
  final WalletRepository repository;
  final WalletRecord? wallet;

  @override
  State<WalletForm> createState() => _WalletFormState();
}

class _WalletFormState extends State<WalletForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.wallet?.name);
  final _amount = TextEditingController(text: '0.00');
  late WalletType _type = widget.wallet?.type ?? WalletType.cash;
  late String _icon = widget.wallet?.icon ?? 'wallet';
  late String _color = widget.wallet?.color ?? '#D4AF37';
  bool _busy = false;
  bool _uncertain = false;
  String? _error;

  Future<void> _save() async {
    if (_busy || _uncertain || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = (
        name: _name.text.trim(),
        type: _type,
        amount: _amount.text,
        icon: _icon,
        color: _color,
      );
      await widget.auth.authenticatedMutation(
        (access) =>
            widget.repository.save(access, draft, id: widget.wallet?.id),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.wallet == null ? 'Wallet created.' : 'Wallet updated.',
          ),
        ),
      );
      context.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uncertain = error is ApiFailure && error.uncertain;
        _error = _uncertain
            ? 'The result could not be confirmed. Check the refreshed wallets before trying again.'
            : walletError(error);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wallet = widget.wallet;
    final enabled = !_busy && !_uncertain;
    return PopScope(
      canPop: !_busy,
      child: AuthScreenLayout(
        title: wallet == null ? 'Add wallet' : 'Edit wallet',
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                label: 'Wallet name',
                controller: _name,
                enabled: enabled,
                validator: validateCategoryName,
              ),
              const SizedBox(height: AppSpacing.md),
              if (wallet == null) ...[
                Wrap(
                  spacing: AppSpacing.xs,
                  children: [
                    for (final type in WalletType.values)
                      ChoiceChip(
                        label: Text(type.label),
                        selected: _type == type,
                        onSelected: enabled
                            ? (_) => setState(() => _type = type)
                            : null,
                      ),
                  ],
                ),
                const Text('Currency: LKR'),
                AppTextField(
                  label: 'Opening balance',
                  controller: _amount,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (value) =>
                      validOpeningBalance(value ?? '') ? null : 'Enter zero or a positive amount with up to 16 digits and two decimal places.',
                ),
                const Text(
                  'The opening balance is set when you create the wallet.',
                ),
              ] else ...[
                Text('Type: ${wallet.type.label}'),
                const Text('Currency: LKR'),
                Text('Opening balance: ${walletMoney(wallet.opening)}'),
                Text('Current balance: ${walletMoney(wallet.current)}'),
              ],
              const SizedBox(height: AppSpacing.lg),
              Text('Icon', style: Theme.of(context).textTheme.titleLarge),
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  for (final entry in categoryIcons.entries)
                    ChoiceChip(
                      label: Text(entry.value.$1),
                      avatar: Icon(entry.value.$2, size: 18),
                      selected: _icon == entry.key,
                      onSelected: enabled
                          ? (_) => setState(() => _icon = entry.key)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Color', style: Theme.of(context).textTheme.titleLarge),
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  for (final entry in categoryColors.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      avatar: CircleAvatar(
                        backgroundColor: categoryColor(entry.key),
                      ),
                      selected: _color == entry.key,
                      onSelected: enabled
                          ? (_) => setState(() => _color = entry.key)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _name,
                builder: (_, name, _) => Card(
                  child: ListTile(
                    leading: CategoryBadge(_icon, _color),
                    title: Text(
                      name.text.trim().isEmpty
                          ? 'Wallet preview'
                          : name.text.trim(),
                    ),
                    subtitle: Text('${_type.label} · LKR'),
                  ),
                ),
              ),
              if (_error case final error?) AppErrorMessage(error),
              if (_uncertain)
                AppSecondaryButton(
                  'Check refreshed wallets',
                  onPressed: () => context.pop(),
                )
              else
                AppPrimaryButton(
                  wallet == null ? 'Create wallet' : 'Save changes',
                  busy: _busy,
                  onPressed: _save,
                ),
              TextButton(
                onPressed: _busy ? null : () => context.pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

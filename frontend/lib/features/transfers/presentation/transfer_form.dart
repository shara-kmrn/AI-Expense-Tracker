import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../incomes/data/income_repository.dart'
    show calendarDate, colomboToday, incomeOperationKey, validIncomeAmount;
import '../../wallets/data/wallet_repository.dart';
import '../data/transfer_repository.dart';
import 'transfer_controller.dart';

final _maxMinor = BigInt.parse('999999999999999999');

BigInt? transferMinorUnits(String input) {
  if (!validIncomeAmount(input)) return null;
  final parts = input.split('.');
  return BigInt.parse(
    parts.first + (parts.length == 2 ? parts.last.padRight(2, '0') : '00'),
  );
}

String _decimalAmount(BigInt minor) {
  final digits = minor.toString().padLeft(3, '0');
  return '${digits.substring(0, digits.length - 2)}.${digits.substring(digits.length - 2)}';
}

class TransferEditor extends StatefulWidget {
  const TransferEditor(
    this.auth,
    this.repository, {
    this.originalId,
    super.key,
  });
  final AuthController auth;
  final TransferRepository repository;
  final String? originalId;

  @override
  State<TransferEditor> createState() => _TransferEditorState();
}

class _TransferEditorState extends State<TransferEditor> {
  late final PendingTransfer? _initial = widget.originalId == null
      ? widget.repository.pendingCreation
      : widget.repository.pendingReversals[widget.originalId];
  late PendingTransfer? _pending = _initial;
  late bool _uncertain = _initial != null;
  late final _amount = TextEditingController(
    text: _initial?.body['amount'] as String?,
  );
  late final _note = TextEditingController(
    text: _initial?.body['note'] as String?,
  );
  late String? _sourceId = _initial?.body['source_wallet_id'] as String?;
  late String? _destinationId =
      _initial?.body['destination_wallet_id'] as String?;
  late DateTime _date =
      DateTime.tryParse(_initial?.body['transfer_date'] as String? ?? '') ??
      colomboToday();
  late Future<(List<WalletRecord>, TransferRecord?)> _choices = _load();
  final _form = GlobalKey<FormState>();
  bool _reviewing = false;
  bool _sending = false;
  late String? _error = _initial == null
      ? null
      : 'A previous submission is unresolved.';

  Future<(List<WalletRecord>, TransferRecord?)> _load() async {
    final id = widget.originalId;
    if (id == null) {
      return (await widget.repository.walletOptions(widget.auth), null);
    }
    final record = await widget.auth.authenticatedRead(
      (access) => widget.repository.get(access, id),
    );
    final (source, destination) = await (
      widget.auth.authenticatedRead(
        (access) =>
            widget.repository.wallets.get(access, record.destination.id),
      ),
      widget.auth.authenticatedRead(
        (access) => widget.repository.wallets.get(access, record.source.id),
      ),
    ).wait;
    return ([source, destination], record);
  }

  void _refresh() {
    final future = _load();
    setState(() {
      _choices = future;
    });
  }

  void _remember(PendingTransfer? value) {
    final id = widget.originalId;
    if (id == null) {
      widget.repository.pendingCreation = value;
    } else if (value == null) {
      widget.repository.pendingReversals.remove(id);
    } else {
      widget.repository.pendingReversals[id] = value;
    }
  }

  String? _balanceError(
    WalletRecord source,
    WalletRecord destination,
    BigInt amount,
  ) {
    if (source.id == destination.id) return 'Select two different wallets.';
    if (!source.active || !destination.active) {
      return 'Restore both wallets before making this movement.';
    }
    if (source.current < amount) {
      return 'The sending wallet has insufficient funds.';
    }
    if (destination.current + amount > _maxMinor) {
      return 'The receiving wallet would exceed its balance limit.';
    }
    return null;
  }

  Future<void> _review(
    WalletRecord? source,
    WalletRecord? destination,
    TransferRecord? original,
  ) async {
    if (_reviewing ||
        _sending ||
        _uncertain ||
        !_form.currentState!.validate()) {
      return;
    }
    final amount = original?.amount ?? transferMinorUnits(_amount.text);
    if (source == null || destination == null || amount == null) return;
    final failure = _balanceError(source, destination, amount);
    if (failure != null) {
      setState(() => _error = failure);
      return;
    }
    final note = _note.text.trim();
    FocusScope.of(context).unfocus();
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          original == null ? 'Review transfer' : 'Reverse this transfer?',
        ),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('From ${source.name} to ${destination.name}'),
            Text(walletMoney(amount)),
            Text(
              'Date: ${calendarDate(original == null ? _date : colomboToday())}',
            ),
            Text(
              'Estimated source balance: ${walletMoney(source.current - amount)}',
            ),
            Text(
              'Estimated destination balance: ${walletMoney(destination.current + amount)}',
            ),
            if (note.isNotEmpty) Text('Note: $note'),
            const SizedBox(height: AppSpacing.sm),
            Text(
              original == null
                  ? 'This records a movement inside your tracked wallets. It does not initiate a bank transaction.'
                  : 'This compensating movement returns the original amount. The original record stays in history.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(
              original == null ? 'Confirm transfer' : 'Confirm reversal',
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _reviewing = false);
    if (confirmed != true) return;
    final operation = (
      key: incomeOperationKey(),
      originalId: original?.id,
      body: <String, Object?>{
        'note': note.isEmpty ? null : note,
        if (original == null) ...{
          'source_wallet_id': source.id,
          'destination_wallet_id': destination.id,
          'currency': 'LKR',
          'amount': _decimalAmount(amount),
          'transfer_date': calendarDate(_date),
        },
      },
    );
    await _submit(operation);
  }

  Future<void> _submit(PendingTransfer operation) async {
    if (_sending) return;
    final owner = widget.auth.user?.id;
    if (owner == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.auth.authenticatedMutation(
        (access) => widget.repository.submit(access, operation),
      );
      if (!mounted || owner != widget.auth.user?.id) return;
      _remember(null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            operation.originalId == null
                ? 'Transfer recorded.'
                : 'Reversal recorded.',
          ),
        ),
      );
      context.pop();
    } catch (failure) {
      if (!mounted || owner != widget.auth.user?.id) return;
      final apiFailure = failure is ApiFailure ? failure : null;
      setState(() {
        _uncertain = _uncertain || apiFailure?.uncertain == true;
        if (_uncertain) {
          _pending = operation;
          _remember(operation);
        }
        _error = apiFailure?.uncertain == true
            ? 'The result is uncertain. Check transfer history or retry this same operation.'
            : transferError(failure);
      });
      if (!_uncertain &&
          (apiFailure?.status == 409 || apiFailure?.status == 404)) {
        _refresh();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _resolve() async {
    final confirmed = await confirmAction(
      context,
      title: 'Resolve the pending operation?',
      description: 'Confirm that you reviewed authoritative transfer history or the linked reversal. If you are unsure, retry the same operation.',
      action: 'Confirm reviewed',
    );
    if (!confirmed || !mounted) return;
    _remember(null);
    context.pop();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending && !_reviewing && !_uncertain,
    child: AuthScreenLayout(
      title: widget.originalId == null ? 'New transfer' : 'Reverse transfer',
      child: FutureBuilder(
        future: _choices,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const AppLoadingIndicator();
          }
          final data = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error case final error?) AppErrorMessage(error),
              if (_uncertain) ...[
                if (_pending case final pending?)
                  AppPrimaryButton(
                    'Retry same operation',
                    busy: _sending,
                    onPressed: () => _submit(pending),
                  ),
                AppSecondaryButton(
                  'Check transfer history',
                  onPressed: _sending ? null : () => context.pop(),
                ),
                if (_initial != null)
                  AppSecondaryButton(
                    'Resolve after reviewing history',
                    onPressed: _sending ? null : _resolve,
                  ),
              ] else if (data == null) ...[
                AppErrorMessage(transferError(snapshot.error)),
                AppSecondaryButton('Try again', onPressed: _refresh),
              ] else
                _formFields(data.$1, data.$2),
            ],
          );
        },
      ),
    ),
  );

  Widget _formFields(List<WalletRecord> wallets, TransferRecord? original) {
    final enabled = !_sending && !_reviewing;
    final source = wallets
        .where((wallet) => wallet.id == (original?.destination.id ?? _sourceId))
        .firstOrNull;
    final destination = wallets
        .where((wallet) => wallet.id == (original?.source.id ?? _destinationId))
        .firstOrNull;
    final eligible = original == null
        ? wallets.length >= 2
        : original.status == TransferStatus.original;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!eligible) ...[
            AppErrorMessage(
              original == null
                  ? 'Create at least two active wallets to record a transfer.'
                  : 'Only an original transfer that has not been reversed is eligible.',
            ),
            if (original == null)
              AppSecondaryButton(
                'Open wallets',
                onPressed: () async {
                  await context.push('/home/wallets');
                  if (mounted) _refresh();
                },
              ),
          ],
          const Text('Currency: LKR'),
          const SizedBox(height: AppSpacing.sm),
          if (original == null) ...[
            AppTextField(
              label: 'Amount (LKR)',
              controller: _amount,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (value) => transferMinorUnits(value ?? '') == null
                  ? 'Enter a positive LKR amount.'
                  : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            _selector(
              'Source wallet',
              wallets,
              _sourceId,
              _destinationId,
              enabled ? (value) => setState(() => _sourceId = value) : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            _selector(
              'Destination wallet',
              wallets,
              _destinationId,
              _sourceId,
              enabled
                  ? (value) => setState(() => _destinationId = value)
                  : null,
            ),
            AppSecondaryButton(
              'Transfer date: ${calendarDate(_date)}',
              onPressed: enabled
                  ? () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(1),
                        lastDate: colomboToday(),
                      );
                      if (picked != null && mounted) {
                        setState(() => _date = picked);
                      }
                    }
                  : null,
            ),
          ] else if (source != null && destination != null) ...[
            Text('From ${source.name} to ${destination.name}'),
            Text(walletMoney(original.amount)),
          ],
          if (source != null && destination != null)
            ValueListenableBuilder(
              valueListenable: _amount,
              builder: (context, input, _) {
                final amount =
                    original?.amount ?? transferMinorUnits(input.text);
                final failure = amount == null
                    ? null
                    : _balanceError(source, destination, amount);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Available source balance: ${walletMoney(source.current)}',
                    ),
                    Text(
                      'Current destination balance: ${walletMoney(destination.current)}',
                    ),
                    if (failure != null)
                      AppErrorMessage(failure)
                    else if (amount != null) ...[
                      Text(
                        'Estimated source balance: ${walletMoney(source.current - amount)}',
                      ),
                      Text(
                        'Estimated destination balance: ${walletMoney(destination.current + amount)}',
                      ),
                    ],
                  ],
                );
              },
            ),
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            controller: _note,
            enabled: enabled,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
            validator: (value) => (value?.runes.length ?? 0) > 1000
                ? 'Enter up to 1,000 characters.'
                : null,
          ),
          const SizedBox(height: AppSpacing.md),
          if (eligible)
            AppPrimaryButton(
              original == null ? 'Review transfer' : 'Review reversal',
              busy: _sending,
              onPressed: () => _review(source, destination, original),
            ),
          TextButton(
            onPressed: enabled ? () => context.pop() : null,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _selector(
    String label,
    List<WalletRecord> wallets,
    String? selected,
    String? excluded,
    ValueChanged<String?>? onChanged,
  ) {
    final options = wallets.where((wallet) => wallet.id != excluded).toList();
    return DropdownButtonFormField<String>(
      initialValue: options.any((wallet) => wallet.id == selected)
          ? selected
          : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final wallet in options)
          DropdownMenuItem(
            value: wallet.id,
            child: Text(
              '${wallet.name} · ${wallet.type.label} · ${walletMoney(wallet.current)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
      validator: (value) => value == null ? 'Select a wallet.' : null,
    );
  }
}

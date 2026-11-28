import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/income_choices.dart';
import '../data/income_repository.dart';
import 'income_controller.dart';

class IncomeEditor extends StatefulWidget {
  const IncomeEditor(
    this.auth,
    this.repository,
    this.choices, {
    this.id,
    super.key,
  });
  final AuthController auth;
  final IncomeRepository repository;
  final IncomeChoiceLoader choices;
  final String? id;

  @override
  State<IncomeEditor> createState() => _IncomeEditorState();
}

class _IncomeEditorState extends State<IncomeEditor> {
  late var _options = _load();

  Future<(IncomeChoices, IncomeRecord?)> _load() async {
    final id = widget.id;
    return (
      await widget.choices.load(widget.auth),
      id == null
          ? null
          : await widget.auth.authenticatedRead(
              (access) => widget.repository.get(access, id),
            ),
    );
  }

  void _retry() {
    final options = _load();
    setState(() {
      _options = options;
    });
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: widget.id == null ? 'Add income' : 'Edit income',
    child: FutureBuilder(
      future: _options,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AppLoadingIndicator();
        }
        final data = snapshot.data;
        if (data == null) {
          return Column(
            children: [
              AppErrorMessage(incomeError(snapshot.error)),
              AppSecondaryButton('Try again', onPressed: _retry),
            ],
          );
        }
        return _IncomeForm(
          widget.auth,
          widget.repository,
          data.$1,
          data.$2,
          key: ValueKey(data.$2?.version),
        );
      },
    ),
  );
}

class _IncomeForm extends StatefulWidget {
  const _IncomeForm(
    this.auth,
    this.repository,
    this.choices,
    this.record, {
    super.key,
  });
  final AuthController auth;
  final IncomeRepository repository;
  final IncomeChoices choices;
  final IncomeRecord? record;

  @override
  State<_IncomeForm> createState() => _IncomeFormState();
}

class _IncomeFormState extends State<_IncomeForm> {
  final _form = GlobalKey<FormState>();
  late final _initial = widget.record == null
      ? widget.repository.pending
      : null;
  late final _title = TextEditingController(
    text: widget.record?.title ?? _saved('title'),
  );
  late final _amount = TextEditingController(
    text: widget.record?.rawAmount ?? _saved('amount'),
  );
  late final _note = TextEditingController(
    text: widget.record?.note ?? _saved('note'),
  );
  late String? _category = widget.record?.categoryId ?? _saved('category_id');
  late String? _wallet = widget.record?.walletId ?? _saved('wallet_id');
  late DateTime _date =
      widget.record?.date ??
      DateTime.tryParse(_saved('income_date') ?? '') ??
      colomboToday();
  bool _busy = false;
  late bool _uncertain = _initial != null;
  bool _stale = false;
  late String? _error = _initial == null
      ? null
      : 'A previous income submission is unresolved.';
  late String? _operation = _initial?.key;
  late Map<String, Object?>? _pendingDraft = _initial?.draft;

  String? _saved(String field) => _initial?.draft[field] as String?;

  Future<void> _save() async {
    if (_busy || _stale) return;
    final record = widget.record;
    if (_uncertain && record != null) return;
    if (!_uncertain && !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final draft =
        _pendingDraft ??
        {
          'title': _title.text.trim(),
          'amount': _amount.text,
          'wallet_id': _wallet,
          'category_id': _category,
          'income_date': calendarDate(_date),
          'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        };
    if (record == null) {
      _operation ??= incomeOperationKey();
      _pendingDraft = draft;
    }
    try {
      await widget.auth.authenticatedMutation(
        (access) => record == null
            ? widget.repository.create(access, draft, _operation!)
            : widget.repository.edit(access, record, draft),
      );
      if (!mounted) return;
      if (record == null) widget.repository.pending = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            record == null ? 'Income recorded.' : 'Income updated.',
          ),
        ),
      );
      context.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        final failure = error is ApiFailure ? error : null;
        _uncertain = _uncertain || failure?.uncertain == true;
        _stale =
            record != null &&
            (failure?.status == 404 ||
                failure?.message ==
                    'Income changed. Reload it before continuing.');
        if (!_uncertain) {
          _operation = null;
          _pendingDraft = null;
        }
        if (_uncertain && record == null && widget.auth.user != null) {
          widget.repository.pending = (key: _operation!, draft: _pendingDraft!);
        }
        _error = _uncertain
            ? 'The result is uncertain. Check authoritative income history before starting a new submission.'
            : incomeError(error);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile() async {
    if (widget.record == null &&
        !await confirmAction(
          context,
          title: 'Check income history?',
          description: 'Confirm whether the earlier income appears in history before entering it again. You can retry here with the same operation key.',
          action: 'Open history',
        )) {
      return;
    }
    if (mounted) context.pop();
  }

  Future<void> _resolvePending() async {
    if (!await confirmAction(
      context,
      title: 'Resolve previous submission?',
      description: 'Confirm that you reviewed current income history and resolved the earlier submission. If still unsure, retry the same submission.',
      action: 'Confirm history reviewed',
    )) {
      return;
    }
    if (!mounted) return;
    widget.repository.pending = null;
    context.pop();
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final enabled = !_busy && !_uncertain && !_stale;
    final categories = [
      ...widget.choices.categories,
      if (record != null &&
          !widget.choices.categories.any(
            (choice) => choice.id == record.categoryId,
          ))
        (id: record.categoryId, name: '${record.categoryName} (archived)'),
    ];
    final wallets = [
      ...widget.choices.wallets,
      if (record != null &&
          !widget.choices.wallets.any((choice) => choice.id == record.walletId))
        (id: record.walletId, name: '${record.walletName} (archived)'),
    ];
    final available = categories.isNotEmpty && wallets.isNotEmpty;
    return PopScope(
      canPop: !_busy && !_uncertain,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wallets.isEmpty)
              const AppErrorMessage(
                'Create an active wallet before recording income.',
              ),
            if (categories.isEmpty)
              const AppErrorMessage(
                'Create an active income category before recording income.',
              ),
            AppTextField(
              label: 'Income title',
              controller: _title,
              enabled: enabled,
              validator: (value) =>
                  value == null ||
                      value.trim().isEmpty ||
                      value.runes.length > 120
                  ? 'Enter a title of up to 120 characters.'
                  : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(
              label: 'Amount (LKR)',
              controller: _amount,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (value) => validIncomeAmount(value ?? '') ? null : 'Enter a positive LKR amount with up to two decimal places.',
            ),
            const SizedBox(height: AppSpacing.sm),
            incomeDropdown(
              'Income category',
              categories,
              _category,
              enabled ? (id) => setState(() => _category = id) : null,
              requiredValue: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            incomeDropdown(
              'Wallet',
              wallets,
              _wallet,
              enabled ? (id) => setState(() => _wallet = id) : null,
              requiredValue: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppSecondaryButton(
              'Income date: ${calendarDate(_date)}',
              onPressed: enabled
                  ? () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(1),
                        lastDate: colomboToday(),
                      );
                      if (date != null && mounted) setState(() => _date = date);
                    }
                  : null,
            ),
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
            Text(
              record == null
                  ? 'Saving credits the selected wallet.'
                  : _wallet != record.walletId
                  ? 'Saving reverses the original credit in ${record.walletName} and credits the selected wallet.'
                  : 'Changing the amount adjusts this wallet balance.',
            ),
            if (_error case final error?) AppErrorMessage(error),
            const SizedBox(height: AppSpacing.sm),
            if (!_stale && (_uncertain ? record == null : available))
              AppPrimaryButton(
                _uncertain
                    ? 'Retry same submission'
                    : record == null
                    ? 'Save income'
                    : 'Save changes',
                busy: _busy,
                onPressed: _save,
              ),
            if (_stale || _uncertain)
              AppSecondaryButton(
                record == null ? 'Check history' : 'Reload income',
                onPressed: _busy ? null : _reconcile,
              )
            else
              TextButton(
                onPressed: _busy ? null : () => context.pop(),
                child: const Text('Cancel'),
              ),
            if (_initial != null && _uncertain)
              TextButton(
                onPressed: _busy ? null : _resolvePending,
                child: const Text('Resolve after reviewing history'),
              ),
          ],
        ),
      ),
    );
  }
}

Widget incomeDropdown(
  String label,
  List<IncomeChoice> choices,
  String? value,
  ValueChanged<String?>? onChanged, {
  bool requiredValue = false,
}) => DropdownButtonFormField<String>(
  initialValue: choices.any((choice) => choice.id == value) ? value : null,
  decoration: InputDecoration(labelText: label),
  isExpanded: true,
  items: [
    if (!requiredValue) const DropdownMenuItem(value: '', child: Text('All')),
    for (final choice in choices)
      DropdownMenuItem(
        value: choice.id,
        child: Text(choice.name, overflow: TextOverflow.ellipsis),
      ),
  ],
  onChanged: onChanged,
  validator: requiredValue
      ? (value) => value == null ? 'Select an option.' : null
      : null,
);

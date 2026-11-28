import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../categories/presentation/category_style.dart';
import '../../wallets/data/wallet_repository.dart';
import '../data/income_choices.dart';
import '../data/income_repository.dart';
import 'income_controller.dart';
import 'income_form.dart';

class IncomeHistory extends StatefulWidget {
  const IncomeHistory(this.auth, this.repository, this.choices, {super.key});
  final AuthController auth;
  final IncomeRepository repository;
  final IncomeChoiceLoader choices;

  @override
  State<IncomeHistory> createState() => _IncomeHistoryState();
}

class _IncomeHistoryState extends State<IncomeHistory> {
  late IncomeController _state;

  @override
  void initState() {
    super.initState();
    _state = IncomeController(widget.auth, widget.repository)..reload();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) await _state.reload();
  }

  Future<void> _filter() async {
    final result = await showDialog<IncomeFilters>(
      context: context,
      builder: (_) => _IncomeFilterDialog(
        widget.auth,
        widget.choices,
        _state.filters,
        widget.repository.noun,
      ),
    );
    if (result != null && mounted) {
      _state.applyFilters(result.category, result.wallet, result.dates);
    }
  }

  Widget _expensePeriods(BuildContext context, MaterialLocalizations labels) {
    final start = _state.summary?.start;
    final end = _state.summary?.end;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Expense summary'),
        Wrap(
          spacing: AppSpacing.xs,
          children: [
            for (final period in ExpensePeriod.values)
              ChoiceChip(
                label: Text(switch (period) {
                  ExpensePeriod.day => 'Daily',
                  ExpensePeriod.week => 'Weekly',
                  ExpensePeriod.month => 'Monthly',
                }),
                selected: period == _state.period,
                onSelected: (_) =>
                    _state.selectExpensePeriod(_state.month, period),
              ),
          ],
        ),
        AppSecondaryButton(
          'Summary date: ${labels.formatMediumDate(_state.month)}',
          onPressed: () async {
            final selected = await showDatePicker(
              context: context,
              initialDate: _state.month,
              firstDate: DateTime(1),
              lastDate: colomboToday(),
            );
            if (selected != null && mounted) {
              _state.selectExpensePeriod(selected, _state.period);
            }
          },
        ),
        if (start != null && end != null)
          Text(
            start == end
                ? labels.formatMediumDate(start)
                : '${labels.formatMediumDate(start)} to ${labels.formatMediumDate(end)}',
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _state,
    builder: (context, _) {
      final labels = MaterialLocalizations.of(context);
      final month = _state.month;
      final expense = widget.repository.expense;
      final noun = widget.repository.noun;
      final route = widget.repository.route;
      final color = expense ? AppColors.error : AppColors.success;
      final today = colomboToday();
      final nextMonth = DateTime(month.year, month.month + 1);
      return AuthScreenLayout(
        title: expense ? 'Expenses' : 'Income',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (expense)
                      _expensePeriods(context, labels)
                    else ...[
                      const Text('Monthly income'),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            tooltip: 'Previous month',
                            icon: const Icon(Icons.chevron_left),
                            onPressed: month.year == 1 && month.month == 1
                                ? null
                                : () => _state.selectMonth(
                                    DateTime(month.year, month.month - 1),
                                  ),
                          ),
                          Flexible(
                            child: Text(
                              labels.formatMonthYear(month),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Next month',
                            icon: const Icon(Icons.chevron_right),
                            onPressed: nextMonth.isAfter(today)
                                ? null
                                : () => _state.selectMonth(nextMonth),
                          ),
                        ],
                      ),
                    ],
                    if (_state.summary case final summary?) ...[
                      Text(
                        walletMoney(summary.total),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: color),
                      ),
                      Text('${summary.count} $noun records'),
                      for (final category in summary.categories)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(category.name),
                          subtitle: Text(walletMoney(category.amount)),
                          trailing: expense && summary.total != BigInt.zero
                              ? Text(
                                  '${category.amount * BigInt.from(100) ~/ summary.total}%',
                                )
                              : null,
                        ),
                    ],
                    if (_state.loadingSummary)
                      const Center(child: AppLoadingIndicator()),
                    if (_state.summaryError case final error?) ...[
                      AppErrorMessage(error),
                      AppSecondaryButton(
                        'Retry summary',
                        onPressed: _state.reloadSummary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppPrimaryButton('Add $noun', onPressed: () => _open('$route/add')),
            TextField(
              onChanged: _state.search,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Search title or note',
                prefixIcon: Icon(Icons.search),
                counterText: '',
              ),
            ),
            AppSecondaryButton('Filter history', onPressed: _filter),
            if (_state.filters.category != null ||
                _state.filters.wallet != null ||
                _state.filters.dates != null)
              AppSecondaryButton(
                'Clear filters',
                onPressed: () => _state.applyFilters(null, null, null),
              ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${widget.repository.label} history',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (_state.historyError case final error?) ...[
              AppErrorMessage(error),
              AppSecondaryButton(
                'Retry history',
                onPressed: _state.reloadHistory,
              ),
            ],
            if (!_state.loading &&
                _state.items.isEmpty &&
                _state.historyError == null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text('No $noun records match.'),
              ),
            for (final record in _state.items)
              Card(
                child: ListTile(
                  leading: CategoryBadge(
                    record.categoryIcon,
                    record.categoryColor,
                  ),
                  title: Text(record.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${record.categoryName} · ${record.walletName}'),
                      Text(labels.formatMediumDate(record.date)),
                      Text(
                        '${expense ? '-' : '+'} ${walletMoney(record.amount)}',
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                  onTap: () => _open('$route/${record.id}'),
                ),
              ),
            if (_state.next != null &&
                !_state.loading &&
                _state.historyError == null)
              AppSecondaryButton('Load more', onPressed: _state.more),
            if (_state.loading) const Center(child: AppLoadingIndicator()),
          ],
        ),
      );
    },
  );
}

class _IncomeFilterDialog extends StatefulWidget {
  const _IncomeFilterDialog(this.auth, this.choices, this.initial, this.noun);
  final AuthController auth;
  final IncomeChoiceLoader choices;
  final IncomeFilters initial;
  final String noun;

  @override
  State<_IncomeFilterDialog> createState() => _IncomeFilterDialogState();
}

class _IncomeFilterDialogState extends State<_IncomeFilterDialog> {
  late final options = widget.choices.load(widget.auth, includeArchived: true);
  late String? category = widget.initial.category;
  late String? wallet = widget.initial.wallet;
  late DateTimeRangeValue? dates = widget.initial.dates;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Filter ${widget.noun} history'),
    scrollable: true,
    content: FutureBuilder(
      future: options,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AppLoadingIndicator();
        }
        final choices = snapshot.data;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (choices == null)
              AppErrorMessage(incomeError(snapshot.error))
            else ...[
              incomeDropdown(
                'Category',
                choices.categories,
                category,
                (id) => setState(() => category = id == '' ? null : id),
              ),
              incomeDropdown(
                'Wallet',
                choices.wallets,
                wallet,
                (id) => setState(() => wallet = id == '' ? null : id),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            AppSecondaryButton(
              dates == null
                  ? 'Pick date range'
                  : '${calendarDate(dates!.start)} to ${calendarDate(dates!.end)}',
              onPressed: () async {
                final old = dates;
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(1),
                  lastDate: colomboToday(),
                  initialDateRange: old == null
                      ? null
                      : DateTimeRange(start: old.start, end: old.end),
                );
                if (picked != null && mounted) {
                  setState(
                    () => dates = (start: picked.start, end: picked.end),
                  );
                }
              },
            ),
            if (dates != null)
              TextButton(
                onPressed: () => setState(() => dates = null),
                child: const Text('Clear dates'),
              ),
          ],
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, (
          search: widget.initial.search,
          category: category,
          wallet: wallet,
          dates: dates,
        )),
        child: const Text('Apply filters'),
      ),
    ],
  );
}

class IncomeDetails extends StatefulWidget {
  const IncomeDetails(this.auth, this.repository, this.id, {super.key});
  final AuthController auth;
  final IncomeRepository repository;
  final String id;

  @override
  State<IncomeDetails> createState() => _IncomeDetailsState();
}

class _IncomeDetailsState extends State<IncomeDetails> {
  late Future<IncomeRecord> _record = _load();
  bool _busy = false;
  String? _error;
  String get noun => widget.repository.noun;
  String get route => widget.repository.route;
  bool get expense => widget.repository.expense;

  Future<IncomeRecord> _load() => widget.auth.authenticatedRead(
    (access) => widget.repository.get(access, widget.id),
  );

  void _refresh() {
    final record = _load();
    setState(() {
      _record = record;
    });
  }

  Future<void> _delete(IncomeRecord record) async {
    if (_busy) return;
    final owner = widget.auth.user?.id;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await confirmAction(
        context,
        title: 'Delete this $noun?',
        description: expense
            ? '${walletMoney(record.amount)} will be credited back to ${record.walletName}.'
            : '${walletMoney(record.amount)} will be deducted from ${record.walletName}.',
        action: 'Delete $noun',
        destructive: true,
      )) {
        return;
      }
      if (!mounted || owner != widget.auth.user?.id) return;
      await widget.auth.authenticatedMutation(
        (access) => widget.repository.delete(access, record),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.repository.label} deleted.')),
      );
      context.pop();
    } catch (error) {
      if (!mounted) return;
      final failure = error is ApiFailure ? error : null;
      setState(() {
        _error = failure?.uncertain == true
            ? 'The outcome is uncertain. Check the refreshed record or return to history.'
            : incomeError(error);
      });
      if (failure?.status == 409 ||
          failure?.uncertain == true ||
          failure?.status == 404) {
        _refresh();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: '${widget.repository.label} details',
    child: FutureBuilder(
      future: _record,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AppLoadingIndicator();
        }
        final record = snapshot.data;
        final labels = MaterialLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error case final error?) AppErrorMessage(error),
            if (record == null) ...[
              AppErrorMessage(incomeError(snapshot.error)),
              AppSecondaryButton('Try again', onPressed: _refresh),
            ] else ...[
              ListTile(
                leading: CategoryBadge(
                  record.categoryIcon,
                  record.categoryColor,
                ),
                title: Text(record.title),
                subtitle: Text(
                  '${expense ? '-' : '+'} ${walletMoney(record.amount)}',
                  style: TextStyle(
                    color: expense ? AppColors.error : AppColors.success,
                  ),
                ),
              ),
              ListTile(
                title: const Text('Category'),
                subtitle: Text(
                  '${record.categoryName}${record.categoryActive ? '' : ' (archived)'}',
                ),
              ),
              ListTile(
                title: const Text('Wallet'),
                subtitle: Text(
                  '${record.walletName}${record.walletActive ? '' : ' (archived)'}',
                ),
              ),
              ListTile(
                title: Text(expense ? 'Spent' : 'Received'),
                subtitle: Text(labels.formatFullDate(record.date)),
              ),
              if (record.note case final note?)
                ListTile(title: const Text('Note'), subtitle: Text(note)),
              ListTile(
                title: const Text('Created'),
                subtitle: Text(record.created.toUtc().toIso8601String()),
              ),
              ListTile(
                title: const Text('Updated'),
                subtitle: Text(record.updated.toUtc().toIso8601String()),
              ),
              AppPrimaryButton(
                'Edit $noun',
                onPressed: _busy
                    ? null
                    : () async {
                        await context.push('$route/${record.id}/edit');
                        if (mounted) _refresh();
                      },
              ),
              AppSecondaryButton(
                'Delete $noun',
                onPressed: _busy ? null : () => _delete(record),
              ),
            ],
          ],
        );
      },
    ),
  );
}

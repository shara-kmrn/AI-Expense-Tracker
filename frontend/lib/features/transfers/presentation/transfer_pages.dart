import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../categories/presentation/category_style.dart';
import '../../incomes/data/income_repository.dart'
    show DateTimeRangeValue, calendarDate, colomboToday;
import '../../wallets/data/wallet_repository.dart';
import '../data/transfer_repository.dart';
import 'transfer_controller.dart';

const transferRoute = '/home/transfers';

class TransferHistoryPage extends StatefulWidget {
  const TransferHistoryPage(this.auth, this.repository, {super.key});
  final AuthController auth;
  final TransferRepository repository;

  @override
  State<TransferHistoryPage> createState() => _TransferHistoryPageState();
}

class _TransferHistoryPageState extends State<TransferHistoryPage> {
  late final _state = TransferController(widget.auth, widget.repository)
    ..reload();

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
    final filters = await showDialog<TransferFilters>(
      context: context,
      builder: (_) =>
          _TransferFilter(widget.auth, widget.repository, _state.filters),
    );
    if (filters != null && mounted) _state.apply(filters);
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: 'Wallet transfers',
    child: ListenableBuilder(
      listenable: _state,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppPrimaryButton(
            'New transfer',
            onPressed: () => _open('$transferRoute/add'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            onChanged: _state.search,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Search note or wallet',
              prefixIcon: Icon(Icons.search),
              counterText: '',
            ),
          ),
          AppSecondaryButton('Filter transfers', onPressed: _filter),
          if (_state.filters.wallet != null ||
              _state.filters.dates != null ||
              _state.filters.kind != null)
            AppSecondaryButton(
              'Clear filters',
              onPressed: () => _state.apply((
                search: _state.filters.search,
                wallet: null,
                dates: null,
                kind: null,
              )),
            ),
          if (_state.error case final error?) ...[
            AppErrorMessage(error),
            AppSecondaryButton('Try again', onPressed: _state.reload),
          ],
          if (!_state.loading && _state.error == null && _state.items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text('No transfers match.'),
            ),
          for (final record in _state.items)
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.control),
                onTap: () => _open('$transferRoute/${record.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _WalletLine(record.source, 'From'),
                      const Padding(
                        padding: EdgeInsets.only(left: AppSpacing.sm),
                        child: Icon(
                          Icons.arrow_downward_rounded,
                          semanticLabel: 'Transfer to',
                        ),
                      ),
                      _WalletLine(record.destination, 'To'),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        walletMoney(record.amount),
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(color: AppColors.gold),
                      ),
                      Text(
                        '${calendarDate(record.date)} · ${record.status.label}',
                      ),
                      if (record.note case final note?) Text(note),
                    ],
                  ),
                ),
              ),
            ),
          if (_state.next != null && !_state.loading && _state.error == null)
            AppSecondaryButton('Load more', onPressed: _state.more),
          if (_state.loading) const Center(child: AppLoadingIndicator()),
        ],
      ),
    ),
  );
}

class _WalletLine extends StatelessWidget {
  const _WalletLine(this.wallet, this.direction);
  final TransferWallet wallet;
  final String direction;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      CategoryBadge(wallet.icon, wallet.color),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Text(
          '$direction ${wallet.name}${wallet.active ? '' : ' (archived)'}',
        ),
      ),
    ],
  );
}

class _TransferFilter extends StatefulWidget {
  const _TransferFilter(this.auth, this.repository, this.initial);
  final AuthController auth;
  final TransferRepository repository;
  final TransferFilters initial;

  @override
  State<_TransferFilter> createState() => _TransferFilterState();
}

class _TransferFilterState extends State<_TransferFilter> {
  late final _wallets = widget.repository.walletOptions(
    widget.auth,
    archived: true,
  );
  late String? _wallet = widget.initial.wallet;
  late String? _kind = widget.initial.kind;
  late DateTimeRangeValue? _dates = widget.initial.dates;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Filter transfers'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder(
          future: _wallets,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const AppLoadingIndicator();
            }
            if (snapshot.hasError) {
              return AppErrorMessage(transferError(snapshot.error));
            }
            final wallets = snapshot.data ?? [];
            return DropdownButtonFormField<String>(
              initialValue: wallets.any((item) => item.id == _wallet)
                  ? _wallet
                  : '',
              decoration: const InputDecoration(labelText: 'Wallet'),
              isExpanded: true,
              items: [
                const DropdownMenuItem(value: '', child: Text('All wallets')),
                for (final wallet in wallets)
                  DropdownMenuItem(
                    value: wallet.id,
                    child: Text(wallet.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => _wallet = value == '' ? null : value),
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        DropdownButtonFormField<String>(
          initialValue: _kind ?? '',
          decoration: const InputDecoration(labelText: 'Transfer kind'),
          items: const [
            DropdownMenuItem(value: '', child: Text('All records')),
            DropdownMenuItem(
              value: 'original',
              child: Text('Original transfers'),
            ),
            DropdownMenuItem(value: 'reversal', child: Text('Reversals')),
          ],
          onChanged: (value) =>
              setState(() => _kind = value == '' ? null : value),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppSecondaryButton(
          _dates == null
              ? 'Pick date range'
              : '${calendarDate(_dates!.start)} to ${calendarDate(_dates!.end)}',
          onPressed: () async {
            final old = _dates;
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(1),
              lastDate: colomboToday(),
              initialDateRange: old == null
                  ? null
                  : DateTimeRange(start: old.start, end: old.end),
            );
            if (picked != null && mounted) {
              setState(() => _dates = (start: picked.start, end: picked.end));
            }
          },
        ),
        if (_dates != null)
          TextButton(
            onPressed: () => setState(() => _dates = null),
            child: const Text('Clear dates'),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, (
          search: widget.initial.search,
          wallet: _wallet,
          kind: _kind,
          dates: _dates,
        )),
        child: const Text('Apply filters'),
      ),
    ],
  );
}

class TransferDetailsPage extends StatefulWidget {
  const TransferDetailsPage(this.auth, this.repository, this.id, {super.key});
  final AuthController auth;
  final TransferRepository repository;
  final String id;

  @override
  State<TransferDetailsPage> createState() => _TransferDetailsPageState();
}

class _TransferDetailsPageState extends State<TransferDetailsPage> {
  late Future<TransferRecord> _record = _load();

  Future<TransferRecord> _load() => widget.auth.authenticatedRead(
    (access) => widget.repository.get(access, widget.id),
  );

  void _refresh() {
    final record = _load();
    setState(() {
      _record = record;
    });
  }

  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: 'Transfer details',
    child: FutureBuilder(
      future: _record,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AppLoadingIndicator();
        }
        final record = snapshot.data;
        if (record == null) {
          return Column(
            children: [
              AppErrorMessage(transferError(snapshot.error)),
              AppSecondaryButton('Try again', onPressed: _refresh),
            ],
          );
        }
        final pending = widget.repository.pendingReversals[record.id] != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              walletMoney(record.amount),
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(color: AppColors.gold),
            ),
            Text(record.status.label),
            const SizedBox(height: AppSpacing.md),
            _WalletLine(record.source, 'From'),
            const Padding(
              padding: EdgeInsets.only(left: AppSpacing.sm),
              child: Icon(
                Icons.arrow_downward_rounded,
                semanticLabel: 'Transfer to',
              ),
            ),
            _WalletLine(record.destination, 'To'),
            ListTile(
              title: const Text('Transfer date'),
              subtitle: Text(calendarDate(record.date)),
            ),
            if (record.note case final note?)
              ListTile(title: const Text('Note'), subtitle: Text(note)),
            ListTile(
              title: const Text('Recorded at'),
              subtitle: Text(record.created.toUtc().toIso8601String()),
            ),
            if (record.reversalOf case final id?)
              AppSecondaryButton(
                'View original transfer',
                onPressed: () => _open('$transferRoute/$id'),
              ),
            if (record.reversal case final id?)
              AppSecondaryButton(
                'View reversal',
                onPressed: () => _open('$transferRoute/$id'),
              ),
            if (pending ||
                (record.status == TransferStatus.original &&
                    record.source.active &&
                    record.destination.active))
              AppPrimaryButton(
                pending ? 'Review pending reversal' : 'Reverse transfer',
                onPressed: () => _open('$transferRoute/${record.id}/reverse'),
              ),
            if (record.status == TransferStatus.original &&
                (!record.source.active || !record.destination.active))
              const AppErrorMessage(
                'Restore both wallets before reversing this transfer.',
              ),
          ],
        );
      },
    ),
  );
}

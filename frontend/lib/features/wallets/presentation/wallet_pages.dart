import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../categories/presentation/category_style.dart';
import '../data/wallet_repository.dart';
import 'wallet_controller.dart';

const walletsRoute = '/home/wallets';

String walletError(Object? error) => error is ApiFailure
    ? error.message
    : 'The wallet request could not be completed.';

class WalletsPage extends StatefulWidget {
  const WalletsPage(this.auth, this.repository, {super.key});
  final AuthController auth;
  final WalletRepository repository;

  @override
  State<WalletsPage> createState() => _WalletsPageState();
}

class _WalletsPageState extends State<WalletsPage> {
  late final WalletController _state;
  bool _busy = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _state = WalletController(widget.auth, widget.repository)..reload();
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

  Future<void> _change(WalletRecord wallet) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final message = await changeWalletStatus(
      context,
      widget.auth,
      widget.repository,
      wallet,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = message;
    });
    if (message != null) await _state.reload();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _state,
    builder: (context, _) => AuthScreenLayout(
      title: _state.archived ? 'Archived wallets' : 'My wallets',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_state.summary case final summary?)
            Card(
              child: ListTile(
                title: const Text('Total active wallet balance'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      walletMoney(summary.total),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      '${summary.activeCount} active · ${summary.archivedCount} archived',
                    ),
                  ],
                ),
                leading: const Icon(Icons.account_balance_wallet_outlined),
              ),
            ),
          TextField(
            onChanged: _state.setSearch,
            decoration: const InputDecoration(
              labelText: 'Search wallets',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _state.type == null,
                onSelected: (_) => _state.filter(null),
              ),
              for (final type in WalletType.values)
                ChoiceChip(
                  label: Text(type.label),
                  selected: _state.type == type,
                  onSelected: (_) => _state.filter(type),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (!_state.archived)
            AppPrimaryButton(
              'Add wallet',
              onPressed: () => _open('$walletsRoute/add'),
            ),
          AppSecondaryButton(
            _state.archived ? 'Active wallets' : 'Archived wallets',
            onPressed: _state.toggleArchived,
          ),
          if (_notice case final notice?)
            AppErrorMessage(notice, information: true),
          if (_state.error case final error?) ...[
            AppErrorMessage(error),
            AppSecondaryButton('Try again', onPressed: _state.reload),
          ],
          if (!_state.loading && _state.items.isEmpty && _state.error == null)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text('No wallets match.'),
            ),
          for (final wallet in _state.items)
            Card(
              child: ListTile(
                leading: CategoryBadge(wallet.icon, wallet.color),
                title: Text(wallet.name),
                subtitle: Text(
                  '${wallet.type.label} · ${wallet.active ? 'Active' : 'Archived'}\n${walletMoney(wallet.current)}',
                ),
                onTap: () => _open('$walletsRoute/${wallet.id}'),
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  tooltip: 'Actions for ${wallet.name}',
                  onSelected: (action) {
                    if (action == 'edit') {
                      _open('$walletsRoute/${wallet.id}/edit');
                    } else {
                      _change(wallet);
                    }
                  },
                  itemBuilder: (_) => [
                    if (wallet.active)
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'status',
                      child: Text(wallet.active ? 'Archive' : 'Restore'),
                    ),
                  ],
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

Future<String?> changeWalletStatus(
  BuildContext context,
  AuthController auth,
  WalletRepository repository,
  WalletRecord wallet,
) async {
  if (wallet.active) {
    if (wallet.current != BigInt.zero) {
      return 'A wallet must have a zero balance before archiving.';
    }
    final confirmed = await confirmAction(
      context,
      title: 'Archive this wallet?',
      description: 'Only wallets with a zero balance can be archived. The wallet record is preserved and can be restored later.',
      action: 'Archive wallet',
    );
    if (!confirmed || !context.mounted) return null;
  }
  try {
    await auth.authenticatedMutation(
      (access) =>
          repository.setActive(access, wallet.id, active: !wallet.active),
    );
    return wallet.active ? 'Wallet archived.' : 'Wallet restored.';
  } catch (error) {
    if (error is ApiFailure && error.uncertain) {
      return 'The result could not be confirmed. Check the refreshed wallet before trying again.';
    }
    return walletError(error);
  }
}

class WalletDetailsPage extends StatefulWidget {
  const WalletDetailsPage(this.auth, this.repository, this.id, {super.key});
  final AuthController auth;
  final WalletRepository repository;
  final String id;

  @override
  State<WalletDetailsPage> createState() => _WalletDetailsPageState();
}

class _WalletDetailsPageState extends State<WalletDetailsPage> {
  late Future<WalletRecord> _wallet = _load();
  bool _busy = false;
  String? _notice;

  Future<WalletRecord> _load() => widget.auth.authenticatedRead(
    (access) => widget.repository.get(access, widget.id),
  );

  void _reload() {
    final wallet = _load();
    setState(() {
      _wallet = wallet;
    });
  }

  Future<void> _change(WalletRecord wallet) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final message = await changeWalletStatus(
      context,
      widget.auth,
      widget.repository,
      wallet,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = message;
      if (message != null) _wallet = _load();
    });
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: 'Wallet details',
    child: FutureBuilder<WalletRecord>(
      future: _wallet,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const AppLoadingIndicator();
        }
        final wallet = snapshot.data;
        if (wallet == null) {
          return Column(
            children: [
              AppErrorMessage(walletError(snapshot.error)),
              AppSecondaryButton('Try again', onPressed: _reload),
            ],
          );
        }
        final dates = MaterialLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: CategoryBadge(wallet.icon, wallet.color),
              title: Text(wallet.name),
              subtitle: Text(
                '${wallet.type.label} · LKR · ${wallet.active ? 'Active' : 'Archived'}',
              ),
            ),
            ListTile(
              title: const Text('Opening balance'),
              subtitle: Text(walletMoney(wallet.opening)),
            ),
            ListTile(
              title: const Text('Current balance'),
              subtitle: Text(walletMoney(wallet.current)),
            ),
            ListTile(
              title: const Text('Created'),
              subtitle: Text(dates.formatFullDate(wallet.createdAt.toLocal())),
            ),
            ListTile(
              title: const Text('Last updated'),
              subtitle: Text(dates.formatFullDate(wallet.updatedAt.toLocal())),
            ),
            const Text(
              'Transaction history will be available when financial transactions are supported.',
            ),
            const SizedBox(height: AppSpacing.md),
            if (_notice case final notice?)
              AppErrorMessage(notice, information: true),
            if (wallet.active)
              AppSecondaryButton(
                'Edit wallet',
                onPressed: _busy
                    ? null
                    : () async {
                        await context.push('$walletsRoute/${wallet.id}/edit');
                        if (mounted) _reload();
                      },
              ),
            AppSecondaryButton(
              wallet.active ? 'Archive wallet' : 'Restore wallet',
              onPressed: _busy ? null : () => _change(wallet),
            ),
          ],
        );
      },
    ),
  );
}

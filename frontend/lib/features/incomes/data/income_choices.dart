import '../../auth/presentation/auth_controller.dart';
import '../../categories/data/category_repository.dart';
import '../../wallets/data/wallet_repository.dart';

typedef IncomeChoice = ({String id, String name});
typedef IncomeChoices = ({
  List<IncomeChoice> categories,
  List<IncomeChoice> wallets,
  Map<String, BigInt> balances,
});

class IncomeChoiceLoader {
  const IncomeChoiceLoader(
    this.categories,
    this.wallets, {
    this.categoryType = CategoryType.income,
  });
  final CategoryType categoryType;
  final CategoryRepository categories;
  final WalletRepository wallets;

  Future<IncomeChoices> load(
    AuthController auth, {
    bool includeArchived = false,
  }) async {
    final (categoryOptions, walletOptions) = await (
      _categories(auth, includeArchived),
      _wallets(auth, includeArchived),
    ).wait;
    return (
      categories: categoryOptions,
      wallets: walletOptions.items,
      balances: walletOptions.balances,
    );
  }

  Future<List<IncomeChoice>> _categories(
    AuthController auth,
    bool includeArchived,
  ) async {
    final items = <IncomeChoice>[];
    for (final archived in [false, if (includeArchived) true]) {
      int? offset = 0;
      while (offset != null) {
        final current = offset;
        final page = await auth.authenticatedRead(
          (access) => categories.list(
            access,
            categoryType,
            '',
            archived: archived,
            offset: current,
          ),
        );
        items.addAll(
          page.items.map(
            (item) => (
              id: item.id,
              name: archived ? '${item.name} (archived)' : item.name,
            ),
          ),
        );
        offset = page.nextOffset;
      }
    }
    return items;
  }

  Future<({List<IncomeChoice> items, Map<String, BigInt> balances})> _wallets(
    AuthController auth,
    bool includeArchived,
  ) async {
    final items = <IncomeChoice>[];
    final balances = <String, BigInt>{};
    for (final archived in [false, if (includeArchived) true]) {
      int? offset = 0;
      while (offset != null) {
        final current = offset;
        final page = await auth.authenticatedRead(
          (access) => wallets.list(
            access,
            archived: archived,
            search: '',
            offset: current,
          ),
        );
        balances.addEntries(
          page.items.map((item) => MapEntry(item.id, item.current)),
        );
        items.addAll(
          page.items.map(
            (item) => (
              id: item.id,
              name: categoryType == CategoryType.expense
                  ? '${item.name} · ${item.type.label} · ${walletMoney(item.current)}${archived ? ' (archived)' : ''}'
                  : archived
                  ? '${item.name} (archived)'
                  : item.name,
            ),
          ),
        );
        offset = page.next;
      }
    }
    return (items: items, balances: balances);
  }
}

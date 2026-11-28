import '../../auth/presentation/auth_controller.dart';
import '../../categories/data/category_repository.dart';
import '../../wallets/data/wallet_repository.dart';

typedef IncomeChoice = ({String id, String name});
typedef IncomeChoices = ({
  List<IncomeChoice> categories,
  List<IncomeChoice> wallets,
});

class IncomeChoiceLoader {
  const IncomeChoiceLoader(this.categories, this.wallets);
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
    return (categories: categoryOptions, wallets: walletOptions);
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
            CategoryType.income,
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

  Future<List<IncomeChoice>> _wallets(
    AuthController auth,
    bool includeArchived,
  ) async {
    final items = <IncomeChoice>[];
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
        items.addAll(
          page.items.map(
            (item) => (
              id: item.id,
              name: archived ? '${item.name} (archived)' : item.name,
            ),
          ),
        );
        offset = page.next;
      }
    }
    return items;
  }
}

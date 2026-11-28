import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/category_repository.dart';
import 'categories_controller.dart';
import 'category_style.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage(this.auth, this.repository, {super.key});
  final AuthController auth;
  final CategoryRepository repository;

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  late final CategoriesController _controller;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = CategoriesController(widget.auth, widget.repository)
      ..reload();
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(String route) async {
    final changed = await context.push<bool>(route);
    if (mounted && changed == true) {
      await _controller.reload();
    }
  }

  Future<void> _archive(CategoryRecord category) async {
    final confirmed = await confirmAction(
      context,
      title: 'Archive this category?',
      description: 'It will be hidden from future transaction selection. Its record is preserved and you can restore it later.',
      action: 'Archive category',
    );
    if (confirmed && mounted) await _controller.setActive(category, false);
  }

  Widget _tile(CategoryRecord category) => ListTile(
    leading: CategoryBadge(category.icon, category.color),
    title: Text(category.name),
    subtitle: category.isDefault ? const Text('Default category') : null,
    trailing: category.isDefault
        ? const Tooltip(
            message: 'Protected default',
            child: Icon(Icons.lock_outline),
          )
        : _controller.archived
        ? TextButton(
            onPressed: _controller.mutating
                ? null
                : () => _controller.setActive(category, true),
            child: const Text('Restore'),
          )
        : PopupMenuButton<String>(
            tooltip: 'Actions for ${category.name}',
            enabled: !_controller.mutating,
            onSelected: (action) {
              if (action == 'edit') {
                _open('/home/categories/${category.id}/edit');
              } else {
                _archive(category);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'archive', child: Text('Archive')),
            ],
          ),
  );

  Widget _section(String title, List<CategoryRecord> items, String empty) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          if (items.isEmpty)
            Text(empty, style: const TextStyle(color: AppColors.muted))
          else
            Card(
              child: Column(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    if (index != 0) const Divider(height: 1),
                    _tile(items[index]),
                  ],
                ],
              ),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final defaults = _controller.items
          .where((item) => item.isDefault)
          .toList();
      final custom = _controller.items
          .where((item) => !item.isDefault)
          .toList();
      return AuthScreenLayout(
        title: _controller.archived ? 'Archived categories' : 'Categories',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<CategoryType>(
              segments: [
                for (final type in CategoryType.values)
                  ButtonSegment(value: type, label: Text(type.label)),
              ],
              selected: {_controller.type},
              onSelectionChanged: (selection) =>
                  _controller.setType(selection.single),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _search,
              onChanged: _controller.setSearch,
              decoration: const InputDecoration(
                labelText: 'Search categories',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (!_controller.archived) ...[
              AppPrimaryButton(
                'Add category',
                onPressed: () =>
                    _open('/home/categories/add?type=${_controller.type.code}'),
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            AppSecondaryButton(
              _controller.archived
                  ? 'Active categories'
                  : 'Archived categories',
              onPressed: () => _controller.setArchived(!_controller.archived),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_controller.notice case final message?) ...[
              AppErrorMessage(message, information: true),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (_controller.error case final error?) ...[
              AppErrorMessage(error),
              const SizedBox(height: AppSpacing.xs),
              AppSecondaryButton('Try again', onPressed: _controller.reload),
            ] else if (!_controller.loading ||
                _controller.items.isNotEmpty) ...[
              if (!_controller.archived) ...[
                _section(
                  'Default categories',
                  defaults,
                  'No matching default categories.',
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              _section(
                _controller.archived
                    ? 'Archived custom categories'
                    : 'My categories',
                custom,
                _controller.archived
                    ? 'No archived categories match.'
                    : 'No custom categories match.',
              ),
              if (_controller.nextOffset != null && !_controller.loading) ...[
                const SizedBox(height: AppSpacing.md),
                AppSecondaryButton(
                  'Load more',
                  onPressed: _controller.loadMore,
                ),
              ],
            ],
            if (_controller.loading || _controller.mutating)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: AppLoadingIndicator()),
              ),
          ],
        ),
      );
    },
  );
}

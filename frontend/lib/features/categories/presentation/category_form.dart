import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/category_repository.dart';
import 'category_style.dart';

String? validateCategoryName(String? input) {
  final raw = input ?? '';
  final value = raw.trim().replaceAll(RegExp(r'\s+', unicode: true), ' ');
  if (raw.runes.length > 1024 ||
      RegExp(r'[\p{Cc}\p{Cf}\p{Cs}]', unicode: true).hasMatch(raw)) {
    return 'Use a name without control characters.';
  }
  if (value.isEmpty || value.runes.length > 80) {
    return 'Enter a name of 1–80 characters.';
  }
  return null;
}

class EditCategoryPage extends StatefulWidget {
  const EditCategoryPage(this.auth, this.repository, this.id, {super.key});
  final AuthController auth;
  final CategoryRepository repository;
  final String id;

  @override
  State<EditCategoryPage> createState() => _EditCategoryPageState();
}

class _EditCategoryPageState extends State<EditCategoryPage> {
  late Future<CategoryRecord> _record = _load();

  Future<CategoryRecord> _load() => widget.auth.authenticatedRead(
    (access) => widget.repository.get(access, widget.id),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<CategoryRecord>(
    future: _record,
    builder: (context, snapshot) {
      final record = snapshot.data;
      if (record != null && !record.isDefault) {
        return CategoryForm(
          widget.auth,
          widget.repository,
          record.type,
          record: record,
        );
      }
      return AuthScreenLayout(
        title: 'Edit category',
        child: snapshot.connectionState != ConnectionState.done
            ? const AppLoadingIndicator()
            : Column(
                children: [
                  AppErrorMessage(
                    record != null
                        ? 'Default categories are protected.'
                        : snapshot.error is ApiFailure
                        ? (snapshot.error! as ApiFailure).message
                        : 'Could not load category.',
                  ),
                  if (record == null)
                    AppSecondaryButton(
                      'Try again',
                      onPressed: () => setState(() => _record = _load()),
                    ),
                ],
              ),
      );
    },
  );
}

class CategoryForm extends StatefulWidget {
  const CategoryForm(
    this.auth,
    this.repository,
    this.initialType, {
    super.key,
    this.record,
  });
  final AuthController auth;
  final CategoryRepository repository;
  final CategoryType initialType;
  final CategoryRecord? record;

  @override
  State<CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<CategoryForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.record?.name);
  late CategoryType _type = widget.initialType;
  late String _icon = widget.record?.icon ?? 'category';
  late String _color = widget.record?.color ?? '#D4AF37';
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
      final draft = CategoryDraft(_name.text.trim(), _type, _icon, _color);
      await widget.auth.authenticatedMutation(
        (access) =>
            widget.repository.save(access, draft, id: widget.record?.id),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.record == null ? 'Category created.' : 'Category updated.',
          ),
        ),
      );
      context.pop(true);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _uncertain = failure is ApiFailure && failure.uncertain;
        _error = _uncertain
            ? 'The result could not be confirmed. Check the refreshed list before trying again.'
            : failure is ApiFailure
            ? failure.message
            : 'Could not save the category.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AuthScreenLayout(
    title: widget.record == null ? 'Add category' : 'Edit category',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            label: 'Category name',
            controller: _name,
            validator: validateCategoryName,
            enabled: !_busy && !_uncertain,
          ),
          const SizedBox(height: AppSpacing.md),
          if (widget.record == null)
            SegmentedButton<CategoryType>(
              segments: [
                for (final type in CategoryType.values)
                  ButtonSegment(value: type, label: Text(type.label)),
              ],
              selected: {_type},
              onSelectionChanged: _busy || _uncertain
                  ? null
                  : (selection) => setState(() => _type = selection.single),
            )
          else
            Text('Type: ${_type.label}'),
          const SizedBox(height: AppSpacing.lg),
          Text('Icon', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final entry in categoryIcons.entries)
                ChoiceChip(
                  label: Text(entry.value.$1),
                  avatar: Icon(entry.value.$2, size: 18),
                  selected: _icon == entry.key,
                  onSelected: _busy || _uncertain
                      ? null
                      : (_) => setState(() => _icon = entry.key),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Color', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
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
                  onSelected: _busy || _uncertain
                      ? null
                      : (_) => setState(() => _color = entry.key),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Card(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _name,
              builder: (_, value, _) => ListTile(
                leading: CategoryBadge(_icon, _color),
                title: Text(
                  value.text.trim().isEmpty
                      ? 'Category preview'
                      : value.text.trim(),
                ),
                subtitle: Text(_type.label),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_error case final error?) ...[
            AppErrorMessage(error),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (_uncertain)
            AppSecondaryButton(
              'Check refreshed list',
              onPressed: () => context.pop(true),
            )
          else
            AppPrimaryButton(
              widget.record == null ? 'Save category' : 'Save changes',
              busy: _busy,
              onPressed: _save,
            ),
          TextButton(
            onPressed: _busy ? null : () => context.pop(_uncertain),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
}

import '../../../core/network/api_client.dart';

enum CategoryType {
  income('INCOME', 'Income'),
  expense('EXPENSE', 'Expense');

  const CategoryType(this.code, this.label);
  final String code;
  final String label;

  static CategoryType parse(Object? code) => switch (code) {
    'INCOME' => income,
    'EXPENSE' => expense,
    _ => throw const FormatException('Invalid category type'),
  };
}

class CategoryRecord {
  const CategoryRecord({
    required this.id,
    required this.name,
    required this.type,
    required this.icon,
    required this.color,
    required this.isDefault,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CategoryRecord.fromJson(Map<String, dynamic> json) => CategoryRecord(
    id: json['id'] as String,
    name: json['name'] as String,
    type: CategoryType.parse(json['type']),
    icon: json['icon'] as String,
    color: json['color'] as String,
    isDefault: json['is_default'] as bool,
    isActive: json['is_active'] as bool,
    createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
    updatedAt: DateTime.parse(json['updated_at'] as String).toUtc(),
  );

  final String id, name, icon, color;
  final CategoryType type;
  final bool isDefault, isActive;
  final DateTime createdAt, updatedAt;
}

class CategoryDraft {
  const CategoryDraft(this.name, this.type, this.icon, this.color);
  final String name, icon, color;
  final CategoryType type;

  Map<String, String> toJson({required bool create}) => {
    'name': name,
    if (create) 'type': type.code,
    'icon': icon,
    'color': color,
  };
}

class CategoryPage {
  const CategoryPage(this.items, this.nextOffset);
  final List<CategoryRecord> items;
  final int? nextOffset;
}

class CategoryRepository {
  const CategoryRepository(this._api);
  final ApiClient _api;

  Future<CategoryPage> list(
    String access,
    CategoryType type,
    String search, {
    required bool archived,
    int offset = 0,
  }) async {
    final json = await _api.send(
      Endpoint.categories,
      bearer: access,
      query: {
        'type': type.code,
        'active': (!archived).toString(),
        if (search.isNotEmpty) 'q': search,
        'limit': '50',
        'offset': offset.toString(),
      },
    );
    return CategoryPage(
      (json['items'] as List)
          .map((item) => CategoryRecord.fromJson(item as Map<String, dynamic>))
          .toList(),
      json['next_offset'] as int?,
    );
  }

  Future<CategoryRecord> get(String access, String id) async =>
      CategoryRecord.fromJson(
        await _api.send(Endpoint.category, bearer: access, categoryId: id),
      );

  Future<CategoryRecord> save(
    String access,
    CategoryDraft draft, {
    String? id,
  }) async => CategoryRecord.fromJson(
    await _api.send(
      id == null ? Endpoint.createCategory : Endpoint.updateCategory,
      bearer: access,
      categoryId: id,
      body: draft.toJson(create: id == null),
    ),
  );

  Future<void> setActive(
    String access,
    String id, {
    required bool active,
  }) async {
    await _api.send(
      active ? Endpoint.restoreCategory : Endpoint.archiveCategory,
      bearer: access,
      categoryId: id,
    );
  }
}

import 'dart:math';

import '../../../core/network/api_client.dart';
import '../../wallets/data/wallet_repository.dart';

String calendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime colomboToday() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
  return DateTime(now.year, now.month, now.day);
}

bool validIncomeAmount(String input) =>
    validOpeningBalance(input) && input.contains(RegExp(r'[1-9]'));

String incomeOperationKey() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class IncomeRecord {
  IncomeRecord.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      title = json['title'] as String,
      rawAmount = json['amount'] as String,
      amount = parseWalletMoney(json['amount'] as String),
      date = DateTime.parse(json['income_date'] as String),
      note = json['note'] as String?,
      version = json['version'] as int,
      categoryId = json['category_id'] as String,
      categoryName = json['category_name'] as String,
      categoryIcon = json['category_icon'] as String,
      categoryColor = json['category_color'] as String,
      categoryActive = json['category_active'] as bool,
      walletId = json['wallet_id'] as String,
      walletName = json['wallet_name'] as String,
      walletActive = json['wallet_active'] as bool,
      created = DateTime.parse(json['created_at'] as String),
      updated = DateTime.parse(json['updated_at'] as String) {
    if (json['currency'] != 'LKR') {
      throw const FormatException('Invalid income currency');
    }
  }

  final String id,
      title,
      rawAmount,
      categoryId,
      categoryName,
      categoryIcon,
      categoryColor,
      walletId,
      walletName;
  final String? note;
  final BigInt amount;
  final DateTime date, created, updated;
  final int version;
  final bool categoryActive, walletActive;
}

typedef IncomeTotal = ({String name, BigInt amount});

class IncomeSummary {
  IncomeSummary.fromJson(Map<String, dynamic> json)
    : total = parseWalletMoney(json['total'] as String),
      count = json['count'] as int,
      categories = [
        for (final row in json['categories'] as List)
          (
            name: row['name'] as String,
            amount: parseWalletMoney(row['total'] as String),
          ),
      ] {
    if (json['currency'] != 'LKR') {
      throw const FormatException('Invalid income currency');
    }
  }

  final BigInt total;
  final int count;
  final List<IncomeTotal> categories;
}

typedef IncomePage = ({List<IncomeRecord> items, int? next});
typedef IncomeFilters = ({
  String search,
  String? category,
  String? wallet,
  DateTimeRangeValue? dates,
});
typedef DateTimeRangeValue = ({DateTime start, DateTime end});

typedef PendingIncome = ({String key, Map<String, Object?> draft});

class IncomeRepository {
  IncomeRepository(this.api);
  final ApiClient api;
  PendingIncome? pending;

  Future<IncomePage> list(
    String access,
    IncomeFilters filters,
    int offset,
  ) async {
    final data = await api.send(
      Endpoint.incomes,
      bearer: access,
      query: {
        if (filters.search.isNotEmpty) 'q': filters.search,
        'category_id': ?filters.category,
        'wallet_id': ?filters.wallet,
        if (filters.dates case final range?) ...{
          'date_from': calendarDate(range.start),
          'date_to': calendarDate(range.end),
        },
        'offset': '$offset',
        'limit': '50',
      },
    );
    return (
      items: [
        for (final row in data['items'] as List)
          IncomeRecord.fromJson(row as Map<String, dynamic>),
      ],
      next: data['next_offset'] as int?,
    );
  }

  Future<IncomeSummary> summary(String access, DateTime month) async =>
      IncomeSummary.fromJson(
        await api.send(
          Endpoint.incomeSummary,
          bearer: access,
          query: {'year': '${month.year}', 'month': '${month.month}'},
        ),
      );

  Future<IncomeRecord> get(String access, String id) async =>
      IncomeRecord.fromJson(
        await api.send(Endpoint.income, bearer: access, incomeId: id),
      );

  Future<void> create(
    String access,
    Map<String, Object?> draft,
    String key,
  ) async {
    await api.send(
      Endpoint.createIncome,
      bearer: access,
      idempotencyKey: key,
      body: {...draft, 'currency': 'LKR'},
    );
  }

  Future<void> edit(
    String access,
    IncomeRecord record,
    Map<String, Object?> draft,
  ) async {
    await api.send(
      Endpoint.updateIncome,
      bearer: access,
      incomeId: record.id,
      body: {...draft, 'expected_version': record.version},
    );
  }

  Future<void> delete(String access, IncomeRecord record) async {
    await api.send(
      Endpoint.deleteIncome,
      bearer: access,
      incomeId: record.id,
      expectedVersion: record.version,
    );
  }
}

import '../../../core/network/api_client.dart';

enum WalletType {
  cash('CASH', 'Cash'),
  bank('BANK', 'Bank'),
  digital('DIGITAL', 'Digital');

  const WalletType(this.code, this.label);
  final String code;
  final String label;

  static WalletType parse(Object? code) => values.firstWhere(
    (type) => type.code == code,
    orElse: () => throw const FormatException('Invalid wallet type'),
  );
}

final _amountInput = RegExp(r'^[0-9]{1,16}(\.[0-9]{1,2})?$');
final _amountResponse = RegExp(r'^[0-9]+\.[0-9]{2}$');

bool validOpeningBalance(String value) =>
    _amountInput.matchAsPrefix(value)?.end == value.length;

BigInt parseWalletMoney(String value) {
  if (_amountResponse.matchAsPrefix(value)?.end != value.length) {
    throw const FormatException('Invalid wallet balance');
  }
  return BigInt.parse(value.replaceFirst('.', ''));
}

String walletMoney(BigInt minorUnits) {
  final digits = minorUnits.toString().padLeft(3, '0');
  final parts = <String>[];
  var end = digits.length - 2;
  final fraction = digits.substring(end);
  while (end > 3) {
    parts.add(digits.substring(end - 3, end));
    end -= 3;
  }
  parts.add(digits.substring(0, end));
  return 'LKR ${parts.reversed.join(',')}.$fraction';
}

void _requireLkr(Object? currency) {
  if (currency != 'LKR') throw const FormatException('Invalid wallet currency');
}

class WalletRecord {
  WalletRecord.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      type = WalletType.parse(json['type']),
      opening = parseWalletMoney(json['opening_balance'] as String),
      current = parseWalletMoney(json['current_balance'] as String),
      icon = json['icon'] as String,
      color = json['color'] as String,
      active = json['is_active'] as bool,
      createdAt = DateTime.parse(json['created_at'] as String),
      updatedAt = DateTime.parse(json['updated_at'] as String) {
    _requireLkr(json['currency']);
  }
  final String id, name, icon, color;
  final WalletType type;
  final BigInt opening, current;
  final bool active;
  final DateTime createdAt, updatedAt;
}

class WalletSummary {
  WalletSummary.fromJson(Map<String, dynamic> json)
    : total = parseWalletMoney(json['total_active_balance'] as String),
      activeCount = json['active_count'] as int,
      archivedCount = json['archived_count'] as int,
      breakdown = {
        for (final type in WalletType.values)
          type: parseWalletMoney(
            (json['balances_by_type'] as Map)[type.code] as String,
          ),
      } {
    _requireLkr(json['currency']);
  }
  final BigInt total;
  final int activeCount, archivedCount;
  final Map<WalletType, BigInt> breakdown;
}

typedef WalletPage = ({List<WalletRecord> items, int? next});
typedef WalletDraft = ({
  String name,
  WalletType type,
  String amount,
  String icon,
  String color,
});

class WalletRepository {
  const WalletRepository(this.api);
  final ApiClient api;

  Future<WalletPage> list(
    String access, {
    WalletType? type,
    required bool archived,
    required String search,
    required int offset,
  }) async {
    final data = await api.send(
      Endpoint.wallets,
      bearer: access,
      query: {
        if (type != null) 'type': type.code,
        if (search.isNotEmpty) 'q': search,
        'active': (!archived).toString(),
        'offset': '$offset',
        'limit': '50',
      },
    );
    return (
      items: (data['items'] as List)
          .map((item) => WalletRecord.fromJson(item as Map<String, dynamic>))
          .toList(),
      next: data['next_offset'] as int?,
    );
  }

  Future<WalletSummary> summary(String access) async => WalletSummary.fromJson(
    await api.send(Endpoint.walletSummary, bearer: access),
  );

  Future<WalletRecord> get(String access, String id) async =>
      WalletRecord.fromJson(
        await api.send(Endpoint.wallet, bearer: access, walletId: id),
      );

  Future<void> save(String access, WalletDraft draft, {String? id}) async {
    await api.send(
      id == null ? Endpoint.createWallet : Endpoint.updateWallet,
      bearer: access,
      walletId: id,
      body: {
        'name': draft.name,
        'icon': draft.icon,
        'color': draft.color,
        if (id == null) ...{
          'type': draft.type.code,
          'currency': 'LKR',
          'opening_balance': draft.amount,
        },
      },
    );
  }

  Future<void> setActive(
    String access,
    String id, {
    required bool active,
  }) async {
    await api.send(
      active ? Endpoint.restoreWallet : Endpoint.archiveWallet,
      bearer: access,
      walletId: id,
    );
  }
}

import '../../../core/network/api_client.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../incomes/data/income_repository.dart'
    show DateTimeRangeValue, calendarDate;
import '../../wallets/data/wallet_repository.dart';

enum TransferStatus {
  original('Original transfer'),
  reversed('Reversed'),
  reversal('Compensating reversal');

  const TransferStatus(this.label);
  final String label;
}

class TransferWallet {
  TransferWallet.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      icon = json['icon'] as String,
      color = json['color'] as String,
      active = json['is_active'] as bool;

  final String id, name, icon, color;
  final bool active;
}

class TransferRecord {
  TransferRecord.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      source = TransferWallet.fromJson(
        json['source_wallet'] as Map<String, dynamic>,
      ),
      destination = TransferWallet.fromJson(
        json['destination_wallet'] as Map<String, dynamic>,
      ),
      amount = parseWalletMoney(json['amount'] as String),
      date = DateTime.parse(json['transfer_date'] as String),
      created = DateTime.parse(json['created_at'] as String),
      note = json['note'] as String?,
      reversalOf = json['reversal_of_id'] as String?,
      reversal = json['reversal_id'] as String?,
      status = TransferStatus.values.byName(json['status'] as String) {
    if (json['currency'] != 'LKR') {
      throw const FormatException('Invalid transfer currency');
    }
  }

  final String id;
  final TransferWallet source, destination;
  final BigInt amount;
  final DateTime date, created;
  final String? note, reversalOf, reversal;
  final TransferStatus status;
}

typedef TransferPage = ({List<TransferRecord> items, int? next});
typedef PendingTransfer = ({
  String key,
  Map<String, Object?> body,
  String? originalId,
});
typedef TransferFilters = ({
  String search,
  String? wallet,
  String? kind,
  DateTimeRangeValue? dates,
});

class TransferRepository {
  TransferRepository(this.api, this.wallets);
  final ApiClient api;
  final WalletRepository wallets;
  PendingTransfer? pendingCreation;
  final pendingReversals = <String, PendingTransfer>{};

  void clearPending() {
    pendingCreation = null;
    pendingReversals.clear();
  }

  Future<List<WalletRecord>> walletOptions(
    AuthController auth, {
    bool archived = false,
  }) async {
    final items = <WalletRecord>[];
    for (final archived in [false, if (archived) true]) {
      int? offset = 0;
      while (offset != null) {
        final nextOffset = offset;
        final page = await auth.authenticatedRead(
          (access) => wallets.list(
            access,
            archived: archived,
            search: '',
            offset: nextOffset,
          ),
        );
        items.addAll(page.items);
        offset = page.next;
      }
    }
    return items;
  }

  Future<TransferPage> list(
    String access,
    TransferFilters filters,
    int offset,
  ) async {
    final json = await api.send(
      Endpoint.transfers,
      bearer: access,
      query: {
        if (filters.search.isNotEmpty) 'q': filters.search,
        'wallet_id': ?filters.wallet,
        'kind': ?filters.kind,
        if (filters.dates case final dates?) ...{
          'date_from': calendarDate(dates.start),
          'date_to': calendarDate(dates.end),
        },
        'offset': '$offset',
        'limit': '50',
      },
    );
    return (
      items: [
        for (final row in json['items'] as List)
          TransferRecord.fromJson(row as Map<String, dynamic>),
      ],
      next: json['next_offset'] as int?,
    );
  }

  Future<TransferRecord> get(String access, String id) async =>
      TransferRecord.fromJson(
        await api.send(Endpoint.transfer, bearer: access, transferId: id),
      );

  Future<void> submit(String access, PendingTransfer operation) async {
    await api.send(
      operation.originalId == null
          ? Endpoint.createTransfer
          : Endpoint.reverseTransfer,
      bearer: access,
      transferId: operation.originalId,
      idempotencyKey: operation.key,
      body: operation.body,
    );
  }
}

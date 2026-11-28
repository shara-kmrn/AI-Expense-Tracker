from datetime import datetime
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import select

from app.auth.errors import AuthError
from app.financial import service as financial
from app.incomes.schemas import COLOMBO
from app.transfers import repository
from app.transfers.models import TransferReplay, WalletTransfer
from app.transfers.schemas import TransferResponse


def _record(db, owner, identity, *, source_id, destination_id, amount, currency,
            transfer_date, note, reversal_of_id=None):
    wallets = financial.lock_wallets(db, owner, {source_id, destination_id})
    source, destination = wallets[source_id], wallets[destination_id]
    for wallet in (source, destination):
        financial.check_wallet(wallet, currency, "Transfer", require_active=True)
    debit = financial.balance_after(source, amount.copy_negate())
    credit = financial.balance_after(destination, amount)
    source.current_balance = debit
    destination.current_balance = credit
    record = WalletTransfer(
        id=uuid4(), user_id=owner, source_wallet_id=source_id,
        destination_wallet_id=destination_id, amount=amount, currency=currency,
        transfer_date=transfer_date, note=note, reversal_of_id=reversal_of_id,
    )
    db.add(record)
    db.flush()
    result = repository.view(record, source, destination)
    financial.persist_replay(db, TransferReplay, identity, result)
    db.commit()
    return result


def create(db, owner, key, data):
    financial.lock_owner(db, owner, "Transfer")
    identity = dict(user_id=owner, operation="create", key=key)
    previous = financial.claim_replay(db, TransferReplay, identity, data.model_dump(mode="json"))
    if previous is not None:
        return TransferResponse.model_validate(previous)
    return _record(
        db, owner, identity, source_id=data.source_wallet_id, destination_id=data.destination_wallet_id,
        amount=Decimal(data.amount), currency=data.currency, transfer_date=data.transfer_date, note=data.note,
    )


def reverse(db, owner, key, original_id, data):
    financial.lock_owner(db, owner, "Transfer")
    identity = dict(user_id=owner, operation="reverse", key=key)
    previous = financial.claim_replay(db, TransferReplay, identity, {
        "original_id": str(original_id), "note": data.note,
    })
    if previous is not None:
        return TransferResponse.model_validate(previous)
    original = db.scalar(select(WalletTransfer).where(
        WalletTransfer.user_id == owner, WalletTransfer.id == original_id,
    ).with_for_update())
    if original is None:
        raise AuthError(404, "Transfer not found")
    if original.reversal_of_id is not None:
        raise AuthError(409, "A reversal cannot be reversed")
    if repository.has_reversal(db, owner, original_id):
        raise AuthError(409, "Transfer already reversed")
    return _record(
        db, owner, identity, source_id=original.destination_wallet_id, destination_id=original.source_wallet_id,
        amount=original.amount, currency=original.currency, transfer_date=datetime.now(COLOMBO).date(),
        note=data.note, reversal_of_id=original_id,
    )

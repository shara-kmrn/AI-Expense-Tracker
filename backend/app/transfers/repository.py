from sqlalchemy import and_, or_, select
from sqlalchemy.orm import aliased

from app.transfers.models import WalletTransfer
from app.transfers.schemas import TransferResponse, TransferWallet
from app.wallets.models import Wallet


def has_reversal(db, owner, original):
    return db.scalar(select(WalletTransfer.id).where(
        WalletTransfer.user_id == owner, WalletTransfer.reversal_of_id == original,
    )) is not None


def view(record, source, destination, reversal_id=None):
    status = "original"
    if record.reversal_of_id is not None:
        status = "reversal"
    elif reversal_id is not None:
        status = "reversed"

    return TransferResponse(
        id=record.id, source_wallet=TransferWallet.model_validate(source),
        destination_wallet=TransferWallet.model_validate(destination),
        amount=record.amount, currency=record.currency, transfer_date=record.transfer_date,
        note=record.note, created_at=record.created_at, reversal_of_id=record.reversal_of_id,
        reversal_id=reversal_id, status=status,
    )


def _owned(owner):
    source, destination, reversal = aliased(Wallet), aliased(Wallet), aliased(WalletTransfer)
    model = WalletTransfer
    query = (
        select(model, source, destination, reversal.id)
        .join(source, and_(source.id == model.source_wallet_id, source.user_id == model.user_id))
        .join(destination, and_(destination.id == model.destination_wallet_id, destination.user_id == model.user_id))
        .outerjoin(reversal, and_(reversal.reversal_of_id == model.id, reversal.user_id == model.user_id))
        .where(model.user_id == owner)
    )
    return query, source, destination


def get(db, owner, transfer_id):
    query, _, _ = _owned(owner)
    row = db.execute(query.where(WalletTransfer.id == transfer_id)).one_or_none()
    return view(*row) if row else None


def history(db, owner, *, date_from, date_to, wallet_id, source_wallet_id,
            destination_wallet_id, kind, search, limit, offset):
    query, source, destination = _owned(owner)
    model = WalletTransfer
    for predicate in (
        model.transfer_date >= date_from if date_from is not None else None,
        model.transfer_date <= date_to if date_to is not None else None,
        or_(model.source_wallet_id == wallet_id, model.destination_wallet_id == wallet_id) if wallet_id else None,
        model.source_wallet_id == source_wallet_id if source_wallet_id else None,
        model.destination_wallet_id == destination_wallet_id if destination_wallet_id else None,
        model.reversal_of_id.is_(None) if kind == "original" else None,
        model.reversal_of_id.is_not(None) if kind == "reversal" else None,
        or_(model.note.icontains(search, autoescape=True), source.name.icontains(search, autoescape=True),
            destination.name.icontains(search, autoescape=True)) if search else None,
    ):
        if predicate is not None:
            query = query.where(predicate)
    return db.execute(query.order_by(
        model.transfer_date.desc(), model.created_at.desc(), model.id.desc(),
    ).limit(limit + 1).offset(offset)).all()

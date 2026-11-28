from decimal import Decimal
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.categories.schemas import name_key
from app.wallets.models import Wallet
from app.wallets.schemas import WalletSummary, WalletType


def owned_wallet(db: Session, owner: UUID, wallet_id: UUID, *, lock: bool = False):
    query = select(Wallet).where(Wallet.user_id == owner, Wallet.id == wallet_id)
    return db.scalar(query.with_for_update() if lock else query)


def list_wallets(db: Session, owner: UUID, *, kind: WalletType | None,
                 search: str | None, active: bool, limit: int, offset: int):
    query = select(Wallet).where(Wallet.user_id == owner, Wallet.is_active == active)
    if kind is not None:
        query = query.where(Wallet.type == kind.value)
    if search is not None:
        query = query.where(Wallet.normalized_name.contains(name_key(search), autoescape=True))
    return db.scalars(query.order_by(Wallet.normalized_name, Wallet.id).limit(limit + 1).offset(offset)).all()


def summarize(db: Session, owner: UUID) -> WalletSummary:
    active_balance = func.coalesce(func.sum(Wallet.current_balance).filter(Wallet.is_active), 0)
    breakdown = {kind: Decimal(0) for kind in WalletType}
    rows = db.execute(select(
        Wallet.type,
        active_balance,
        func.count().filter(Wallet.is_active),
        func.count().filter(~Wallet.is_active),
        func.sum(active_balance).over(),
    ).where(Wallet.user_id == owner).group_by(Wallet.type)).all()
    for kind, balance, _, _, _ in rows:
        breakdown[WalletType(kind)] = balance
    return WalletSummary(
        total_active_balance=rows[0][4] if rows else Decimal(0),
        active_count=sum(row[2] for row in rows),
        archived_count=sum(row[3] for row in rows),
        balances_by_type=breakdown,
    )

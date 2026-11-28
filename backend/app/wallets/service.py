from decimal import Decimal
from uuid import UUID, uuid4

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth.errors import AuthError
from app.categories.schemas import name_key
from app.wallets.models import Wallet
from app.wallets.repository import owned_wallet
from app.wallets.schemas import WalletCreate, WalletResponse, WalletUpdate


def get(db: Session, owner: UUID, wallet_id: UUID, *, lock: bool = False) -> Wallet:
    wallet = owned_wallet(db, owner, wallet_id, lock=lock)
    if wallet is None:
        raise AuthError(404, "Wallet not found")
    return wallet


def save(db: Session, wallet: Wallet) -> WalletResponse:
    try:
        db.flush()
        result = WalletResponse.model_validate(wallet)
        db.commit()
    except IntegrityError as error:
        db.rollback()
        if getattr(getattr(error.orig, "diag", None), "constraint_name", None) == "uq_wallets_owner_name":
            raise AuthError(409, "Wallet name is already reserved") from None
        raise
    return result


def create(db: Session, owner: UUID, data: WalletCreate) -> WalletResponse:
    opening = Decimal(data.opening_balance)
    wallet = Wallet(id=uuid4(), user_id=owner, name=data.name, normalized_name=name_key(data.name),
                    type=data.type.value, currency=data.currency, opening_balance=opening,
                    current_balance=opening, icon=data.icon, color=data.color)
    db.add(wallet)
    return save(db, wallet)


def update(db: Session, owner: UUID, wallet_id: UUID, data: WalletUpdate) -> WalletResponse:
    wallet = get(db, owner, wallet_id, lock=True)
    if not wallet.is_active:
        raise AuthError(409, "Restore this wallet before editing")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(wallet, field, value)
    if data.name is not None:
        wallet.normalized_name = name_key(data.name)
    return save(db, wallet)


def change_active(db: Session, owner: UUID, wallet_id: UUID, active: bool) -> WalletResponse:
    wallet = get(db, owner, wallet_id, lock=True)
    if not active and wallet.current_balance != 0:
        raise AuthError(409, "Wallet balance must be zero before archiving")
    wallet.is_active = active
    return save(db, wallet)

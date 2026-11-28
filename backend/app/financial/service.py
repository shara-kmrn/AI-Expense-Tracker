import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal, localcontext
from uuid import uuid4
from collections.abc import Callable

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert

from app.auth.errors import AuthError
from app.auth.models import User
from app.categories.models import Category
from app.wallets.models import Wallet

MAX_BALANCE = Decimal("9999999999999999.99")


@dataclass(frozen=True)
class FinancialOperation:
    label: str
    direction: int
    record: type
    replay: type
    response: type
    view: Callable


def lock_owner(db, owner, label):
    # Account deletion locks the same user before cascading into financial rows.
    user = db.scalar(select(User.id).where(User.id == owner).with_for_update(read=True, key_share=True))
    if user is None:
        raise AuthError(404, f"{label} not found")


def lock_record(db, owner, record_id, operation):
    model = operation.record
    record = db.scalar(select(model).where(
        model.user_id == owner, model.id == record_id,
    ).with_for_update())
    if record is None:
        raise AuthError(404, f"{operation.label} not found")
    return record


def check_version(record, expected, operation):
    if record.version != expected:
        raise AuthError(409, f"{operation.label} changed. Reload it before continuing.")
    if record.version == 2_147_483_647:
        raise AuthError(409, f"{operation.label} version limit reached")


def lock_wallets(db, owner, ids):
    wallets = {row.id: row for row in db.scalars(select(Wallet).where(
        Wallet.user_id == owner, Wallet.id.in_(ids),
    ).order_by(Wallet.id).with_for_update())}
    if len(wallets) != len(ids):
        raise AuthError(404, "Wallet not found")
    return wallets


def lock_category(db, owner, category_id, operation, *, require_active):
    category = db.scalar(select(Category).where(
        Category.user_id == owner, Category.id == category_id,
    ).with_for_update(read=True))
    if category is None:
        raise AuthError(404, "Category not found")
    if category.type != operation.label.upper() or (require_active and not category.is_active):
        raise AuthError(409, f"Select an active {operation.label.lower()} category")
    return category


def check_wallet(wallet, currency, label, *, require_active):
    if wallet.currency != currency:
        raise AuthError(409, f"{label} and wallet currencies must match")
    if require_active and not wallet.is_active:
        raise AuthError(409, "Select an active wallet")


def balance_after(wallet, delta, *, insufficient="Insufficient wallet balance"):
    with localcontext() as context:
        context.prec = 24
        balance = wallet.current_balance + delta
    if balance < 0:
        raise AuthError(409, insufficient)
    if balance > MAX_BALANCE:
        raise AuthError(409, "Wallet balance would exceed its maximum")
    if not wallet.is_active and balance != 0:
        raise AuthError(409, "Restore the wallet before changing its balance")
    return balance


def adjust(wallet, delta, operation):
    wallet.current_balance = balance_after(
        wallet, delta, insufficient="Insufficient wallet balance" if operation.direction == -1
        else "Wallet balance is too low to reverse this income",
    )


def claim_replay(db, replay, identity, fields):
    if "amount" in fields:
        fields = {**fields, "amount": format(Decimal(fields["amount"]), ".2f")}
    fingerprint = hashlib.sha256(json.dumps(
        fields, sort_keys=True, ensure_ascii=False, separators=(",", ":"),
    ).encode()).hexdigest()
    claimed = db.scalar(insert(replay).values(
        **identity, fingerprint=fingerprint, response={},
    ).on_conflict_do_nothing().returning(replay.key))
    if claimed is None:
        previous = db.get(replay, identity)
        if previous.fingerprint != fingerprint:
            raise AuthError(409, "This operation key already belongs to a different request")
        return previous.response
    return None


def persist_replay(db, replay, identity, result):
    db.execute(update(replay).where(
        *(getattr(replay, key) == value for key, value in identity.items())
    ).values(response=result.model_dump(mode="json")))


def create(db, owner, key, data, operation):
    lock_owner(db, owner, operation.label)
    identity = {"user_id": owner, "key": key}
    previous = claim_replay(db, operation.replay, identity, data.model_dump(mode="json"))
    if previous is not None:
        return operation.response.model_validate(previous)
    amount = Decimal(data.amount)
    wallet = lock_wallets(db, owner, {data.wallet_id})[data.wallet_id]
    category = lock_category(db, owner, data.category_id, operation, require_active=True)
    check_wallet(wallet, data.currency, operation.label, require_active=True)
    adjust(wallet, operation.direction * amount, operation)
    record = operation.record(**data.model_dump(exclude={"amount"}), id=uuid4(), user_id=owner, amount=amount)
    db.add(record)
    db.flush()
    result = operation.view(record, wallet, category)
    persist_replay(db, operation.replay, identity, result)
    db.commit()
    return result


def edit(db, owner, record_id, data, operation):
    lock_owner(db, owner, operation.label)
    record = lock_record(db, owner, record_id, operation)
    if record.deleted_at is not None:
        raise AuthError(404, f"{operation.label} not found")
    check_version(record, data.expected_version, operation)
    changes = data.model_dump(exclude_unset=True, exclude={"expected_version", "amount"})
    wallet_id = data.wallet_id or record.wallet_id
    category_id = data.category_id or record.category_id
    amount = Decimal(data.amount) if data.amount is not None else record.amount
    wallets = lock_wallets(db, owner, {record.wallet_id, wallet_id})
    wallet = wallets[wallet_id]
    moved = wallet_id != record.wallet_id
    category = lock_category(db, owner, category_id, operation, require_active=category_id != record.category_id)
    check_wallet(wallet, record.currency, operation.label, require_active=moved)
    if moved:
        adjust(wallets[record.wallet_id], -operation.direction * record.amount, operation)
        adjust(wallet, operation.direction * amount, operation)
    elif amount != record.amount:
        with localcontext() as context:
            context.prec = 24
            adjust(wallet, operation.direction * (amount - record.amount), operation)
    for field, value in changes.items():
        setattr(record, field, value)
    record.amount = amount
    record.version += 1
    db.flush()
    result = operation.view(record, wallet, category)
    db.commit()
    return result


def delete(db, owner, record_id, expected, operation):
    lock_owner(db, owner, operation.label)
    record = lock_record(db, owner, record_id, operation)
    if record.deleted_at is not None:
        return
    check_version(record, expected, operation)
    wallet = lock_wallets(db, owner, {record.wallet_id})[record.wallet_id]
    adjust(wallet, -operation.direction * record.amount, operation)
    record.deleted_at = datetime.now(UTC)
    record.version += 1
    db.commit()

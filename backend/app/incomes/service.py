import hashlib
import json
from datetime import UTC, datetime
from decimal import Decimal, localcontext
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert

from app.auth.errors import AuthError
from app.auth.models import User
from app.categories.models import Category
from app.incomes.models import Income, IncomeCreation
from app.incomes.repository import view
from app.incomes.schemas import IncomeResponse
from app.wallets.models import Wallet

MAX_BALANCE = Decimal("9999999999999999.99")


def lock_owner(db, owner):
    # Account deletion locks the same user before cascading into financial rows.
    user = db.scalar(select(User.id).where(User.id == owner).with_for_update(read=True, key_share=True))
    if user is None:
        raise AuthError(404, "Income not found")


def lock_income(db, owner, income_id):
    income = db.scalar(select(Income).where(
        Income.user_id == owner, Income.id == income_id,
    ).with_for_update())
    if income is None:
        raise AuthError(404, "Income not found")
    return income


def check_version(income, expected):
    if income.version != expected:
        raise AuthError(409, "Income changed. Reload it before continuing.")
    if income.version == 2_147_483_647:
        raise AuthError(409, "Income version limit reached")


def lock_wallets(db, owner, ids):
    wallets = {row.id: row for row in db.scalars(select(Wallet).where(
        Wallet.user_id == owner, Wallet.id.in_(ids),
    ).order_by(Wallet.id).with_for_update())}
    if len(wallets) != len(ids):
        raise AuthError(404, "Wallet not found")
    return wallets


def lock_category(db, owner, category_id, *, require_active):
    category = db.scalar(select(Category).where(
        Category.user_id == owner, Category.id == category_id,
    ).with_for_update(read=True))
    if category is None:
        raise AuthError(404, "Category not found")
    if category.type != "INCOME" or (require_active and not category.is_active):
        raise AuthError(409, "Select an active income category")
    return category


def check_wallet(wallet, currency, *, require_active):
    if wallet.currency != currency:
        raise AuthError(409, "Income and wallet currencies must match")
    if require_active and not wallet.is_active:
        raise AuthError(409, "Select an active wallet")


def adjust(wallet, delta):
    with localcontext() as context:
        context.prec = 24
        balance = wallet.current_balance + delta
    if balance < 0:
        raise AuthError(409, "Wallet balance is too low to reverse this income")
    if balance > MAX_BALANCE:
        raise AuthError(409, "Wallet balance would exceed its maximum")
    if not wallet.is_active and balance != 0:
        raise AuthError(409, "Restore the wallet before changing its balance")
    wallet.current_balance = balance


def create(db, owner, key, data):
    lock_owner(db, owner)
    fields = data.model_dump(mode="json")
    amount = Decimal(data.amount)
    fields["amount"] = format(amount, ".2f")
    fingerprint = hashlib.sha256(json.dumps(
        fields, sort_keys=True, ensure_ascii=False, separators=(",", ":"),
    ).encode()).hexdigest()
    claimed = db.scalar(insert(IncomeCreation).values(
        user_id=owner, key=key, fingerprint=fingerprint, response={},
    ).on_conflict_do_nothing().returning(IncomeCreation.key))
    if claimed is None:
        previous = db.get(IncomeCreation, (owner, key))
        if previous.fingerprint != fingerprint:
            raise AuthError(409, "This operation key already belongs to a different request")
        return IncomeResponse.model_validate(previous.response)
    wallet = lock_wallets(db, owner, {data.wallet_id})[data.wallet_id]
    category = lock_category(db, owner, data.category_id, require_active=True)
    check_wallet(wallet, data.currency, require_active=True)
    adjust(wallet, amount)
    income = Income(**data.model_dump(exclude={"amount"}), id=uuid4(), user_id=owner, amount=amount)
    db.add(income)
    db.flush()
    result = view(income, wallet, category)
    db.execute(update(IncomeCreation).where(
        IncomeCreation.user_id == owner, IncomeCreation.key == key,
    ).values(response=result.model_dump(mode="json")))
    db.commit()
    return result


def edit(db, owner, income_id, data):
    lock_owner(db, owner)
    income = lock_income(db, owner, income_id)
    if income.deleted_at is not None:
        raise AuthError(404, "Income not found")
    check_version(income, data.expected_version)
    changes = data.model_dump(exclude_unset=True, exclude={"expected_version", "amount"})
    wallet_id = data.wallet_id or income.wallet_id
    category_id = data.category_id or income.category_id
    amount = Decimal(data.amount) if data.amount is not None else income.amount
    wallets = lock_wallets(db, owner, {income.wallet_id, wallet_id})
    wallet = wallets[wallet_id]
    moved = wallet_id != income.wallet_id
    category = lock_category(db, owner, category_id, require_active=category_id != income.category_id)
    check_wallet(wallet, income.currency, require_active=moved)
    if moved:
        adjust(wallets[income.wallet_id], -income.amount)
        adjust(wallet, amount)
    elif amount != income.amount:
        with localcontext() as context:
            context.prec = 24
            adjust(wallet, amount - income.amount)
    for field, value in changes.items():
        setattr(income, field, value)
    income.amount = amount
    income.version += 1
    db.flush()
    result = view(income, wallet, category)
    db.commit()
    return result


def delete(db, owner, income_id, expected):
    lock_owner(db, owner)
    income = lock_income(db, owner, income_id)
    if income.deleted_at is not None:
        return
    check_version(income, expected)
    wallet = lock_wallets(db, owner, {income.wallet_id})[income.wallet_id]
    adjust(wallet, -income.amount)
    income.deleted_at = datetime.now(UTC)
    income.version += 1
    db.commit()

from calendar import monthrange
from datetime import date
from decimal import Decimal
from uuid import UUID

from sqlalchemy import and_, func, or_, select

from app.categories.models import Category
from app.incomes.models import Income
from app.incomes.schemas import CategoryTotal, IncomeResponse, IncomeSummary
from app.wallets.models import Wallet


def view(income, wallet, category):
    return IncomeResponse(
        id=income.id, title=income.title, amount=income.amount, currency=income.currency,
        note=income.note, income_date=income.income_date, category_id=category.id,
        category_name=category.name, category_icon=category.icon, category_color=category.color,
        category_active=category.is_active, wallet_id=wallet.id, wallet_name=wallet.name,
        wallet_active=wallet.is_active, version=income.version,
        created_at=income.created_at, updated_at=income.updated_at,
    )


def visible(owner: UUID):
    return select(Income, Wallet, Category).join(
        Wallet, and_(Income.user_id == Wallet.user_id, Income.wallet_id == Wallet.id),
    ).join(
        Category, and_(Income.user_id == Category.user_id, Income.category_id == Category.id),
    ).where(Income.user_id == owner, Income.deleted_at.is_(None))


def history(db, owner, *, date_from, date_to, category_id, wallet_id, search, limit, offset):
    query = visible(owner)
    for predicate in (
        Income.income_date >= date_from if date_from is not None else None,
        Income.income_date <= date_to if date_to is not None else None,
        Income.category_id == category_id if category_id is not None else None,
        Income.wallet_id == wallet_id if wallet_id is not None else None,
        or_(Income.title.icontains(search, autoescape=True),
            Income.note.icontains(search, autoescape=True)) if search else None,
    ):
        if predicate is not None:
            query = query.where(predicate)
    return db.execute(query.order_by(
        Income.income_date.desc(), Income.created_at.desc(), Income.id.desc(),
    ).offset(offset).limit(limit + 1)).all()


def summarize(db, owner, year, month):
    amount = func.sum(Income.amount)
    rows = db.execute(select(
        Category.id, Category.name, amount, func.count(), func.sum(amount).over(),
    ).join(
        Income, and_(Income.user_id == Category.user_id, Income.category_id == Category.id),
    ).where(
        Income.user_id == owner, Income.deleted_at.is_(None),
        Income.income_date.between(date(year, month, 1), date(year, month, monthrange(year, month)[1])),
    ).group_by(Category.id, Category.name).order_by(Category.name, Category.id)).all()
    return IncomeSummary(
        year=year, month=month, total=rows[0][4] if rows else Decimal(0),
        count=sum(row[3] for row in rows),
        categories=[CategoryTotal(category_id=row[0], name=row[1], total=row[2]) for row in rows],
    )

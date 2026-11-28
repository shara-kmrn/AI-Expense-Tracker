from calendar import monthrange
from datetime import date
from decimal import Decimal
from uuid import UUID

from sqlalchemy import and_, func, or_, select

from app.categories.models import Category
from app.incomes.models import Income
from app.incomes.schemas import CategoryTotal, IncomeResponse, IncomeSummary
from app.wallets.models import Wallet


def view_record(income, wallet, category, response, **date_field):
    return response(
        id=income.id, title=income.title, amount=income.amount, currency=income.currency,
        note=income.note, category_id=category.id, **date_field,
        category_name=category.name, category_icon=category.icon, category_color=category.color,
        category_active=category.is_active, wallet_id=wallet.id, wallet_name=wallet.name,
        wallet_active=wallet.is_active, version=income.version,
        created_at=income.created_at, updated_at=income.updated_at,
    )


def view(income, wallet, category):
    return view_record(income, wallet, category, IncomeResponse, income_date=income.income_date)


def visible(owner: UUID, model=Income):
    return select(model, Wallet, Category).join(
        Wallet, and_(model.user_id == Wallet.user_id, model.wallet_id == Wallet.id),
    ).join(
        Category, and_(model.user_id == Category.user_id, model.category_id == Category.id),
    ).where(model.user_id == owner, model.deleted_at.is_(None))


def history(db, owner, *, date_from, date_to, category_id, wallet_id, search, limit, offset,
            model=Income, date_column=Income.income_date):
    query = visible(owner, model)
    for predicate in (
        date_column >= date_from if date_from is not None else None,
        date_column <= date_to if date_to is not None else None,
        model.category_id == category_id if category_id is not None else None,
        model.wallet_id == wallet_id if wallet_id is not None else None,
        or_(model.title.icontains(search, autoescape=True),
            model.note.icontains(search, autoescape=True)) if search else None,
    ):
        if predicate is not None:
            query = query.where(predicate)
    return db.execute(query.order_by(
        date_column.desc(), model.created_at.desc(), model.id.desc(),
    ).offset(offset).limit(limit + 1)).all()


def period_rows(db, owner, start, end, model, date_column):
    amount = func.sum(model.amount)
    return db.execute(select(
        Category.id, Category.name, amount, func.count(), func.sum(amount).over(),
    ).join(
        model, and_(model.user_id == Category.user_id, model.category_id == Category.id),
    ).where(
        model.user_id == owner, model.deleted_at.is_(None),
        date_column.between(start, end),
    ).group_by(Category.id, Category.name).order_by(Category.name, Category.id)).all()


def summary_totals(rows):
    return dict(total=rows[0][4] if rows else Decimal(0),
                count=sum(row[3] for row in rows),
                categories=[CategoryTotal(category_id=row[0], name=row[1], total=row[2]) for row in rows])


def summarize(db, owner, year, month):
    rows = period_rows(db, owner, date(year, month, 1), date(year, month, monthrange(year, month)[1]),
                       Income, Income.income_date)
    return IncomeSummary(year=year, month=month, **summary_totals(rows))

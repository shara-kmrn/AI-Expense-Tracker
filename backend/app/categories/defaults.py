"""Version 1 seed definitions. Future migrations should add a new version."""

DEFAULTS_V1 = (
    ("salary", "INCOME", "Salary", "work", "#E8D5A3"),
    ("freelance", "INCOME", "Freelance", "laptop", "#C4B5FD"),
    ("business", "INCOME", "Business", "store", "#FBBF24"),
    ("investments", "INCOME", "Investments", "trending_up", "#4ADE80"),
    ("gifts", "INCOME", "Gifts", "gift", "#F9A8D4"),
    ("other_income", "INCOME", "Other Income", "wallet", "#D4AF37"),
    ("food", "EXPENSE", "Food & Dining", "restaurant", "#FDBA74"),
    ("transport", "EXPENSE", "Transport", "car", "#93C5FD"),
    ("shopping", "EXPENSE", "Shopping", "shopping_bag", "#F9A8D4"),
    ("housing", "EXPENSE", "Housing", "home", "#E8D5A3"),
    ("utilities", "EXPENSE", "Bills & Utilities", "bolt", "#FBBF24"),
    ("education", "EXPENSE", "Education", "graduation_cap", "#C4B5FD"),
    ("healthcare", "EXPENSE", "Healthcare", "medical", "#FCA5A5"),
    ("entertainment", "EXPENSE", "Entertainment", "movie", "#F9A8D4"),
    ("travel", "EXPENSE", "Travel", "flight", "#A5F3FC"),
    ("other_expenses", "EXPENSE", "Other Expenses", "category", "#D4AF37"),
)

ICONS_V1 = frozenset(icon for _, _, _, icon, _ in DEFAULTS_V1)


def seed_rows_v1():
    for code, kind, name, icon, color in DEFAULTS_V1:
        yield dict(default_code=code, type=kind, name=name, normalized_name=name.casefold(),
                   icon=icon, color=color)

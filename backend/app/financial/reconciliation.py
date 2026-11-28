from sqlalchemy import text

WALLET_DISCREPANCIES = text("""
    WITH credits AS (
        SELECT user_id, wallet_id, sum(amount) AS total
        FROM incomes WHERE deleted_at IS NULL GROUP BY user_id, wallet_id
    ), debits AS (
        SELECT user_id, wallet_id, sum(amount) AS total
        FROM expenses WHERE deleted_at IS NULL GROUP BY user_id, wallet_id
    )
    SELECT count(*)
    FROM wallets w
    LEFT JOIN credits i ON i.user_id = w.user_id AND i.wallet_id = w.id
    LEFT JOIN debits e ON e.user_id = w.user_id AND e.wallet_id = w.id
    WHERE w.current_balance <> w.opening_balance + coalesce(i.total, 0) - coalesce(e.total, 0)
""")


def wallet_discrepancies(connection):
    return connection.scalar(WALLET_DISCREPANCIES)

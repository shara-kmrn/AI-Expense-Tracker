from sqlalchemy import text

WALLET_DISCREPANCIES = text("""
    WITH credits AS (
        SELECT user_id, wallet_id, sum(amount) AS total
        FROM incomes WHERE deleted_at IS NULL GROUP BY user_id, wallet_id
    ), debits AS (
        SELECT user_id, wallet_id, sum(amount) AS total
        FROM expenses WHERE deleted_at IS NULL GROUP BY user_id, wallet_id
    ), movements AS (
        SELECT user_id, destination_wallet_id AS wallet_id, amount FROM wallet_transfers
        UNION ALL
        SELECT user_id, source_wallet_id AS wallet_id, -amount FROM wallet_transfers
    ), transfer_net AS (
        SELECT user_id, wallet_id, sum(amount) AS total
        FROM movements GROUP BY user_id, wallet_id
    )
    SELECT count(*)
    FROM wallets w
    LEFT JOIN credits i ON i.user_id = w.user_id AND i.wallet_id = w.id
    LEFT JOIN debits e ON e.user_id = w.user_id AND e.wallet_id = w.id
    LEFT JOIN transfer_net t ON t.user_id = w.user_id AND t.wallet_id = w.id
    WHERE w.current_balance <> w.opening_balance + coalesce(i.total, 0) - coalesce(e.total, 0)
                              + coalesce(t.total, 0)
""")


def wallet_discrepancies(connection):
    return connection.scalar(WALLET_DISCREPANCIES)

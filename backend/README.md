# FastAPI and PostgreSQL backend foundation

The Android client will use this versioned REST API. The backend provides application liveness, PostgreSQL readiness, API documentation, and an Alembic migration baseline.

- `app/main.py` creates the FastAPI app and applies CORS settings.
- `app/core/config.py` loads settings from the backend environment file and process environment.
- `app/api/v1/` defines versioned routing and the health endpoint.
- `app/db/` provides shared declarative metadata, a pooled synchronous engine, and the FastAPI session dependency. Connections open on demand. Callers own commits and transaction boundaries. Closing a session rolls back pending work and returns its connection to the pool.
- `migrations/` applies schema revisions using the same metadata and settings.
- `tests/test_health.py` exercises the API through FastAPI TestClient.

## Windows setup

Use Python 3.15.2, verified for this phase on Windows x64. Run the following from the repository root. Use the full path to your Python interpreter if the Windows alias is unavailable.

```powershell
Set-Location backend
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
```

For a runtime-only installation, use `requirements.txt`.

Database dependencies verified on Python 3.15.2 are SQLAlchemy 2.1.9, Psycopg 3.3.9 with its Windows x64 binary wheel, and Alembic 1.20.1.

## Environment configuration

The defaults work without an environment file. To customize them, copy `.env.example` to `.env` and edit the copy. Process environment variables take precedence.

| Variable | Purpose |
| --- | --- |
| `EXPENSE_TRACKER_APP_NAME` | API title |
| `EXPENSE_TRACKER_APP_VERSION` | Version included in the health response and OpenAPI schema |
| `EXPENSE_TRACKER_CORS_ORIGINS` | JSON array of exact browser origins. Defaults to an empty array. |
| `DATABASE_URL` | Development application and Alembic connection URL. Leave unset to run liveness and documentation without a database. |
| `TEST_DATABASE_URL` | Explicit isolated PostgreSQL test connection URL. Integration tests and test migrations never fall back to the development URL. |

For temporary Flutter Chrome testing, use a fixed port and configure its exact HTTP or HTTPS origin. Omit the trailing slash.

```dotenv
EXPENSE_TRACKER_CORS_ORIGINS=["http://localhost:5173"]
```

Use the `postgresql+psycopg://role:encoded-password@host:port/database` format. Percent-encode the password as a URL component, including reserved characters such as `@`, `:`, `/`, `#`, and `%`. The optional query parameter is `sslmode`. Store values in the ignored backend `.env` or supply them as process environment variables. Do not include real values in source, shell history, or Alembic configuration.

## PostgreSQL setup on Windows

PostgreSQL 16 tooling was verified. This machine's PostgreSQL 16 service accepts local connections at `127.0.0.1:5433`. Check your configured port before connecting.

```powershell
$pgBin = 'C:\Program Files\PostgreSQL\16\bin'
& "$pgBin\pg_isready.exe" -h 127.0.0.1 -p 5433
& "$pgBin\psql.exe" -X -W -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5433 -U postgres -d postgres
```

Use the administrator password only at the local prompt. In that interactive session, check for existing project databases and roles first.

```sql
SELECT datname, pg_get_userbyid(datdba) AS owner
FROM pg_database WHERE datname IN ('expense_tracker_dev', 'expense_tracker_test');

SELECT rolname FROM pg_roles
WHERE rolname IN ('expense_tracker_app', 'expense_tracker_test_app');
```

If either query returns rows, stop and verify ownership, data and permissions before commissioning those objects. The following commands are for a fresh setup only. Enter two distinct passwords at the `\password` prompts.

```sql
CREATE ROLE expense_tracker_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE expense_tracker_test_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
\password expense_tracker_app
\password expense_tracker_test_app

CREATE DATABASE expense_tracker_dev OWNER expense_tracker_app;
CREATE DATABASE expense_tracker_test OWNER expense_tracker_test_app;

REVOKE ALL ON DATABASE expense_tracker_dev FROM PUBLIC;
REVOKE ALL ON DATABASE expense_tracker_test FROM PUBLIC;
ALTER ROLE expense_tracker_app LOGIN;
ALTER ROLE expense_tracker_test_app LOGIN;
\q
```

Each role owns its own database, including its public schema through PostgreSQL 16's `pg_database_owner` mechanism. The test suite checks the two project databases' reciprocal connection restrictions. Other databases on a shared cluster may independently grant access to `PUBLIC`. Use a project-dedicated cluster if cluster-wide isolation is required without altering unrelated databases.

To configure both URLs for the current PowerShell process, run this from `backend/`. The prompts mask input and encode reserved characters. Run migrations and tests in the same terminal.

```powershell
function Set-ExpenseTrackerDatabaseUrl($name, $role, $database) {
    $password = Read-Host "Password for $role" -AsSecureString
    $credential = [pscredential]::new($role, $password)
    $encoded = [uri]::EscapeDataString($credential.GetNetworkCredential().Password)
    [Environment]::SetEnvironmentVariable(
        $name, "postgresql+psycopg://${role}:${encoded}@127.0.0.1:5433/$database", 'Process'
    )
}
Set-ExpenseTrackerDatabaseUrl DATABASE_URL expense_tracker_app expense_tracker_dev
Set-ExpenseTrackerDatabaseUrl TEST_DATABASE_URL expense_tracker_test_app expense_tracker_test
```

## Alembic migrations

Run these commands from `backend/`. Revision `0001` is the empty baseline, `0002` adds users and refresh sessions, `0003` adds password reset records, `0004` adds and backfills categories, `0005` adds wallets, and `0006` adds income. Online migrations verify the database and role. The income migration tests exercise the rollback in an isolated transaction. Apply only the forward upgrade to the development database after testing.

```powershell
.\.venv\Scripts\python.exe -m alembic -x target=test upgrade head
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m pip check
.\.venv\Scripts\python.exe -m alembic -x target=test current
.\.venv\Scripts\python.exe -m alembic current
.\.venv\Scripts\python.exe -m alembic upgrade 0006
.\.venv\Scripts\python.exe -m alembic current
```

## Start and verify

Run from `backend/`.

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Use a second PowerShell terminal to check the running server.

```powershell
Invoke-RestMethod http://127.0.0.1:8000/api/v1/health
Invoke-RestMethod http://127.0.0.1:8000/api/v1/health/ready
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/docs).StatusCode
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/openapi.json).StatusCode
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/redoc).StatusCode
```

| Route | Response |
| --- | --- |
| `GET /api/v1/health` | Application liveness and version, independent of PostgreSQL |
| `GET /api/v1/health/ready` | PostgreSQL connectivity probe. Returns 200 with `{"status":"ready"}` or 503 with `{"status":"unavailable"}`. |
| `GET /docs` | Swagger UI |
| `GET /openapi.json` | OpenAPI schema |
| `GET /redoc` | ReDoc |

Stop the foreground server with Ctrl+C.

## Automated testing

Run from `backend/` with the development dependencies installed.

```powershell
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m pip check
```

Starlette 1.10.0 prefers `httpx2` for `TestClient`. If it is absent, importing
`TestClient` falls back to the pinned `httpx` and emits a deprecation warning.
The tests still run, and Uvicorn does not use this test client.

The real PostgreSQL tests skip when `TEST_DATABASE_URL` is unset. They verify the connected test database and role before running a migration round trip inside a transaction that is rolled back. Configure both project databases on the same instance for the isolation checks.

The authentication, category, wallet, and income integration suites require `TEST_DATABASE_URL` and revision `0006` on the isolated test database. They verify database and role identity, create uniquely named synthetic accounts, and remove those accounts when finished. SMTP is mocked in tests.

Connection failures report a sanitized PostgreSQL diagnostic. The application engine suppresses informational SQL and pool logging and hides bound parameters. The pytest configuration keeps tracebacks while suppressing frame locals, which can contain driver configuration. For a connection failure, verify the isolated database identity, listener, and role with an interactive `psql` session.

## Income management

The income module stores owner-scoped received income in `incomes`. Each record references a wallet and an income category. Composite foreign keys enforce same-owner references. IDs remain stable, edits increment a version, and deletion records a UTC timestamp while excluding the record from history and totals. Account deletion cascades to income records and creation replay results. The development deletion policy still needs a production financial retention decision.

`income_date` is a calendar DATE in YYYY-MM-DD format. The business date uses the modern Asia/Colombo offset of UTC+05:30. Historical dates are accepted through today. Technical timestamps are UTC. Positive LKR amounts are sent as exact decimal strings with up to two fractional digits and a maximum of `9999999999999999.99`. PostgreSQL stores amounts as NUMERIC(18,2), and Python uses Decimal. PostgreSQL sums without the individual amount's precision limit. The wallet cannot go below zero or above its limit.

| Method and path | Contract |
| --- | --- |
| `GET /api/v1/incomes` | Owner-scoped active history ordered by received date, creation time, and ID descending. Supports `date_from`, `date_to`, `category_id`, `wallet_id`, literal title or note search `q`, `limit` (1–100, default 50), and `offset`. Returns `items` and nullable `next_offset`. |
| `GET /api/v1/incomes/summary` | Requires `year` and `month`. Returns monthly `total`, `count`, and category totals in `categories`. History filters and pagination do not affect the summary. Archived references remain included. |
| `GET /api/v1/incomes/{id}` | Returns the record, version, and wallet and category display fields. Missing, foreign, and deleted records return `404`. |
| `POST /api/v1/incomes` | Requires a UUIDv4 `Idempotency-Key`. Returns `201` on first success and replays the original `201` snapshot for the same canonical request. |
| `PATCH /api/v1/incomes/{id}` | Requires `expected_version` and one or more editable fields. Returns the new version. |
| `DELETE /api/v1/incomes/{id}` | Requires an integer version in `If-Match`. Returns `204` and reverses the credit once. Subsequent deletes with a valid header also return `204`. |

Example create body.

```json
{"title":"Monthly salary","amount":"50000.00","currency":"LKR","category_id":"10000000-0000-4000-8000-000000000001","wallet_id":"10000000-0000-4000-8000-000000000002","income_date":"2026-11-28","note":"November salary"}
```

Example summary response for the month.

```json
{"currency":"LKR","year":2026,"month":11,"total":"50000.00","count":1,"categories":[{"category_id":"10000000-0000-4000-8000-000000000001","name":"Salary","total":"50000.00"}]}
```

All requests require a valid bearer session. Wrong-owner references return `404`, invalid input returns `422`, and stale versions, incompatible references, balance violations, and operation-key conflicts return `409`. Titles accept up to 120 code points, and notes accept up to 1,000. New assignments require active references and an INCOME category. An unchanged archived reference remains usable for metadata corrections. Balance-changing operations must preserve the archived wallet's zero-balance rule.

The write transaction takes the owner key-share lock first, then the creation key or income row, wallet rows in UUID order, and the category share lock when applicable. Account deletion locks the owner before cascading. Wallet and category archival lock their own rows. Financial writes commit once. Creation reserves the owner-scoped key and persists the canonical fingerprint and original response in the same transaction as the credit. Successful keys are retained until account deletion. Edits apply the amount delta or reverse the source credit and apply the destination credit. Deletion reverses the credit and records the tombstone atomically.

Revision `0006` creates income and replay storage without changing existing wallet balances. Its downgrade takes exclusive locks and refuses when either table contains data. For isolated verification, upgrade to `0006`, run the migration tests that downgrade to `0005` and re-upgrade within a rolled-back test transaction, then run the complete suite. Apply only the forward migration to development. Reconcile Phase 5.3 balances with opening balance plus exact SUM of active income by owner and wallet. Future expense and transfer writers must share the lock order, use auditable atomic balance changes, and extend reconciliation.

## Wallet management

Wallets are user-created cash, bank, or digital accounts. The wallet router reuses the authenticated session dependency. The repository scopes all reads, summaries, and locked writes to the signed-in owner. All wallet responses use `Cache-Control: no-store`. Missing and foreign IDs return the same `404`.

The `wallets` table stores a stable UUID, required owner UUID, display and normalized names, type, currency, opening and current balances, icon, color, active status, and UTC timestamps. Owner deletion cascades to wallets. PostgreSQL enforces normalized-name uniqueness across wallet types, valid types and currency, allowlisted icons, uppercase HEX colors, nonnegative balances, and zero current balance for archived wallets. The owner, active status, and type index supports filtered listing. Names follow the category Unicode normalization rules and remain reserved while archived. The icon allowlist matches categories.

LKR and no overdrafts are provisional rules. Both balances use `NUMERIC(18,2)` and Python `Decimal`. Opening balances accept unsigned strings with 1–16 ASCII digits before the decimal point and up to two fractional digits. A decimal point requires at least one following digit. The per-wallet range is `0.00` to `9999999999999999.99`. Exponents, signs, separators, whitespace, excess precision, nonfinite values, and JSON numbers fail validation. Serialized amounts always have two fractional digits. PostgreSQL aggregates exact decimals and the summary can exceed the per-wallet limit.

Creation initializes current balance from opening balance. Metadata edits accept name, icon, and color. Type, currency, balances, ownership, and archive state are server-controlled after creation. Restore an archived wallet before editing. Archival locks the wallet row and requires an exact zero balance. Repeating archive or restore succeeds and preserves the UUID and amounts. Funded wallets remain active until future transaction or transfer features can reduce their balance to zero.

| Method and path | Operation | Responses |
| --- | --- | --- |
| `GET /api/v1/wallets` | List owned wallets | `200` |
| `GET /api/v1/wallets/summary` | Get active total, counts, and balances by type | `200` |
| `GET /api/v1/wallets/{id}` | Read an owned wallet | `200`, `404` |
| `POST /api/v1/wallets` | Create a wallet | `201`, `409` |
| `PATCH /api/v1/wallets/{id}` | Edit active wallet metadata | `200`, `404`, `409` |
| `DELETE /api/v1/wallets/{id}` | Archive a zero-balance wallet | `204`, `404`, `409` |
| `POST /api/v1/wallets/{id}/restore` | Restore a wallet | `200`, `404` |

All routes require a bearer session and return `401` for invalid credentials or `422` for invalid inputs. Listing supports `type`, a literal normalized substring `q`, `active` (default true), `limit` (1–100, default 50), and `offset` (0–1,000,000, default zero). Wallets sort by normalized name and UUID. The list returns `items` and nullable `next_offset`. The summary is independent of list filters and pagination.

Example create request and summary after creating that wallet in an empty account.

```json
{"name":"Personal Cash","type":"CASH","currency":"LKR","opening_balance":"5000.00","icon":"wallet","color":"#D4AF37"}
```

```json
{"currency":"LKR","total_active_balance":"5000.00","active_count":1,"archived_count":0,"balances_by_type":{"CASH":"5000.00","BANK":"0.00","DIGITAL":"0.00"}}
```

Future financial writes must validate active status and ownership, lock participating wallets in a consistent order, record operations and update balances in the same transaction, and use idempotency keys where requests can be retried. Reconciliation should compare balances to independently summed opening amounts and recorded financial activity. Establish a financial retention and deletion policy before enabling production account deletion with financial history.

## Category Management

The authenticated router delegates writes to the category service and owner-scoped queries to the repository. Each category has a UUID, a required owner, display and normalized names, an immutable type, an icon, an uppercase HEX color, an active flag, and timezone-aware timestamps serialized in UTC. A nullable `default_code` identifies protected defaults and supplies the response's `is_default` flag. PostgreSQL enforces owner/type/name and owner/default-code uniqueness, valid category types, icons and colors, and active defaults. The owner/active/type index supports list queries.

Migration `0004` backfills the version 1 defaults. Registration provisions them in the user creation transaction. Conflict-safe inserts preserve existing records on repeated or concurrent provisioning.

| Type | Default | Icon | Color |
| --- | --- | --- | --- |
| Income | Salary | `work` | `#E8D5A3` |
| Income | Freelance | `laptop` | `#C4B5FD` |
| Income | Business | `store` | `#FBBF24` |
| Income | Investments | `trending_up` | `#4ADE80` |
| Income | Gifts | `gift` | `#F9A8D4` |
| Income | Other Income | `wallet` | `#D4AF37` |
| Expense | Food & Dining | `restaurant` | `#FDBA74` |
| Expense | Transport | `car` | `#93C5FD` |
| Expense | Shopping | `shopping_bag` | `#F9A8D4` |
| Expense | Housing | `home` | `#E8D5A3` |
| Expense | Bills & Utilities | `bolt` | `#FBBF24` |
| Expense | Education | `graduation_cap` | `#C4B5FD` |
| Expense | Healthcare | `medical` | `#FCA5A5` |
| Expense | Entertainment | `movie` | `#F9A8D4` |
| Expense | Travel | `flight` | `#A5F3FC` |
| Expense | Other Expenses | `category` | `#D4AF37` |

Every route requires an active bearer session. Invalid or revoked sessions receive `401`, invalid input receives `422`, and foreign and nonexistent IDs share a generic `404`.

| Method and path | Operation | Responses |
| --- | --- | --- |
| `GET /api/v1/categories` | List owned categories | `200` |
| `GET /api/v1/categories/{id}` | Read an owned category | `200`, `404` |
| `POST /api/v1/categories` | Create a custom category | `201`, `409` |
| `PATCH /api/v1/categories/{id}` | Update name, icon, or color | `200`, `403`, `404`, `409` |
| `DELETE /api/v1/categories/{id}` | Archive a custom category | `204`, `403`, `404` |
| `POST /api/v1/categories/{id}/restore` | Restore a custom category | `200`, `403`, `404` |

Lists accept `type=INCOME|EXPENSE`, `q` for a literal normalized substring, `active=true|false` (default true), and optional `default=true|false`. Results sort by default status first, normalized name, type, and UUID. `limit` defaults to 50 and accepts 1–100. `offset` defaults to zero and accepts 0–1,000,000. The list response contains `items` and a nullable `next_offset`.

A create request accepts the following fields.

```json
{"name":"University Expenses","type":"EXPENSE","icon":"graduation_cap","color":"#D4AF37"}
```

The category response has this shape.

```json
{
  "id":"10000000-0000-4000-8000-000000000001",
  "name":"University Expenses",
  "type":"EXPENSE",
  "icon":"graduation_cap",
  "color":"#D4AF37",
  "is_default":false,
  "is_active":true,
  "created_at":"2026-11-28T12:00:00Z",
  "updated_at":"2026-11-28T12:00:00Z"
}
```

Names reject Unicode control, format, and surrogate code points. The API applies NFKC, trims and collapses whitespace, then requires 1–80 code points. Comparison uses Unicode case folding followed by NFKC. The API accepts the listed icon identifiers and six-digit HEX colors with a leading hash. Request bodies reject unknown and server-managed fields. Ownership comes from the session.

Default mutations return `403`. Archived names remain reserved per user and type, so duplicate creates and renames return `409`. Repeated archive and restore requests succeed for an owned custom category. Account deletion cascades to owned categories. Future transaction writes must validate category ownership, type, and active status. Future financial foreign keys need to preserve historical category references and account deletion semantics.

## Authentication

The versioned API handles requests and response validation. The authentication service owns registration and session transactions, and repositories handle user lookup and family locks. User responses expose only the authenticated account's ID, name, email, and timestamps. Registering creates no session.

| Variable | Purpose |
| --- | --- |
| `EXPENSE_TRACKER_JWT_SECRET` | Required for authentication. Use a cryptographically generated development key in the ignored `.env` and a separate managed key in production. |
| `EXPENSE_TRACKER_JWT_ISSUER` | Token issuer, defaults to `expense-tracker-api`. |
| `EXPENSE_TRACKER_JWT_AUDIENCE` | Token audience, defaults to `expense-tracker-android`. |
| `EXPENSE_TRACKER_ACCESS_TOKEN_MINUTES` | Access token lifetime, defaults to 15 minutes. |
| `EXPENSE_TRACKER_REFRESH_SESSION_DAYS` | Absolute session lifetime from login, defaults to 7 days. |

Generate a signing key once from `backend/`. These commands preserve an existing key and do not echo the generated value.

```powershell
@'
from pathlib import Path
from secrets import token_urlsafe
from dotenv import dotenv_values, set_key

path = Path(".env")
path.touch(exist_ok=True)
key = "EXPENSE_TRACKER_JWT_SECRET"
if not dotenv_values(path).get(key):
    set_key(path, key, token_urlsafe(48))
'@ | .\.venv\Scripts\python.exe -
```

| Route | Request | Success |
| --- | --- | --- |
| `POST /api/v1/auth/register` | JSON with `full_name`, `email`, `password` | 201, sanitized profile |
| `POST /api/v1/auth/login` | JSON with `email`, `password` | 200, token response |
| `GET /api/v1/users/me` | Bearer access token | 200, authenticated profile |
| `POST /api/v1/auth/refresh` | JSON with `refresh_token` | 200, replacement token response |
| `POST /api/v1/auth/logout` | Bearer access token | 204, empty body |

Register, then log in and send the returned access token as a Bearer credential. Token responses contain `access_token`, `refresh_token`, `token_type`, `expires_in` in seconds, and `refresh_expires_at`. Authentication responses use `Cache-Control: no-store`. Invalid credentials return a generic 401. Duplicate registration returns 409 and can reveal account existence. Registration validates email format and normalizes case, with mailbox ownership verification deferred.

Passwords must be 15–128 characters. Spaces and Unicode are accepted. Argon2id protects stored passwords and hashes are upgraded after successful checks when the hashing policy changes. Login uses a dummy hash for missing users. Access JWTs use HS256 and bind to the user and active session family. Refresh tokens are random opaque values stored as SHA-256 digests.

Refresh keeps the original absolute session deadline. Each successful request consumes the old token, and reuse revokes the whole family. Serialize refresh requests in the Android client and replace stored tokens together. If concurrent refreshes or a retry consume the same token, the client may need to log in again. Logout revokes one family immediately and is idempotent while the same signed access token remains unexpired.

Use TLS, platform-backed secure token storage, a managed signing secret, and distributed rate limits at deployment. The local per-source limit and four concurrent password operations apply per process. Configure trusted proxies and ingress request-size limits. Exclude credentials, authorization headers, and request bodies from logs. Plan a retention policy for expired session records.

## Profile and account security

| Route | Request | Success |
| --- | --- | --- |
| `PATCH /api/v1/users/me` | Bearer access token and JSON `full_name` | 200, updated profile with a UTC timestamp |
| `POST /api/v1/auth/change-password` | Bearer access token and JSON `current_password`, `new_password` | 204 |
| `POST /api/v1/auth/forgot-password` | JSON `email` | 202, generic recovery message |
| `POST /api/v1/auth/reset-password` | JSON `reset_token`, `new_password` | 204 |
| `DELETE /api/v1/users/me` | Bearer access token and JSON body with `current_password` | 204 |

Profile updates trim the full name using registration rules. Email stays immutable. Unsupported fields return 422. Invalid authentication returns 401 with a Bearer challenge. Incorrect current passwords, reuse of the current password during change, and invalid reset tokens return 400. Exhausting the source rate limit returns 429. Validation and database errors are sanitized, and sensitive responses include `Cache-Control: no-store`.

Changing or resetting a password requires the user to log in again. The password write, session revocation, and reset-token invalidation share one transaction. Account operations acquire the user row before session-family or reset-token writes. Login and refresh also acquire the user row before issuing tokens, so they cannot leave a usable session based on the old password. Account deletion permanently removes the user, refresh sessions, and reset records while preserving other accounts. Future financial modules must define and integrate their deletion or retention policies before production.

### Recovery and SMTP

Recovery codes are 43-character URL-safe strings generated from 256 bits of randomness. PostgreSQL stores only SHA-256 digests. Codes expire after 15 minutes by default and are single-use. A newer request invalidates older codes. Recovery issuance removes that account's tokens that expired more than seven days earlier. Accounts that never request recovery again retain expired records until a maintenance purge or account deletion.

The API returns the same 202 response for valid email input regardless of account state or delivery outcome. Delivery runs after the response in a bounded background worker and starts after the database transaction has closed. There is no durable delivery queue or automatic retry. Delivery failures emit a generic log message. A newer code can supersede an older one even if emails arrive out of order. The Android client should accept a pasted code, clear stored tokens after a password change or reset, and prompt for login. Recovery uses email codes without a web app or deep-link domain.

Configure the following in the ignored backend `.env`. Recovery delivery is optional for local development and is independent of ordinary authentication and health checks.

| Variable | Example or default |
| --- | --- |
| `SMTP_HOST` | `smtp.gmail.com` for Gmail |
| `SMTP_PORT` | `587` for STARTTLS or `465` for implicit TLS |
| `SMTP_SECURITY` | `starttls` (default) or `tls` |
| `SMTP_USERNAME` | Provider login address |
| `SMTP_PASSWORD` | Provider-issued SMTP credential |
| `SMTP_FROM_EMAIL` | Provider-authorized sender address |
| `SMTP_TIMEOUT_SECONDS` | `5` seconds by default per socket operation |
| `PASSWORD_RESET_TOKEN_EXPIRE_MINUTES` | `15` minutes by default |

For Gmail, use an eligible account with 2-Step Verification and an [app password](https://support.google.com/mail/answer/185833). Store the app password directly in the ignored local file or secret store. Both SMTP modes verify certificates. STARTTLS failure ends the connection before authentication. Recovery also has a process-local per-email limit of three requests per 15 minutes and at most four active jobs per worker. Use shared limits and a durable delivery design before relying on recovery in production.

If readiness returns 503 while liveness returns 200, verify `DATABASE_URL`, the listener with `pg_isready`, and the role with an interactive `psql` login. For a migration identity error, check the selected target and the database and role names. Keep connection URLs and raw authentication errors out of shared logs.

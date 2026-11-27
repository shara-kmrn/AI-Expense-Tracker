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

Run these commands from `backend/`. The empty baseline records the first revision in Alembic's version table and creates no business tables. Online migrations verify the connected database and role before executing. Test the full round trip in the isolated test database. After confirming the development database belongs to this project, apply the non-destructive baseline there.

```powershell
.\.venv\Scripts\python.exe -m alembic -x target=test upgrade head
.\.venv\Scripts\python.exe -m alembic -x target=test downgrade base
.\.venv\Scripts\python.exe -m alembic -x target=test upgrade head
.\.venv\Scripts\python.exe -m alembic upgrade head
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

If readiness returns 503 while liveness returns 200, verify `DATABASE_URL`, the listener with `pg_isready`, and the role with an interactive `psql` login. For a migration identity error, check the selected target and the database and role names. Keep connection URLs and raw authentication errors out of shared logs.

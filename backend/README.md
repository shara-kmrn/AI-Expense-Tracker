# FastAPI backend foundation

The Android client will use this versioned REST API. This phase provides application health and API documentation.

- `app/main.py` creates the FastAPI app and applies CORS settings.
- `app/core/config.py` loads settings from the backend environment file and process environment.
- `app/api/v1/` defines versioned routing and the health endpoint.
- `tests/test_health.py` exercises the API through FastAPI TestClient.

## Windows setup

Use Python 3.15.2, verified for this phase on Windows x64. Run the following from the repository root. Use the full path to your Python interpreter if the Windows alias is unavailable.

```powershell
Set-Location backend
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
```

For a runtime-only installation, use `requirements.txt`.

## Environment configuration

The defaults work without an environment file. To customize them, copy `.env.example` to `.env` and edit the copy. Process environment variables take precedence.

| Variable | Purpose |
| --- | --- |
| `EXPENSE_TRACKER_APP_NAME` | API title |
| `EXPENSE_TRACKER_APP_VERSION` | Version included in the health response and OpenAPI schema |
| `EXPENSE_TRACKER_CORS_ORIGINS` | JSON array of exact browser origins. Defaults to an empty array. |

For temporary Flutter Chrome testing, use a fixed port and configure its exact HTTP or HTTPS origin. Omit the trailing slash.

```dotenv
EXPENSE_TRACKER_CORS_ORIGINS=["http://localhost:5173"]
```

## Start and verify

Run from `backend/`.

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Use a second PowerShell terminal to check the running server.

```powershell
Invoke-RestMethod http://127.0.0.1:8000/api/v1/health
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/docs).StatusCode
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/openapi.json).StatusCode
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8000/redoc).StatusCode
```

| Route | Response |
| --- | --- |
| `GET /api/v1/health` | Application status and version, for example `{"status":"ok","version":"0.1.0"}` |
| `GET /docs` | Swagger UI |
| `GET /openapi.json` | OpenAPI schema |
| `GET /redoc` | ReDoc |

Stop the foreground server with Ctrl+C.

## Automated testing

Run from `backend/` with the development dependencies installed.

```powershell
.\.venv\Scripts\python.exe -m pytest
```

Starlette 1.10.0 prefers `httpx2` for `TestClient`. If it is absent, importing
`TestClient` falls back to the pinned `httpx` and emits a deprecation warning.
The tests still run, and Uvicorn does not use this test client.

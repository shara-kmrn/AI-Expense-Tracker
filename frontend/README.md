# AI Expense Tracker frontend

The Flutter client targets Android. Phase 4.3 covers authentication, profile management, and account security. Phase 5.1 adds category management. Chrome provides a temporary local test target.

## Architecture

- `lib/app/` contains the Material 3 theme and guarded GoRouter routes.
- `lib/core/` contains the trusted-origin HTTP client, session storage adapters, and shared controls.
- `lib/features/auth/` contains the typed account and credential models, FastAPI repository, session controller, and forms.
- `lib/features/profile/` contains the profile, placeholder home, and account settings screens.

`http` provides one injectable native and browser transport. Requests explicitly reject redirects. GoRouter keeps guest and authenticated routes separate. `flutter_secure_storage` protects saved refresh credentials on Android. A Flutter `ChangeNotifier` handles the current session with constructor injection, so an additional state management package is unnecessary for this phase.

## Design

Material 3 dark uses midnight `#0A0A0B`, background `#18181B`, surface `#242427`, elevated `#2D2D30`, selected `#44391F`, gold `#D4AF37`, and champagne `#E8D5A3`. Primary text is `#FAFAF9`, muted text `#A1A1AA`, and borders `#3F3F46`. Semantic success, error, and warning are `#4ADE80`, `#F87171`, and `#FBBF24`.

Theme tokens centralize typography, spacing, and corner radii. Screens share the logo, layout, cards, fields, password visibility controls, loading states, feedback, buttons, and confirmation dialogs. A future light theme can define a second set of theme tokens before adding appearance controls.

## Local Chrome development

Use the installed Flutter SDK from a regular VS Code terminal. For an isolated UI smoke test, run the following from the repository root. It checks the PostgreSQL test identity, limits CORS to the Chrome development origin, disables outbound mail, and cleans up only the generated test account when Uvicorn stops normally. Use the generated address for registration and the account flows.

```powershell
Set-Location backend
@'
from secrets import token_urlsafe
from uuid import uuid4
import uvicorn
from pydantic import SecretStr
from sqlalchemy import delete, text
from app.auth.models import User
from app.core.config import Settings
from app.db.session import build_engine
from app.main import create_app

settings = Settings()
if not settings.test_database_url:
    raise SystemExit("Configure the isolated test database first.")
settings = settings.model_copy(update={
    "database_url": settings.test_database_url,
    "cors_origins": ("http://127.0.0.1:5173",),
    "jwt_secret": SecretStr(token_urlsafe(48)),
})
engine = build_engine(settings.database_url)
with engine.connect() as conn:
    assert tuple(conn.execute(text("SELECT current_database(), current_user")).one()) == (
        "expense_tracker_test", "expense_tracker_test_app"
    )
    assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0005"
email = f"phase43-manual-{uuid4().hex}@example.com"
application = create_app(settings)
application.state.recovery_delivery = lambda *_: None
print("Register this disposable test email:", email)
try:
    uvicorn.run(application, host="127.0.0.1", port=8000, access_log=False)
finally:
    with engine.begin() as conn:
        conn.execute(delete(User).where(User.email == email))
    engine.dispose()
'@ | .\.venv\Scripts\python.exe -
```

In a separate terminal from the repository root:

```powershell
Set-Location frontend
flutter pub get
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 5173 --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
```

Use exactly `127.0.0.1` in the Chrome URL. Register the generated account, sign in, open the profile and settings, then exercise profile updates, password change, logout, and account deletion. The smoke server suppresses email delivery. Use the mocked Flutter and isolated backend test suites to exercise successful recovery without real mail. Stop Flutter with `q` and the smoke API with Ctrl+C.

## Android

For a physical device use a trusted HTTPS API URL via `--dart-define=API_BASE_URL=...`. For debug-only loopback testing with an already configured physical device, USB port forwarding can map `adb reverse tcp:8000 tcp:8000` to the PC's loopback server, subject to device and Android networking support. The debug manifest permits cleartext for the documented loopback hosts. Release builds require HTTPS and exclude the debug network override. The Android manifests exclude backups and shared-preference device transfers. Verify those controls on a physical Android device in Phase 08.

## Authentication and storage

Startup restores a saved refresh credential and loads the current profile. Registration and reset return to sign-in. Sign-in opens Home. Protected routes include Home, profile and editing, settings, password change, and debug-only account deletion. The frontend gate for deletion does not replace production server policy.

Access tokens remain in memory. Android persists only the refresh credential through secure storage. Chrome uses memory only, so reload requires sign-in. A single pending refresh is shared across concurrent requests. A read can retry once after rotation; account mutations are never replayed. When a refresh outcome is uncertain, local credentials are cleared and the user signs in again. Logout invalidates stale completions and clears local credentials even when remote revocation cannot be confirmed. Password changes and deletion clear local authentication after success.

## Category Management

From Home, open **Categories** to browse authenticated API results by Income or Expense, search by name, and switch between active and archived categories. The active view groups protected defaults and custom categories. Custom actions include editing and confirming archival. The archived view offers restoration.

Add and edit share a scrollable form with name validation, labeled icon and color choices, and a live preview. Edit displays the type as read-only. Stable icon identifiers map to Material icons, with a generic category icon for unknown identifiers. Badges accept valid API HEX colors and choose a contrasting foreground. The picker offers named presets and marks the selected choice.

The category repository uses the existing HTTP client and session controller. Reads can renew the session and retry once. Writes are sent once per explicit action. Following an uncertain outcome, the app directs the user to check the refreshed list. The controller drops older results after a filter change and clears categories when the session changes. The API is authoritative for Unicode normalization and duplicate names.

The Flutter suite covers category parsing, request construction, guarded routing, filters and search, form and mutation flows, small-screen behavior, and stale-session handling. Phase 08 still includes the automated Chrome category smoke test, comprehensive manual Chrome category workflows, and physical Android checks for keyboard, system Back, TalkBack, and text scaling.

## Wallet management

Open **Wallets** from Home. My Wallets shows the API’s active balance summary, active and archived counts, name search, type filters, pagination, and a separate archived view. Select a wallet to see its current and opening balances, type, status, and dates. Wallet forms reuse the category icon and color palette and badge. Edit keeps the financial fields read-only. Archive requires a zero balance, and a funded wallet cannot be archived until a future transaction or transfer brings its balance to zero.

The repository sends and receives exact decimal strings. The client parses responses as `BigInt` minor units and formats LKR amounts with two decimal places on Android and Chrome. The controller refreshes the summary and wallet list after changes, drops stale results, and clears data when the account changes. Secure session renewal can retry eligible reads. Wallet mutations are sent once per explicit action, with follow-up reads used to resolve uncertain outcomes.

Wallet unit and widget tests cover amount precision, HTTP contracts, pagination, account changes, and the guarded wallet flow. The Phase 5.2 headless Chrome wallet test was stopped after it produced no output. Phase 08 still includes live Chrome-to-API smoke testing, comprehensive manual Chrome workflows, and physical Android verification of keyboard insets, system Back, TalkBack, and text scaling.

## Verification

```powershell
dart format lib test
flutter analyze
flutter test
```

Unit and widget tests use simulated HTTP responses and storage. The backend remains authoritative for complete email normalization and policy. Test Chrome against isolated disposable accounts and controlled recovery codes, then stop the temporary server and remove the test accounts. Production rollout still requires an HTTPS deployment, server-side deletion policy, and physical Android verification.

### Phase 4.3 verification and Phase 08 deferrals

- **Implemented:** the authentication screens, guarded navigation, profile editing, password change and recovery, logout, and debug-only account deletion.
- **Automated:** Flutter unit and widget tests cover form validation, navigation, concurrent refresh, refresh rejection and uncertainty, logout races, storage write failure, redirect rejection, and account-mutation replay prevention. The backend suite covers PostgreSQL session revocation and recovery behavior independently.
- **Completed in Chrome:** the manual visual design review passed. A separate automated Chrome run submitted registration to the isolated API, received HTTP 201, and returned to sign-in.
- **Deferred from Phase 4.3/4.4 to Phase 08:** manual registration, duplicate and invalid form cases, invalid and successful login, Home navigation, profile retrieval and editing, read-only email, password change and old-session revocation, logout and back navigation, controlled forgot/reset and code reuse, account deletion and database absence, and network, loading, repeated-submit, and expired-session behavior.
- **Physical Android verification in Phase 08:** secure-storage persistence and failure handling, process restart, backup and device transfer exclusions, debug loopback and release HTTPS behavior, keyboard insets, system Back behavior, text scaling, and full on-device account flows. APK generation remains a Phase 08 deliverable.

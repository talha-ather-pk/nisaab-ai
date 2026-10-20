# Nisaab AI

**Track · Understand · Grow.** A personal finance manager for Pakistan. Type or speak a transaction ("Spent 1,200 rupees on groceries at Carrefour"). The AI extracts and categorises it, budgets and forecasts flag overspending before it happens, and an assistant answers questions about your own money.

```
nisaab-ai/
├── docker-compose.yml          Postgres + API stack
├── .env.example                every secret/setting, documented
├── database/
│   └── schema.sql              production schema (users, transactions, budgets, ai_financial_logs)
├── backend/                    FastAPI service
│   ├── main.py                 app, middleware, error handling, all REST routes
│   ├── config.py               settings from env / .env
│   ├── database.py             SQLAlchemy engine + connection pool
│   ├── models.py               ORM models (mirror schema.sql)
│   ├── schemas.py              Pydantic request/response contracts
│   ├── security.py             bcrypt, JWT, auth dependency, ownership checks
│   ├── nlp_engine.py           entity extraction: amount, currency, merchant, category, type, date
│   ├── forecasting.py          month-end projection, overspend risk, next-month forecast
│   ├── assistant.py            AI assistant (Claude or built-in rule engine)
│   ├── seed.py                 demo account with 3 months of history
│   ├── Dockerfile
│   └── tests/                  74 tests (NLP, forecasting, full API)
├── mobile/                     Flutter app (Riverpod + Dio)
│   └── lib/
│       ├── main.dart           entry, light/dark themes, typography, routing table
│       ├── core/               config, theme tokens, formatters, categories
│       ├── models/             JSON models
│       ├── services/           api_service.dart (Dio + auth), token_storage.dart
│       ├── providers/          session, transactions, budgets, dashboard, chat, settings
│       ├── screens/            login, home shell, dashboard, history, budgets, AI chat
│       └── widgets/            input bar (text/voice), forms, chart, tiles
└── docs/                       user stories, design doc, technical doc
```

| Requirement | Version |
|---|---|
| Docker Desktop (option A) | 4.x with Compose v2 |
| PostgreSQL (option B) | 14+ (17 recommended) |
| Python (option B) | 3.11+ |
| Flutter | 3.32+ (Dart 3.8+) |

Commands are for **Windows PowerShell** unless marked otherwise. macOS/Linux differences are noted.

---

## 1. Secrets (`.env`)

```powershell
cd C:\Users\DELL\nisaab-ai
Copy-Item .env.example .env                   # macOS/Linux: cp .env.example .env
python -c "import secrets; print(secrets.token_urlsafe(64))"   # paste the output into JWT_SECRET
```

Edit `.env` and set at least:

| Variable | What to put |
|---|---|
| `POSTGRES_PASSWORD` | A strong password. Use letters and digits only, because it is embedded in a URL. |
| `DATABASE_URL` | The same password, used only when you run the API without Docker. |
| `JWT_SECRET` | The 64-character random string generated above. |
| `ANTHROPIC_API_KEY` | Optional. With a key, the assistant answers with Claude. Without one, it uses the built-in rule engine. |

`.env` is git-ignored. Never commit it.

---

## 2A. Run everything with Docker (recommended)

```powershell
docker compose up -d --build              # Postgres + API; schema.sql is applied on first boot
docker compose ps                         # both services should be "healthy"/"running"
docker compose exec api python seed.py   # optional: demo account + 3 months of data
```

- API docs: <http://localhost:8000/docs>
- Health: <http://localhost:8000/health> returns `{"status":"ok","database":"up",...}`
- Logs: `docker compose logs -f api`
- Stop: `docker compose down`. Add `-v` to also delete the database volume.

### Migrations with Docker

`database/schema.sql` runs automatically **only when the `pgdata` volume is first created**. It is idempotent (`IF NOT EXISTS`) and records its version in `schema_migrations`. To apply it to an existing database:

```powershell
Get-Content database/schema.sql | docker compose exec -T db psql -U nisaab -d nisaab
# macOS/Linux: docker compose exec -T db psql -U nisaab -d nisaab < database/schema.sql
```

---

## 2B. Run the backend without Docker

### Database

```powershell
winget install PostgreSQL.PostgreSQL.17       # macOS: brew install postgresql@17 && brew services start postgresql@17
# Reopen the terminal so psql is on PATH (Windows: C:\Program Files\PostgreSQL\17\bin)

psql -U postgres -h localhost -c "CREATE USER nisaab WITH PASSWORD 'your-db-password';"
psql -U postgres -h localhost -c "CREATE DATABASE nisaab OWNER nisaab;"
psql -U nisaab   -h localhost -d nisaab -f database/schema.sql      # migration
```

### API

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1                  # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
Copy-Item ..\.env .env                        # the API reads backend/.env (or real env vars)

pytest -q                                     # 129 tests on a temporary SQLite DB, no Postgres needed
# Same suite on PostgreSQL (use a dedicated DB; every table is dropped per test):
# $env:TEST_DATABASE_URL = "postgresql://nisaab:nisaab@localhost:5432/nisaab_test"; pytest -q
python seed.py                                # optional demo data
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` lets a phone on the same Wi-Fi reach the API. Allow the port through Windows Firewall once:

```powershell
New-NetFirewallRule -DisplayName "Nisaab API 8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow
```

### API reference

All routes except `/health`, `/api/v1/categories`, register and login need `Authorization: Bearer <token>`. Routes with `{user_id}` only accept the caller's own id.

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/auth/register` | Create an account and receive a JWT. Requires `accept_terms: true` and the current `terms_version` (research consent) |
| POST | `/api/v1/auth/login` | Log in and receive a JWT |
| GET / PATCH | `/api/v1/auth/me` | Profile, including `terms_accepted_at`, `terms_version` and `terms_required` |
| POST | `/api/v1/auth/me/accept-terms` | Record consent for an existing account (`terms_version`) |
| DELETE | `/api/v1/auth/me` | Permanently delete the account and all of its data. Body: `{"password": ...}`. The shared demo account can't be deleted |
| POST | `/api/v1/transactions/parse` | NLP: text, voice transcript or SMS to a structured preview (not saved; logged) |
| POST | `/api/v1/transactions` | Create a transaction |
| GET | `/api/v1/transactions/{user_id}` | History: `page`, `page_size`, `search`, `category`, `type`, `source`, `date_from`, `date_to`, `month`+`year`, `min_amount`, `max_amount`, `sort` |
| GET | `/api/v1/transactions/{user_id}/export` | All transactions as CSV (optional `date_from`, `date_to`) |
| PATCH / DELETE | `/api/v1/transactions/{id}` | Edit or delete. Edits to AI-parsed fields set `user_corrected`, which the parser then learns from |
| POST | `/api/v1/budgets` | Create or update a category limit for a month |
| GET | `/api/v1/budgets/{user_id}` | Budgets with spent, remaining, % used and status |
| DELETE | `/api/v1/budgets/{id}` | Remove a budget |
| POST | `/api/v1/goals` | Create a savings goal (name, target, optional target date) |
| GET | `/api/v1/goals/{user_id}` | Goals with % saved, remaining, monthly amount needed and status |
| PATCH / DELETE | `/api/v1/goals/{id}` | Edit or delete a goal |
| POST | `/api/v1/goals/{id}/contribute` | Add savings (a negative amount records a withdrawal) |
| GET | `/api/v1/analytics/summary/{user_id}` | Month totals, savings rate, category distribution, daily series, budgets |
| GET | `/api/v1/analytics/forecast/{user_id}` | Month-end projection, overspend risk, next-month forecast, recommended budgets |
| POST | `/api/v1/ai/assistant` | Context-aware financial guidance |
| GET | `/api/v1/ai/assistant/history` | Past assistant conversations |

Try it from the terminal:

```powershell
$login = Invoke-RestMethod -Method Post http://127.0.0.1:8000/api/v1/auth/login -ContentType "application/json" -Body '{"email":"demo@nisaab.app","password":"Demo@1234"}'
$h = @{ Authorization = "Bearer $($login.access_token)" }
Invoke-RestMethod -Method Post http://127.0.0.1:8000/api/v1/transactions/parse -Headers $h -ContentType "application/json" -Body '{"text":"Spent 1,200 rupees on groceries at Carrefour"}'
Invoke-RestMethod -Method Post http://127.0.0.1:8000/api/v1/ai/assistant -Headers $h -ContentType "application/json" -Body '{"message":"Am I on track with my budgets?"}'
```

---

### Model evaluation (RQ1 / RQ2)

```powershell
python evaluate.py --offline-only            # RQ1 on the held-out labelled set; no database needed
python evaluate.py --out eval\report.md      # plus correction rate and the forecast backtest from the database
```

Every metric comes with a 95% bootstrap confidence interval. The database part also replays each user's entries in date order to measure whether learning from corrections improves accuracy (with a McNemar test). On the seeded demo database the database figures are synthetic; run it after the pilot for real results.

### Pilot gold set (export → dual labelling → κ → freeze)

```powershell
python export_pilot.py --init-key        # once, on the machine that keeps the data; back the key up privately
python export_pilot.py                   # consenting, non-demo users only → eval\pilot\sample.csv + calibration.csv
#   review every row whose `reviewed` is empty: replace names with [NAME], set reviewed=yes
python labelling.py sheets eval\pilot\calibration.csv --round calibration   # both label, discuss, refine the guide
python labelling.py sheets eval\pilot\sample.csv --round main
python labelling.py agreement eval\pilot\annotator_A_main.csv eval\pilot\annotator_B_main.csv
#   fill final_category for every row of disagreements_main.csv
python labelling.py freeze eval\pilot\annotator_A_main.csv eval\pilot\annotator_B_main.csv `
    --adjudicated eval\pilot\disagreements_main.csv --sample eval\pilot\sample.csv
python evaluate.py --test-set eval\pilot\pilot_test_v1.csv   # checksum is verified before scoring
```

`eval/pilot/` holds participant text and is git-ignored. Keep it, and the key, off shared drives.

## 3. Mobile app (Flutter)

The repo contains `lib/`, `test/` and `pubspec.yaml`. Generate the platform folders once:

```powershell
cd C:\Users\DELL\nisaab-ai\mobile
flutter create . --project-name nisaab_ai --org com.nisaab --platforms android,ios
flutter pub get
flutter analyze
flutter test
```

`flutter create .` keeps existing files. It adds `android/` and `ios/`, plus a sample `test/widget_test.dart` that you can delete.

### Android setup

**1.** Edit `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>

    <queries>
        <intent>
            <action android:name="android.speech.RecognitionService"/>
        </intent>
        <!-- keep the <intent> entries flutter create generated -->
    </queries>

    <application
        android:usesCleartextTraffic="true"
        ... keep the existing attributes ...>
```

`usesCleartextTraffic` allows `http://` to your laptop during development. Remove it once the API is served over HTTPS.

**2.** `flutter_secure_storage` needs Android API 23 or later. In `android/app/build.gradle.kts` (or `build.gradle`), set `minSdk = 23` inside `defaultConfig`.

### iOS (macOS only)

Add to `ios/Runner/Info.plist` inside `<dict>`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Nisaab uses the microphone so you can add expenses by voice.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Nisaab converts your speech into transactions.</string>
```

### Run

```powershell
flutter devices
flutter run                                                          # Android emulator, defaults to http://10.0.2.2:8000
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000         # iOS simulator / desktop
flutter run --dart-define=API_BASE_URL=http://192.168.1.25:8000      # physical phone: use your PC's LAN IP (ipconfig)
flutter build apk --release --dart-define=API_BASE_URL=https://api.your-domain.pk
```

### Demo walkthrough

1. Tap **Try the demo account**. It needs `seed.py` to have been run.
2. **Home:** check net savings, quick stats, the forecast warning, the spending chart and recent transactions.
3. Type **"Spent 1,200 rupees on groceries at Carrefour"** and send. Review the 95%-confidence preview and save. Everything refreshes.
4. Tap 🎤 and say **"Careem ride to office, eight hundred fifty rupees"**.
5. **History:** search "careem", filter by category or date, tap a row to edit it in place, swipe left to delete.
6. **Budgets:** see the progress bars and projected month-end. Add a budget; the suggested limit comes from your history.
7. **Assistant:** ask "Where does most of my money go?" or "Can I afford Rs 20,000?".
8. **Profile** (avatar, top right): switch between light, dark and system themes, or log out.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| App says "Can't reach the Nisaab server" | The API isn't running, `API_BASE_URL` is wrong, the firewall is blocking it, or `usesCleartextTraffic` is missing on Android |
| API returns `503 Database unavailable` | Postgres is down or `DATABASE_URL` is wrong. Check `/health` |
| `docker compose up` says "Set POSTGRES_PASSWORD" | Create `.env` from `.env.example` |
| Login returns 401 for the demo account | Run `python seed.py` (or `docker compose exec api python seed.py`) |
| Assistant replies are tagged "Nisaab insights", not "Claude" | No `ANTHROPIC_API_KEY` is set, or Claude was unreachable and the rule engine answered instead. Check the API logs |
| Mic shows "not available" | Grant microphone permission. On the emulator, enable *Extended controls → Microphone → Virtual mic uses host audio input* |
| Changes to `schema.sql` aren't applied in Docker | The init script only runs on a fresh volume. Apply it manually (see 2A) |

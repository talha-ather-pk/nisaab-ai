# Nisaab AI — Project Status

*Last updated: 2026-10-19. Read this first when resuming work in a new session.*

## Context

- **Project:** Nisaab AI, a final-year capstone at KSBL (Department of Business Analytics) by Muhammad Usman Shahid and Talha Ather. It is a personal finance management and expense tracking mobile app for Pakistan.
- **Proposal:** `C:\Users\DELL\Downloads\Nisaab_AI_Project_Proposal-Final 1.docx`, covering RQ1 (classification), RQ2 (forecasting) and RQ3 (AI guidance and usability).
- **Deadline:** submission on Tuesday (stated 2026-10-18).
- **Stack (decided):** Flutter + Riverpod + Dio · FastAPI + SQLAlchemy 2 + psycopg 3 · PostgreSQL 17 · JWT/bcrypt · Claude (`claude-opus-5-5`) for the assistant, with a rule-engine fallback · Docker Compose.

## Current state: v1.0 feature-complete

| Area | Status | Verified |
|---|---|---|
| DB schema (`database/schema.sql`): users, transactions, budgets, savings_goals, ai_financial_logs, schema_migrations | ✅ Done, idempotent | ✅ Applied repeatedly to real **PostgreSQL 17.10**, including migration `2026.10.002` (savings_goals) on the live demo DB |
| Backend (`backend/`): auth, transactions CRUD/parse/filter/CSV export, budgets, savings goals, analytics summary, forecast, AI assistant + history, personal category learning | ✅ Done | ✅ **129 pytest tests pass** on SQLite **and on PostgreSQL 17.10** (`TEST_DATABASE_URL`). ✅ Live uvicorn on a schema.sql DB: seed, login, parse, create, edit, filter, delete, summary, forecast, budgets, assistant, history, 403 authz |
| NLP engine: amount, currency, merchant, category, type, date, spoken numbers, bank SMS | ✅ Done | ✅ Unit tests |
| Forecasting: month-end projection, risk, next-month forecast, recommended budgets | ✅ Done | ✅ Unit tests + seeded-data API test |
| Assistant: Claude provider + rule engine (12 intents, incl. savings goals) + logging | ✅ Done | ✅ Rules tested. Claude only **mocked**; no live API call yet |
| Flutter app (`mobile/lib/`): login/register, dashboard, history (search/filter/inline edit/CSV export), budgets, goals, AI chat, light/dark, "learned from your edits" hint | ✅ Done | ✅ `dart analyze`: no issues. ✅ **13 flutter tests pass**, incl. widget smoke tests at 393 dp and 360 dp with no layout overflows |
| RQ1/RQ2 evaluation (`backend/evaluate.py`, `backend/eval/labelled_transactions.csv`) | ✅ Done | ✅ Rule baseline on the 129-entry held-out set (constructed for the project, not user data): **80.6% accuracy (95% CI 72.9–87.6%), macro F1 0.834 (0.761–0.883)**. The CI includes values under 80%, so don't claim the target is "surpassed". Date-order learning replay + McNemar test, and user-level bootstrap CIs, are built and tested; they need pilot data (the demo DB has one synthetic user) |
| Docker (`docker-compose.yml`, `backend/Dockerfile`) | ✅ Written | ❌ **Never run.** Docker is not installed on this machine |
| Docs (`docs/USER_STORIES.md`, `DESIGN_DOCUMENT.md`, `TECHNICAL_DOCUMENT.md`) | ✅ Updated to v1.0 | — |
| README with full run guide | ✅ | — |

## Next steps (priority order)

1. ~~Run against real PostgreSQL~~ ✅ Done 2026-10-18 with portable EDB binaries (no Docker). **Still untested:** `docker compose` itself (Dockerfile/compose files), because Docker isn't installed.
2. **Run the Flutter app on an emulator or phone:**
   - `cd mobile && flutter create . --project-name nisaab_ai --org com.nisaab --platforms android,ios`
   - Edit the AndroidManifest (INTERNET, RECORD_AUDIO, speech `<queries>`, `usesCleartextTraffic`) and set `minSdk = 23`. See the README.
   - Delete the generated `test/widget_test.dart` sample.
   - Test voice input on a real device.
3. **Optional live Claude test:** set `ANTHROPIC_API_KEY` in `.env` and ask the assistant one question. Confirm the reply is tagged "Claude" and that `ai_financial_logs.provider = 'claude'`. Each question is a paid API call.
4. ✅ **Proposal docx text errors fixed** (2026-10-18). The corrected copy is `C:\Users\DELL\Downloads\Nisaab_AI_Project_Proposal-Final 2 (corrected).docx`, the original is untouched, and the file passes validation. Not changed: §3.2 "teenagers ... of 18-35 ages" (could be "young adults"). Fixed items:
   - §3.6 says "misclassification of **animals**".
   - §3.5 says "Mean **Squared** Error (MAE)"; it should be Mean Absolute Error.
   - §1.7 has the garbled "Users litters, have modern smartphone".
   - §1.7 says "Future spending information"; it should say historical.
   - §1.2 talks about "financial aid".
   - §2.3 calls the app "decentralized".
   - Typos: "fourweek", "Authentification", "NIsaab".
5. ✅ **Done 2026-10-19:** US-22 CSV export, US-26 savings goals, US-27 personal category learning (`personalization.py`), and `evaluate.py` (RQ1/RQ2 metrics).
6. ✅ **Pilot step 1 done (2026-10-19): research consent + account deletion.** Live DB migrated (`2026.10.003`). The demo account is marked `terms_version='demo'`. Before the pilot:
   - Have the supervisor or ethics contact review the consent text in `mobile/lib/core/terms.dart`.
   - Confirm the retention period. The text currently says nothing more specific than "the study".
   - ✅ **Pilot export + labelling pipeline done:** `export_pilot.py` and `labelling.py`; see README "Pilot gold set". Create the real key once with `--init-key` on the machine that will keep the data, and back it up. The live DB currently exports nothing (the demo is excluded, and the only real account hasn't consented), which is correct.
7. **Never tune `nlp_engine.py` on `eval/labelled_transactions.csv`:** it is the held-out test set. `test_evaluate.py` fails if accuracy or macro F1 drops below 0.80.
8. **Post-v1.0 backlog** (see `docs/USER_STORIES.md`):
   - Android SMS auto-read
   - A global TF-IDF + logistic-regression model trained on pooled pilot corrections
   - Refresh tokens
   - Alembic migrations
   - Urdu-script UI

## How to run tests

```powershell
# Backend (no Postgres needed: conftest.py uses a temp SQLite DB)
cd C:\Users\DELL\nisaab-ai\backend
.\.venv\Scripts\python -m pytest -q tests

# Flutter (needs a Flutter SDK, 3.32+)
cd C:\Users\DELL\nisaab-ai\mobile
flutter pub get
dart analyze lib test
flutter test
```

## Gotchas learned

- **Web prototype (2026-10-18):** `mobile/web/` was added with `flutter create . --platforms web`. To run it: `flutter build web --release` (no `API_BASE_URL`, so the web build calls its own origin), then start the API with `WEB_DIR=<repo>/mobile/build/web` and a real `JWT_SECRET`. One port (8000) then serves both the app and the API. For a shareable link, run `cloudflared tunnel --url http://localhost:8000` (the user runs it, because Claude's auto-mode blocks tunnels). The demo DB lives in the scratchpad Postgres cluster on port 55432. Voice input on web needs a mic permission prompt in Chrome. The SDK used was the old scratchpad copy at `C:\Users\DELL\AppData\Local\Temp\claude\C--Users-DELL\4e249bb7-...\scratchpad\flutter-sdk`.

- **Postgres without Docker:** the EDB zip `https://get.enterprisedb.com/postgresql/postgresql-17.10-1-windows-x64-binaries.zip` gives `initdb`/`pg_ctl`/`psql` with no installer. `pgserver` (pip) has no Python 3.14 wheel.

- **No Flutter on PATH.** A temporary SDK (Flutter 3.47.7) was cloned into the Claude session scratchpad and may be gone; install Flutter properly. `flutter analyze` failed there on the SDK's own long paths, but `dart analyze lib test` worked. Git needed `core.longpaths true`.
- **Backend venv:** `backend/.venv` uses Python 3.14, and all requirements are installed. `tzdata` is required on Windows for `Asia/Karachi`.
- **Settings:** the API reads `backend/.env` or real environment variables. Docker Compose reads the root `.env`. Copy `.env.example` to both places.
- **Postgres GROUP BY:** format strings in `forecasting.py` are inlined with `literal_column` so SELECT and GROUP BY match. Keep it that way.
- **Flutter tests:** the test font measures every glyph as a full square, so text runs wider than on a device. Use `Flexible` + ellipsis on text inside a `Row`.
- **Pinned packages:** `flutter_riverpod` is on **2.x** (the code uses `valueOrNull`, `StateProvider`), so don't bump to 3.x without migrating. `speech_to_text ^7.5.0` (listen options live in `SpeechListenOptions`). `dio ^5.9.0` (the error switch has a `default` for new types).
- **Two category lists:** the categories exist in both `backend/nlp_engine.py` (`CATEGORIES`) and `mobile/lib/core/categories.dart`. Keep them in sync.
- **Demo login:** `demo@nisaab.app` / `Demo@1234`, created by `python seed.py` (3 months of history plus 6 budgets).

## Key files

| Purpose | File |
|---|---|
| All API routes, middleware, error handlers | `backend/main.py` |
| NLP extraction | `backend/nlp_engine.py` |
| Forecast maths + SQL aggregation | `backend/forecasting.py` |
| Assistant (Claude + rules) | `backend/assistant.py` |
| App entry, themes, routes, AuthGate | `mobile/lib/main.dart` |
| HTTP client | `mobile/lib/services/api_service.dart` |
| State | `mobile/lib/providers/*.dart` |
| Widget smoke tests (fake backend) | `mobile/test/app_smoke_test.dart` |

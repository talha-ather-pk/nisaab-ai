# Nisaab AI — Technical Design Document

*Tech Lead view · v1.0 · October 2026*

## 1. Scope

This document covers the architecture, data model, API contract, AI components, security, quality strategy and deployment of Nisaab AI v1.0. It turns the three-layer architecture in the proposal (Figure 1) and the pipeline in Figure 2 into concrete, implemented decisions.

## 2. Technology decisions

| Layer | Choice | Why |
|---|---|---|
| Mobile | **Flutter 3.32+**, **Riverpod 2** (state), **Dio** (HTTP), **flutter_secure_storage** (JWT), **speech_to_text** | One codebase for Android and iOS. Riverpod gives testable, compile-safe state. Dio interceptors handle auth headers centrally. The token sits in the Keystore/Keychain |
| API | **FastAPI** (Python 3.12) | Same language as the ML stack. Pydantic validation and automatic OpenAPI docs |
| ORM / DB access | **SQLAlchemy 2.0** + **psycopg 3**, pooled | Typed ORM, connection pooling with pre-ping and recycle, portable queries (the test suite runs on SQLite) |
| Database | **PostgreSQL 17** | `NUMERIC` money, CHECK constraints, JSONB for AI logs |
| Auth | **bcrypt** (SHA-256 pre-hash) + **JWT HS256** | Stateless tokens suit a mobile client. The pre-hash avoids bcrypt's 72-byte limit |
| NLP | Rule-based extractor (regex, gazetteer, keyword scoring, spoken-number parser) | Deterministic and explainable, needs no training data, and produces labelled data from day one |
| Forecasting | Blended run-rate + weighted moving average | Works from the first week of data and is explainable to users |
| Assistant | **Claude** (`claude-opus-5-5`) grounded in a JSON snapshot of the user's data, with a deterministic rule engine as fallback | High-quality natural answers when a key is configured. Always works offline or without a key |
| Packaging | Docker (non-root, healthcheck) + Compose | One command for the whole stack |

## 3. Architecture

```
┌──────────────────────────── Flutter app ────────────────────────────┐
│ Screens: Login · Dashboard · History · Budgets · AI Chat            │
│ Providers (Riverpod): session · dashboard/forecast · transactions   │
│                       · budgets · chat · theme                       │
│ ApiService (Dio): bearer token interceptor, 401 → session expiry,   │
│                   typed models, FastAPI error → readable message     │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ HTTPS JSON  /api/v1/*
┌───────────────────────────────▼─────────────────────────────────────┐
│ FastAPI main.py                                                      │
│  middleware: request-id + timing log, CORS                           │
│  handlers: 401/403/404/409/422 · DB down → 503 · unknown → 500       │
│  security.py  ── JWT auth, ownership checks                          │
│  nlp_engine.py ── POST /transactions/parse                           │
│  forecasting.py ── /analytics/summary, /analytics/forecast           │
│  assistant.py ── /ai/assistant ──► Claude API (optional)             │
│  database.py ── SQLAlchemy pool (5 + 10 overflow, pre-ping)          │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ SQL
┌───────────────────────────────▼─────────────────────────────────────┐
│ PostgreSQL: users · transactions · budgets · ai_financial_logs       │
└──────────────────────────────────────────────────────────────────────┘
```

Parsing and saving are **separate calls**. That keeps the user's review step in the flow and makes every saved row a reviewed label.

## 4. Data model (`database/schema.sql`)

| Table | Key columns | Constraints and indexes |
|---|---|---|
| `users` | `email` (lower-case, unique), `password_hash`, `preferred_currency`, `monthly_income`, `is_active`, `last_login_at`, `terms_accepted_at`, `terms_version` (research consent, migration `2026.10.003`) | CHECK lower-case email, ISO currency, non-negative income |
| `transactions` | `amount NUMERIC(14,2)`, `currency`, `type`, `category`, `merchant`, `description`, `raw_text`, `source`, `ai_confidence`, `user_corrected`, `transaction_date` | CHECK `amount > 0`, `type ∈ {expense, income}`, `source ∈ {text, voice, sms, manual}`, confidence 0–1. Indexes: `(user_id, transaction_date DESC, id DESC)`, `(user_id, category, transaction_date)`, `(created_at)` |
| `budgets` | `category`, `monthly_limit`, `month_year DATE` (1st of month), `alert_threshold` | UNIQUE `(user_id, category, month_year)`, CHECK first day of month, threshold 1–100. Index `(user_id, month_year)` |
| `savings_goals` | `name`, `target_amount`, `saved_amount`, `currency`, `target_date` (optional) | CHECK target > 0, saved ≥ 0. Index `(user_id)`. Added in migration `2026.10.002` |
| `ai_financial_logs` | `interaction_type ∈ {parse, assistant, forecast}`, `input_text`, `output_text`, `intent`, `provider ∈ {rules, claude}`, `model`, `confidence`, `context JSONB`, `latency_ms`, tokens | Index `(user_id, created_at DESC)`, `(interaction_type, created_at DESC)` |
| `schema_migrations` | `version`, `applied_at` | Migration bookkeeping |

All foreign keys use `ON DELETE CASCADE`, so deleting a user removes all of their data. Every table has an `updated_at` trigger where applicable. The schema is idempotent and safe to re-run.

**Money:** stored as `NUMERIC` (exact), aggregated in SQL, and converted to JSON numbers only at the API boundary.

**Month filters** use half-open ranges (`date >= first AND date < next_first`) rather than `EXTRACT`, so the `(user_id, transaction_date)` index is used.

## 5. API contract (v1)

Full schema: `GET /docs`. All errors share one envelope: `{"detail": str | [{loc, msg, type}], "request_id": "…"}`. The `X-Request-ID` header is echoed on every response and appears in the server logs.

| Area | Endpoints |
|---|---|
| Auth | `POST /auth/register` (201; requires consent), `POST /auth/login`, `GET/PATCH /auth/me`, `POST /auth/me/accept-terms`, `DELETE /auth/me` (204; password required) |
| Transactions | `POST /transactions/parse`, `POST /transactions` (201), `GET /transactions/{user_id}` (paginated + filters + totals), `GET /transactions/{user_id}/export` (CSV), `PATCH/DELETE /transactions/{id}` |
| Budgets | `POST /budgets` (201 create / 200 update), `GET /budgets/{user_id}?month&year`, `DELETE /budgets/{id}` |
| Savings goals | `POST /goals` (201), `GET /goals/{user_id}`, `PATCH/DELETE /goals/{id}`, `POST /goals/{id}/contribute` (negative = withdrawal). Each goal returns `percent`, `remaining`, `monthly_needed` and `status` (`on_track`, `behind`, `completed`, `overdue`, `no_deadline`) |
| Analytics | `GET /analytics/summary/{user_id}`, `GET /analytics/forecast/{user_id}` |
| AI | `POST /ai/assistant`, `GET /ai/assistant/history` |
| System | `GET /health`, `GET /categories` |

**Validation rules on the server:**
- The category must be valid for the type. Income can only use Salary, Freelance, Transfers or Other.
- No future dates (one day of grace for timezone differences).
- Budgets only on spending categories.
- Passwords need at least 8 characters with a letter and a digit.

## 6. AI components

### 6.1 NLP pipeline (`nlp_engine.py`, proposal §3.4)

| Stage | Technique |
|---|---|
| Normalise | Collapse whitespace; keep the original for display |
| Spoken numbers | "twelve hundred" → 1200, "two thousand five hundred" → 2500, "ninety-nine" → 99. Bare "lakh" or "one" is left alone |
| Amount + currency | Regex for prefix/suffix currency (Rs, PKR, rupees, $, USD, AED, SAR, EUR, GBP, `/-`), comma grouping, k/thousand/hazar/lakh/crore/million. The first currency-tagged number wins, so bank SMS give the debit, not the balance. Numbers attached to letters or slashes (`xx1234`, `15/10/26`) are skipped |
| Type | Income vs. expense keyword counts (English + Roman Urdu) |
| Merchant | A gazetteer of 50+ Pakistani merchants, then a fallback to the phrase after "at / from / @" |
| Category | Keyword scoring across 15 categories combined with the merchant's category. Confidence is 0.95 when they agree, 0.80 for keywords only, 0.85 for merchant only, and 0.40 when nothing matched |
| Date | today, yesterday/kal, day before yesterday/parson, "on/last <weekday>", dd/mm[/yy]. Future dates are ignored |
| Output | Fields plus `confidence` and `missing_fields`, logged to `ai_financial_logs` |

### 6.2 Forecasting (`forecasting.py`, RQ2)

- **Month-end projection** = spent so far + remaining days × blended daily rate. The blend is `w · current run-rate + (1 − w) · trailing-3-month daily average`, where `w` = days elapsed ÷ days in month.
- **Lumpy categories** (Rent, Education, Utilities, Charity) are paid about once a month. For them the projection is `max(spent, historical average)`, so paying rent on the 5th doesn't project 6× rent.
- **Risk:** `exceeded` if spent > limit; `likely_over` if projected > limit; `at_risk` if spent ≥ alert threshold or projected ≥ 90% of the limit; otherwise `on_track`.
- **Next month:** a linearly weighted moving average of recent months plus this month's projection.
- **Recommended budget:** the weighted average × 1.05, rounded up to the next Rs 500.
- **New users:** months before the user's first activity are excluded, so averages aren't diluted by zeros.
- **Evaluation (RQ2):** MAE, RMSE and MAPE of the projection at day 10, 15 and 20 against the actual month-end, computed from `transactions` after the pilot.

### 6.3 Assistant (`assistant.py`, RQ3)

1. **Context snapshot** (computed per request): this month and last month by category, today and the last 7 days, budgets with status, forecast and alerts, and the last 10 transactions.
2. **Claude provider** (when `ANTHROPIC_API_KEY` is set):
   - Model `claude-opus-5-5`, effort `low` (chat latency).
   - A stable, cached system prompt with rules: ground every number in the context, PKR formatting, be brief, reply in the user's language, no specific investment products.
   - The context is sent as `<financial_context>` JSON inside the user turn, plus up to 20 prior turns from the client.
   - Server-side refusal fallback (`fallbacks: "default"`) is enabled.
   - Errors (authentication, rate limit, connection, 5xx, refusal) automatically fall back to the rule engine.
3. **Rule engine:** 12 intents. It covers greetings, help, savings goals (progress, monthly amount needed, and whether projected savings cover it), spending queries by category or period, top categories, budget status, forecasts, savings, income, affordability ("Can I afford Rs 20,000?"), recent transactions, advice, and a general overview. Advice is generated from the user's actual numbers: top-category share, food-delivery ratio, exceeded budgets, savings rate, and missing budgets with suggested limits.
4. **Logging:** every answer is logged with intent, provider, model, latency and tokens. The app shows which provider answered ("Claude" or "Nisaab insights").

### 6.4 Personal learning and evaluation (RQ1)

Every saved row carries `raw_text`, the final `category` and `user_corrected`; edits in the review sheet or the history screen set `user_corrected`.

**Personal learning (`personalization.py`).** On every parse, a per-user model is trained from that user's latest 500 transactions:
1. **Merchant memory:** a merchant the user re-labelled gets their category next time.
2. **Word model:** multinomial Naive Bayes over word tokens. Corrected rows count 3×.

The learned category replaces the rule engine's only when it disagrees, has probability ≥ 0.8, and is backed by at least one correction that shares a word with the text. One correction therefore can't take over unrelated text. The response carries `category_source: "personal"`, the app shows "Category learned from your earlier edits", and the log keeps the rule engine's original answer for comparison.

**Evaluation (`evaluate.py`).**
- **Offline:** `eval/labelled_transactions.csv` is a small held-out set of 129 entries across all 16 categories. It was constructed for the project, not collected from users. It gives accuracy, per-class precision/recall/F1 and macro F1. **Rule-engine baseline: 80.6% accuracy (95% CI 72.9–87.6%), macro F1 0.834 (0.761–0.883).** The point estimate meets the 0.80 target, but the interval does not rule out falling short, so this is a sanity check, not the final RQ1 result. Never tune rules on this set; use a separate development set for that.
- **Learning replay:** every user's saved transactions are replayed in the order they were entered. Each AI-parsed entry is classified by the rules alone and by rules plus personal learning, where the personal model only sees transactions saved *before* that entry, exactly as the live app would have. The report gives both accuracies, the gain with a confidence interval, the counts of wrong→right and right→wrong changes, and an exact McNemar test.
  - The label is the category the user finally saved. Entries never corrected keep the rule engine's guess as their label, which favours the rules, so the measured gain is conservative.
  - `user_corrected` is also set by amount or type edits, so the replay compares categories directly instead of trusting the flag.
  - The rule engine is re-run with today's code, not the version that was live at entry time.
- **Correction rate:** the share of AI-parsed transactions saved without a correction. Report it as a usage measure, not accuracy: users don't always fix a wrong category.
- **RQ2:** a backtest replays the day-15 month-end projection for every complete past month and reports MAE, RMSE and MAPE with a confidence interval.
- **Statistics:** intervals are 95% percentile bootstraps, 2,000 resamples with a fixed seed (`--bootstrap`, `--seed`). For real-user data (the replay and the backtest), whole users are resampled, because one person's entries are correlated. Treating entries as independent would make the intervals too narrow.
- **Final pilot test set (`export_pilot.py`, `labelling.py`):**
  - **Who:** consenting, non-demo users only, AI-parsed entries only.
  - **Pseudonyms:** `P` + HMAC-SHA256(key, user_id). The key lives outside the repo (default `~/.nisaab/pilot_export.key`), and the export records only a fingerprint of it.
  - **Masking:** phone numbers (mobile and landline), CNIC, IBAN, email, card and account numbers, including bank-masked ones such as `****1234`. Amounts and dates are left intact.
  - **Name review:** names can't be masked reliably, so a heuristic flags them (context words, honorifics, Roman-Urdu particles, about 80 common given names; names take precedence over merchant words). Flagged rows must be reviewed by hand before annotation sheets can be made.
  - **Sampling:** near-duplicates removed (texts differing only in numbers), at most 15 items per participant (calibration and test together), at least 10 per saved category, the rest drawn at random. 30 calibration items are kept separate and never enter the test set.
  - **Labelling:** two blind sheets, text only, each in a different random order, plus a labelling guide with draft decision rules.
  - **Agreement:** Cohen's κ with a bootstrap CI, Landis–Koch band, per-category specific agreement and one-vs-rest κ, and the most frequent confusions. Target κ ≥ 0.80.
  - **Freeze:** every disagreement needs an adjudicated `final_category`. Writes `eval/pilot/pilot_test_v1.csv` plus `.sha256` and a `.json` manifest, refuses to overwrite, and `evaluate.py --test-set` refuses a file whose checksum no longer matches.
  - **Location:** the frozen set is git-ignored on purpose, because it contains participant text.

**Future work:** a global `TF-IDF + LogisticRegression` model trained on pooled, pseudonymised pilot corrections, compared against the rule baseline using the same report.

## 7. Security

| Concern | Implementation |
|---|---|
| Passwords | bcrypt (cost 12) over SHA-256 pre-hash; strength validation |
| Sessions | JWT HS256 with `sub`, `iat`, `exp` and `type`, 7-day expiry; secret from env (min 32 chars) |
| Authorisation | Every `{user_id}` route checks it matches the token (403). Every `{id}` route checks ownership (404, so other users' ids can't be discovered) |
| Account enumeration | The same message for an unknown email and a wrong password |
| Token storage (app) | Android Keystore-backed encrypted prefs / iOS Keychain. A 401 clears it and returns the user to login |
| SQL injection | ORM / bound parameters only |
| Input validation | Pydantic: lengths, ranges, enums, category whitelist, currency format |
| Transport | HTTPS in production (reverse proxy). Cleartext only in Android debug builds |
| Containers | Non-root user, no secrets in the image, healthcheck |
| LLM | User data is sent to Claude only when the operator configures a key. The context is minimal (no names beyond first name, no email or phone). The system prompt treats the context as data, not instructions |
| Research consent | Registration requires accepting the terms. The server stores its own timestamp in `terms_accepted_at` and the text version in `terms_version` (it must equal `Settings.terms_version`, otherwise 409). Accounts without the current version get `terms_required: true`, and the app shows a consent screen before anything else. The text lives in `mobile/lib/core/terms.dart`; bump both versions together |
| Withdrawal / erasure | `DELETE /auth/me` re-checks the password, so a stolen session can't wipe an account, then deletes the user. Transactions, budgets, goals and AI logs go with it (ON DELETE CASCADE, covered by a test). Only the user id is logged |
| Shared demo account | `terms_version = 'demo'`: never asked for consent, never deletable (403), and must be excluded from research exports |
| Privacy for research | Exports include only users with `terms_accepted_at IS NOT NULL AND terms_version <> 'demo'`, and drop `full_name`, `email` and `phone` (pseudonymised `user_id`) |

## 8. Reliability and error handling

- **Server:**
  - The connection pool uses `pool_pre_ping`, so dropped connections are replaced transparently.
  - Database outage → 503 with a readable message. Integrity conflicts → 409. Unexpected errors → 500 with a request id, and the stack trace is logged rather than returned.
- **Client:**
  - Dio timeouts: 10 s to connect, 60 s to receive (the assistant can be slow).
  - Every `DioException` type maps to a user-facing sentence.
  - Every screen has loading, empty, error-with-retry and pull-to-refresh states.
- **Consistency:**
  - Any create, update or delete invalidates the dashboard, forecast, budgets and history providers, so totals never disagree between tabs.
  - Stale responses for superseded filter queries are discarded.

## 9. Testing

| Level | Tooling | Status |
|---|---|---|
| NLP unit | pytest (parametrised: typed, voice, currencies, SMS, dates) | ✅ |
| Forecasting unit | pytest (projection, lumpy categories, risk, WMA, recommendation) | ✅ |
| API end-to-end | FastAPI TestClient on SQLite: auth, ownership, CRUD, filters, pagination, budgets, savings goals, CSV export, personal learning, summary, forecast on seeded data, assistant (rules + mocked Claude + fallback), evaluation maths (bootstrap, McNemar, leakage-free replay), research consent, account deletion with cascade, pilot export (consent filter, masking, sampling) and labelling pipeline (κ, freeze, checksum) | ✅ **129 tests passing** |
| Flutter | `dart analyze` (no issues) + `flutter test`: 5 model/format unit tests and 8 widget tests. The consent tests cover: sign-up blocked without consent, the consent screen for older accounts, password-confirmed deletion, and no delete option on the demo account. The smoke tests log in, then exercise the dashboard, History (inline edit), Budgets, Goals, Assistant and the AI review sheet against a fake HTTP backend at 393 dp and 360 dp, in light and dark themes, and fail on any layout overflow | ✅ **13 tests passing** |
| PostgreSQL integration | The same suite with `TEST_DATABASE_URL=postgresql://…/nisaab_test pytest` | ✅ Passing on PostgreSQL 17.10 |
| Usability | SUS + task script (Design Document §9) | Pilot weeks 14–16 |

## 10. Deployment

- **Single-origin web build:** with `WEB_DIR=<repo>/mobile/build/web`, the API also serves the Flutter web app at `/`. The web build then calls its own origin, so one URL (or one HTTPS tunnel) serves both.
- **Local:** `docker compose up -d --build`. The schema is applied on first boot, and `seed.py` creates the demo data.
- **Pilot (40 users):**
  - API on a single VM or container host (Railway, Render, Fly, or a 1 vCPU VM) behind HTTPS.
  - Managed Postgres (Neon, Supabase or RDS) with daily backups.
  - `WEB_CONCURRENCY=2`.
- **App:** `flutter build apk --release --dart-define=API_BASE_URL=https://api.<domain>`, distributed through Firebase App Distribution.
- **Load:** 40 users × about 5 transactions a day is roughly 6,000 rows a month. Every dashboard query hits an index; no cache is needed.

## 11. Known limitations

| Item | Plan |
|---|---|
| Global classifier is rule-based (the personal model sits on top) | Global ML model trained on pilot corrections (§6.4) |
| No refresh tokens (7-day JWT) | Add refresh rotation before a public launch |
| `schema.sql` is a single versioned migration | Adopt Alembic for v1.1+ |
| Summaries assume a single currency (PKR) | Convert foreign-currency transactions at entry |
| SMS auto-read not implemented (the parser supports SMS text) | Android SMS permission flow, post-pilot |
| Category list duplicated in Dart and Python | Load from `GET /api/v1/categories` at startup |

## 12. Traceability to the proposal

| Proposal item | Implemented by |
|---|---|
| Objective 1: text/voice ingestion | `NlInputBar` (speech_to_text), `POST /transactions/parse`, spoken-number parser |
| Objective 2: automatic classification | `nlp_engine.extract_entities` plus per-user learning (`personalization.py`); measured by `evaluate.py` |
| Objective 3: forecasting | `forecasting.py`, `GET /analytics/forecast`, budget projections in the app |
| Objective 4: dashboard with trends, budgets, goals and alerts | Dashboard, Budgets, Goals and History screens; forecast alert banners; CSV export |
| Objective 5: pilot evaluation | `evaluate.py` (RQ1 accuracy/F1 with CIs, date-order learning replay with McNemar test, correction rate; RQ2 MAE/RMSE/MAPE with CI), `ai_financial_logs`, `user_corrected`, `source`; SUS plan |
| Figure 2, step 10: AI Financial Assistant | `assistant.py`, AI Chat screen |
| §3.6 privacy and risk | §7 |

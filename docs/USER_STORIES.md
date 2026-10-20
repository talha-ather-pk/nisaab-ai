# Nisaab AI — Product Backlog & User Stories

*Product Owner view · v1.0 release (capstone submission) · October 2026*

## 1. Product vision

> For young Pakistanis who juggle cash, bank cards and mobile wallets, **Nisaab** is a personal finance app that turns everyday language into an organised money picture. Unlike bank apps that only show a log of what happened, Nisaab categorises automatically, tracks budgets, and nudges you before you overspend.

**MVP goal:** a user can log a transaction in under 10 seconds by typing or speaking. They see it categorised correctly most of the time, and they always know where they stand against their monthly budgets.

## 2. Personas

| Persona | Profile | Main pain | What success looks like |
|---|---|---|---|
| **Ayesha, 21: university student** | Lahore. Allowance plus a tutoring income. Pays with cash and JazzCash. | Money "disappears" by the 20th. Forgets cash spends. | Logs chai and rickshaw rides in seconds. Sees a warning before the food budget runs out. |
| **Bilal, 27: freelancer** | Karachi. Fiverr/Upwork income in irregular chunks. | Can't tell what a "normal month" costs. Income and spending are mixed up. | Sees income vs. spend each month and knows how much he actually saved. |
| **Sana, 31: young professional** | Islamabad. Salaried. Pays bills, rent and fuel. | Bills and fuel creep up and she only notices at month end. | Sets category budgets once and gets nudged at 80%. |

## 3. Epics

| ID | Epic | v1.0 status |
|---|---|---|
| E1 | Conversational transaction capture (text/voice) | ✅ Built |
| E2 | AI extraction & categorisation with user review | ✅ Built |
| E3 | Transaction history & management (search, filter, inline edit) | ✅ Built |
| E4 | Budgets & overspending nudges | ✅ Built (incl. budget editor) |
| E5 | Monthly dashboard & insights | ✅ Built |
| E6 | Accounts & authentication | ✅ Built (email + password, JWT) |
| E7 | Bank SMS ingestion | Parser handles SMS text; automatic SMS reading is post-pilot |
| E8 | Expense forecasting & budget recommendations | ✅ Built |
| E9 | AI financial assistant (Q&A) | ✅ Built (Claude, with a rule-engine fallback) |

## 4. User stories

Priority uses MoSCoW (**M**ust, **S**hould, **C**ould, **W**on't-this-release). Points use the Fibonacci scale.

### E1: Conversational capture

**US-01 · Log an expense by typing** · M · 3 pts
*As a* student, *I want to* type "Spent 500 on chai" *so that* I can record spending without filling in a form.
- **Given** I'm on the dashboard, **when** I type a sentence and tap send, **then** a review sheet opens within 2 s with the extracted amount, category and merchant.
- **Given** I typed "1,200", "Rs. 1200", "1.2k" or "1200/-", **then** the amount is 1,200.
- **Given** the backend is unreachable, **then** I see a clear error and my text is not lost.

**US-02 · Log an expense by voice** · S · 5 pts
*As a* busy professional, *I want to* say my expense *so that* I can log it hands-free right after paying.
- **Given** I tap the mic and grant permission, **when** I speak, **then** my words appear live in the input bar.
- **When** I stop speaking for 3 s, **then** the text is sent automatically and the transaction source is saved as `voice`.
- **Given** permission is denied or speech isn't supported, **then** I see a message and can still type.

**US-03 · Add a transaction manually** · M · 2 pts
*As a* user, *I want* a plain form *so that* I can add something the AI can't parse.
- Tapping ＋ opens an empty sheet with Expense/Income, amount, category, merchant, description and date.

### E2: AI extraction & review

**US-04 · Review and correct before saving** · M · 5 pts
*As a* user, *I want to* see and edit what the AI understood *so that* wrong guesses never reach my records.
- The sheet shows a confidence badge: green ≥ 80% ("Looks right"), amber 50–79%, red < 50% ("Needs your input").
- Fields the AI couldn't find are listed ("Couldn't find: amount").
- Every field is editable. If I change anything, the saved record is marked `user_corrected = true`, which becomes training data.
- I can't save without a positive amount.

**US-05 · Automatic categorisation for local merchants** · M · 3 pts
*As a* user in Pakistan, *I want* Carrefour, Careem, K-Electric, Jazz, Foodpanda and similar merchants recognised *so that* I rarely fix categories.
- At least 40 common Pakistani merchants map to categories.
- Roman-Urdu keywords such as *sabzi, doodh, kiraya, bijli, dawai* map to the right category.
- **Target:** at least 80% of pilot entries saved without a category correction (measured from `user_corrected`, which answers RQ1).

**US-06 · Detect income vs. expense** · M · 2 pts
- "Received salary 150,000", "Got 25k from Upwork" and "credited" are detected as **income**. Everything else defaults to expense.

**US-07 · Understand relative dates** · C · 1 pt
- "yesterday" is set to today − 1, and "15/10/26" becomes 15 Oct 2026. Otherwise the date is today. It is always editable.

### E3: History & management

**US-08 · See recent transactions** · M · 2 pts
- The dashboard lists the latest 15, newest first. Each shows the merchant or description, the category icon, a relative date, and a signed amount (income shown in green).
- Entries made by voice, text or SMS show a small source icon.

**US-09 · Delete a wrong transaction** · S · 2 pts
- Swiping left asks for confirmation, then deletes. Totals and budgets refresh.

**US-10 · Filter history** · C · 3 pts
- Delivered as the History tab (see US-24).

### E4: Budgets & nudges

**US-11 · Set a monthly category budget** · M · 3 pts
*As* Sana, *I want to* set "Fuel: Rs 15,000 per month" *so that* I control recurring costs.
- Setting a budget for the same category and month again updates it rather than creating a duplicate.
- Budgets can't be set on income categories.
- Set from the Budgets tab (see US-16).

**US-12 · See budget progress** · M · 2 pts
- Each budget shows spent / limit with a bar: green below 80%, amber at 80–100%, red over 100%.

**US-13 · Get nudged before overspending** · M · 2 pts
*As* Ayesha, *I want* a warning when I'm close to a limit *so that* I adjust before month end.
- At ≥ 80% used, an amber banner reads "You've used 85% of your Food & Dining budget."
- Over the limit, a red banner reads "You're Rs 2,300 over your Groceries budget."

### E5: Dashboard

**US-14 · Monthly summary at a glance** · M · 3 pts
- Shows net savings (income − spend), savings rate %, total income and total spent for the current month.
- Quick stats: number of entries, daily average spend, top spending category.
- Pull-to-refresh reloads everything.

### E6–E9: Delivered in v1.0

| ID | Story | Priority | Pts | Acceptance highlights |
|---|---|---|---|---|
| US-15 | Sign up and log in with email + password | M | 5 | Password needs 8+ characters with a letter and a number. The session survives app restarts. An expired token returns the user to login. The same error is shown for a wrong email or password |
| US-16 | Budget editor screen | M | 3 | Add, edit and remove limits per month. Shows a suggested limit from history. Alert threshold from 50–100% |
| US-18 | Forecast month-end spending per category | S | 8 | Each budget shows its projected month-end. A warning appears when it will likely go over |
| US-19 | Recommend budgets from history | C | 5 | Shown in the empty Budgets state and the budget form |
| US-20 | Ask "How much did I spend on food this month?" | S | 8 | The answer uses only the user's data, supports English and Roman Urdu, and shows which provider answered |
| US-24 | Search, filter and inline-edit history | S | 5 | Search by merchant or note. Filter by type, category and date range. Tap a row to edit it in place |
| US-25 | Light and dark themes | C | 2 | System, Light and Dark options in the profile sheet |
| US-22 | Export to CSV | C | 2 | History → download icon. Mobile opens the share sheet, the browser downloads the file. Opens correctly in Excel (UTF-8 BOM) |
| US-26 | Savings goals (e.g. "Laptop: Rs 150,000 by June") | S | 5 | Goals tab: create, edit, add or withdraw money. Shows % saved, the monthly amount needed and whether the user is on track. The assistant answers "Am I on track for my goals?" |
| US-28 | Research consent and account deletion | M | 3 | Sign-up needs an explicit consent tick (with the full terms one tap away). Older accounts must accept before continuing. Profile → Delete account, confirmed with the password, erases everything permanently |
| US-27 | The app learns from my category corrections | S | 5 | After I re-label a merchant or phrase once, the next entry like it gets my category and is marked "learned from your edits". Other users are unaffected |

### Post-v1.0 backlog

| ID | Story | Priority | Pts |
|---|---|---|---|
| US-17 | Read bank/wallet SMS (Android) and propose transactions | S | 8 |
| US-21 | Urdu-script UI | C | 5 |
| US-23 | Direct bank API integration | W | — |

## 5. Release scope

**v1.0 (submission):** US-01 to US-16, US-18 to US-20 and US-22 to US-28.
**Not in v1.0:** automatic SMS reading, Urdu-script UI and bank APIs.

## 6. Definition of Done

- The acceptance criteria pass on an Android emulator against a live backend and database.
- Backend tests pass (`pytest -q`). New parsing rules come with a test case.
- There is no unhandled error path: network, database-down and validation errors show a readable message.
- The API is documented automatically at `/docs`.
- The demo script in the README runs end to end.

## 7. Success metrics for the pilot (from the proposal)

| Metric | Source | Target | Research question |
|---|---|---|---|
| Category accuracy (no correction) | `transactions.user_corrected` | ≥ 80% | RQ1 |
| Macro F1 on a labelled test set | Offline evaluation | ≥ 0.80 | RQ1 |
| Median time to log | Task-completion timing | < 10 s | RQ3 |
| SUS score | Survey | ≥ 70 ("good") | RQ3 |
| Weekly active loggers | DB | ≥ 60% of 40 testers | RQ3 |
| Forecast MAPE (day-15 projection vs actual) | Held-out month | ≤ 20% | RQ2 |

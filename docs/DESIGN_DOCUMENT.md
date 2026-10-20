# Nisaab AI — UI/UX Design Document

*UI/UX Advisor view · MVP · October 2026*

## 1. Design principles

1. **Talk, don't fill forms.** The main action is one sentence in a chat-style bar. Forms exist only to confirm what the AI understood.
2. **The AI suggests and the user decides.** Nothing the AI extracts is saved until the user has reviewed it. Confidence is shown honestly, with colour and plain words.
3. **One glance, one truth.** The first screen answers "Am I okay this month?" before anything else.
4. **Nudge, don't nag.** Warnings appear only when a budget reaches 80%, and they are specific: they name the category and the rupee amount. That matches the behavioural-nudge framing in the proposal.
5. **Built for Pakistan.** It uses rupees ("Rs") with comma grouping, recognises local merchants, understands Roman-Urdu words, greets the user with "Assalam-o-Alaikum", and works well on mid-range Android phones.

## 2. Information architecture (v1.0)

```
Splash ─► Login / Register  (or "Try the demo account")
            │
            ▼
Home shell: bottom navigation (state kept per tab)
├── Home (Dashboard)
│   ├── Net-savings hero · income / spent (vs last month)
│   ├── Quick stats: entries · daily avg · projected month-end
│   ├── Forecast nudge banner (conditional)
│   ├── "Where your money went": ranked category bars (top 5 + Other)
│   ├── Recent transactions → "See all" opens History
│   └── Persistent input bar: text · 🎤 voice · ＋ manual ─► Review sheet ─► Save
├── History
│   ├── Search · type chips · category picker · date-range picker · clear
│   ├── Totals strip (filtered income / spent / net)
│   └── Day-grouped list, infinite scroll; tap = inline editor, swipe = delete
├── Budgets
│   ├── Month switcher · total budgeted card · forecast alerts
│   ├── Per-category cards: status label, bar, remaining, projected month-end
│   └── Add/Edit sheet: category, limit (suggested from history), alert threshold
└── Assistant
    ├── Starter prompts (empty state) · saved conversation
    ├── Bubbles labelled "Claude" or "Nisaab insights" · typing indicator · retry
    └── Follow-up suggestion chips
Profile sheet (avatar in every app bar): account · theme (System/Light/Dark) · log out
```

## 3. Key flows

### F1: Log by text (happy path, ≤ 10 s)

1. Tap the input bar and type "Spent 1,200 on groceries at Carrefour", then tap ↑.
2. A spinner replaces the send button while the API parses (target < 1 s).
3. The review sheet slides up with the banner "AI preview · Looks right · 95%", the original sentence in italics, and the fields filled in.
4. Tap **Save transaction**. The sheet closes, a snackbar confirms "Saved Rs 1,200 · Groceries", and the summary, budget bar and list update.

### F2: Log by voice

1. Tap 🎤. The first time, the system asks for microphone permission.
2. The hint text changes to "Listening…" and the mic icon becomes a red stop button.
3. The transcript fills in as the user speaks. After a 3-second pause it is sent automatically and the review sheet opens, as in F1.

### F3: Low-confidence correction

- If the parser misses the amount, the banner turns red ("Needs your input · 30%") with "Couldn't find: amount". The amount field is empty, and Save shows the inline error "Enter an amount".

### F4: Overspending nudge

- When a save pushes a category past 80%, the next dashboard refresh shows an amber banner. Past 100%, it turns red and gives the overrun in rupees.

## 4. Screen specifications

### 4.1 Dashboard (Home tab)

| Zone | Content | Notes |
|---|---|---|
| App bar | Logo mark (navy rounded square, bar-chart glyph), "Nisaab", refresh | Background matches the page so it feels light |
| Greeting | "Assalam-o-Alaikum" + "Here's your October 2026 overview" | Sets the period context |
| Summary card | Net savings (32 pt, bold), savings-rate line, Income ↙ / Spent ↗ | Navy gradient, the visual anchor. Shows "−" in a red tint when negative |
| Quick stats | 3 equal tiles: Entries · Daily avg · Top spend | White cards, 16 px radius |
| Nudge banner | Only when a budget is ≥ 80% | Amber or red, 10% tinted background |
| Budgets | Category icon, name, "spent / limit", 8 px progress bar | Bar is green, amber or red by status |
| Recent | Avatar with category colour, title, "Category · Today", signed amount | Income green with "+"; expense navy with "−". Swipe left to delete |
| Input bar | ＋ · text field · 🎤 · ↑ | Floats above the keyboard, 28 px radius pill with a soft navy shadow |

### 4.2 Review / add sheet

Fields in order of importance:
1. **AI banner**: confidence, original text, missing fields
2. **Expense | Income** segmented control
3. **Amount**: large bold digits with an "Rs" prefix and numeric keypad
4. **Category**: dropdown with a coloured icon for each option. The list changes with the type: income shows Salary, Freelance, Transfers and Other.
5. Merchant (labelled "From" for income), Description, Date (picker, no future dates)
6. Full-width primary button, 52 px tall, "Save transaction"; while saving it shows "Saving…" with a spinner

### 4.3 States

| State | Treatment |
|---|---|
| Loading (first load) | Centred spinner |
| Refreshing | Pull-to-refresh indicator; content stays visible |
| Server unreachable | Cloud-off icon, message naming the server address, **Try again** button |
| Empty history | Speech-bubble icon: "No transactions yet. Type or say something like 'Spent 500 on chai' below." This teaches the input pattern. |
| Save error | Inline red text above the button; the sheet stays open and nothing is lost |
| Parse error | Red floating snackbar; the typed text is kept |

### 4.4 History

| Zone | Content | Notes |
|---|---|---|
| Search | "Search merchant, note or category" | Debounced 400 ms. The clear (×) button resets it |
| Filter chips | All / Expenses / Income · Category · Date range · Clear | One row that scrolls sideways. Active chips are shown selected |
| Totals strip | Income · Spent · Net | Labels change to "(filtered)" while a filter is active |
| List | Day headers (Today, Yesterday, "Monday, 12 October") then rows | Infinite scroll in pages of 25; a count is shown at the end |
| Inline editor | Expands the row in place: type, amount, category, merchant, note, date, Delete / Cancel / Save | Shows the original AI text in italics. Swiping is disabled while editing |

### 4.5 Budgets

| Zone | Content | Notes |
|---|---|---|
| Month switcher | ‹ October 2026 › | Can't go into the future. Past months are read-only history |
| Total card | "Rs 61,200 of Rs 80,000", status label, bar, "Rs 18,800 left · 77% used · day 18 of 31" | The status label always has an icon and text |
| Alerts | Up to 3 forecast messages | Amber when at risk, red when likely or already over |
| Category card | Avatar, name, status label, spent / limit, bar, remaining, **projected month-end** coloured by risk | Tap or ⋮ to edit; ⋮ also offers remove |
| Form sheet | Category (only those without a budget), limit, "Suggested from your history" chip, alert-threshold slider (50–100%) | |

### 4.6 Assistant

| Zone | Content | Notes |
|---|---|---|
| Empty state | Icon, "Ask me about your money", 4 starter prompts, disclaimer | Doubles as onboarding |
| Bubbles | User on the right (primary colour); assistant on the left (surface) with time and provider ("Claude" or "Nisaab insights") | Long-press to copy. Errors show in a red bubble with **Retry** |
| Typing | Three-dot animated bubble | Has a screen-reader label |
| Suggestions | Chips from the last reply's intent | Hidden while sending |

## 5. Visual design tokens

### Colour

| Token | Hex | Use |
|---|---|---|
| `navy` | `#0F2A4A` | Primary, text headings, buttons, brand |
| `navyLight` | `#1E4A7A` | Gradient end |
| `green` | `#2E9E5B` | Income, healthy budgets, "Looks right" (from the logo leaf) |
| `amber` | `#E8A33D` | Warning (≥ 80%) |
| `red` | `#D64545` | Exceeded, errors, destructive actions |
| `surface` | `#F5F7FA` | Page background |
| `muted` | `#6B7A90` | Secondary text |

Each of the 16 categories has a fixed icon and colour (see `CategoryStyle` in `lib/theme.dart`), so users learn to recognise them by colour.

### Dark mode

Dark mode has its own set of steps, not an automatic inversion: page `#0F161F`, cards and sheets `#18212D`, borders `#223246`. The text and status colours are lifted versions (income `#5FD08E`, warning `#F2B65A`, critical `#FF7B7B`). Users choose System, Light or Dark in the profile sheet, and the choice is remembered.

### Charts

The spending distribution uses **ranked horizontal bars in one hue** (light `#2B5C93`, dark `#4F94E8`). Both colours were checked with a palette validator against their surfaces for lightness, chroma and contrast. Each row has:
- the category icon and name, which carry identity, so colour is never the only cue;
- the amount and share as text;
- 8 px bars with rounded ends.

Only the top 5 categories get their own row; the rest are grouped as "Other". Tapping a row shows a tooltip with the transaction count. A 16-slice pie was rejected because it can't be read at phone width.

### Typography (Material 3 default, Roboto / SF)

| Role | Size / weight |
|---|---|
| Hero amount | 32 / 800 |
| Section title | 16 / 700 navy |
| Body | 14–16 / 400 |
| Caption | 12 / 400 muted |

### Shape and spacing

- 4-pt grid; 16 px page padding; 10–14 px gaps between cards
- Radius: cards 16, summary card 20, sheet top 24, input pill 28, inputs 12

## 6. Microcopy

| Moment | Copy |
|---|---|
| Input hint | "e.g. Spent 1,200 on groceries at Carrefour" |
| Listening | "Listening…" |
| High confidence | "AI preview · Looks right" |
| Medium | "AI preview · Please double-check" |
| Low | "AI preview · Needs your input" |
| Saved | "Saved Rs 1,200 · Groceries" |
| Warning nudge | "You've used 85% of your Food & Dining budget." |
| Over nudge | "You're Rs 2,300 over your Groceries budget." |
| Positive savings | "You kept 32% of your income" |

Tone: friendly, short, no blame, and always gives a number.

## 7. Accessibility

- Text contrast meets WCAG AA: navy on white is about 14:1; white on the navy card is above 12:1.
- Status is never shown by colour alone: banners and budgets always include words or numbers.
- Every icon-only button has a tooltip, which is its screen-reader label (Add manually, Speak, Send, Refresh).
- Touch targets are at least 44 × 44 px.
- Respects the system text size, and layouts use `Expanded` and ellipsis so larger text doesn't overflow.

## 8. Localisation roadmap

- **MVP:** English UI; the parser understands Roman-Urdu keywords.
- **Next:** Urdu UI strings via `flutter_localizations` with RTL support, Urdu speech locale (`ur-PK`), and lakh-style grouping (1,50,000) as a user setting.

## 9. Usability evaluation plan (supports RQ3)

| Task | Success criterion | Measure |
|---|---|---|
| T1: Log "Spent 750 on lunch" by typing | Saved with the correct category | Time, errors |
| T2: Log a ride by voice | Saved with source = voice | Time, retries |
| T3: Fix a wrong category before saving | `user_corrected = true` | Completion |
| T4: Tell whether you're over budget this month | Correct verbal answer | Time to answer |
| T5: Delete a transaction | Removed and totals updated | Completion |

After the tasks: the 10-item **System Usability Scale** (target ≥ 70), plus a five-minute interview on trust in the AI suggestions.

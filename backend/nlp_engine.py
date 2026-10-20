"""
Nisaab NLP engine: rule-based entity extraction for Pakistani personal-finance text.

Extracts amount, currency, merchant, category, transaction type, date and a description
from typed text, voice transcripts ("twelve hundred rupees") and bank/wallet SMS.

Pipeline (proposal §3.4): normalise -> spoken-number conversion -> tokenised regex
entity extraction -> gazetteer + keyword classification -> consistency rules -> confidence.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from typing import Literal, Optional

TransactionType = Literal["expense", "income"]

# =============================================================================
# Vocabulary
# =============================================================================

CATEGORIES: list[str] = [
    "Groceries", "Food & Dining", "Transport", "Fuel", "Utilities",
    "Mobile & Internet", "Shopping", "Health", "Education", "Entertainment",
    "Rent", "Charity", "Transfers", "Salary", "Freelance", "Other",
]
INCOME_CATEGORIES: list[str] = ["Salary", "Freelance", "Transfers", "Other"]
EXPENSE_CATEGORIES: list[str] = [c for c in CATEGORIES if c not in ("Salary", "Freelance")]

# Merchants common in Pakistan -> (display name, category). Keys are regex fragments.
KNOWN_MERCHANTS: dict[str, tuple[str, str]] = {
    r"carrefour": ("Carrefour", "Groceries"),
    r"imtiaz": ("Imtiaz", "Groceries"),
    r"naheed": ("Naheed", "Groceries"),
    r"chase\s*up": ("Chase Up", "Groceries"),
    r"al[\s-]?fatah": ("Al-Fatah", "Groceries"),
    r"metro": ("Metro", "Groceries"),
    r"hyperstar": ("Hyperstar", "Groceries"),
    r"foodpanda": ("Foodpanda", "Food & Dining"),
    r"kfc": ("KFC", "Food & Dining"),
    r"mcdonald'?s": ("McDonald's", "Food & Dining"),
    r"subway": ("Subway", "Food & Dining"),
    r"hardee'?s": ("Hardee's", "Food & Dining"),
    r"savour\s*foods": ("Savour Foods", "Food & Dining"),
    r"careem": ("Careem", "Transport"),
    r"uber": ("Uber", "Transport"),
    r"bykea": ("Bykea", "Transport"),
    r"indrive|indriver": ("inDrive", "Transport"),
    r"yango": ("Yango", "Transport"),
    r"daewoo": ("Daewoo Express", "Transport"),
    r"pso": ("PSO", "Fuel"),
    r"shell": ("Shell", "Fuel"),
    r"total\s*parco|totalenergies": ("TotalEnergies", "Fuel"),
    r"attock": ("Attock Petroleum", "Fuel"),
    r"k[\s-]?electric|ke\s+bill": ("K-Electric", "Utilities"),
    r"lesco": ("LESCO", "Utilities"),
    r"iesco": ("IESCO", "Utilities"),
    r"mepco": ("MEPCO", "Utilities"),
    r"ssgc|sui\s*southern": ("SSGC", "Utilities"),
    r"sngpl|sui\s*northern": ("SNGPL", "Utilities"),
    r"kwsc|water\s*board": ("KW&SC", "Utilities"),
    r"ptcl": ("PTCL", "Mobile & Internet"),
    r"jazz": ("Jazz", "Mobile & Internet"),
    r"zong": ("Zong", "Mobile & Internet"),
    r"telenor": ("Telenor", "Mobile & Internet"),
    r"ufone": ("Ufone", "Mobile & Internet"),
    r"stormfiber|storm\s*fiber": ("StormFiber", "Mobile & Internet"),
    r"nayatel": ("Nayatel", "Mobile & Internet"),
    r"daraz": ("Daraz", "Shopping"),
    r"khaadi": ("Khaadi", "Shopping"),
    r"gul\s*ahmed": ("Gul Ahmed", "Shopping"),
    r"junaid\s*jamshed": ("J.", "Shopping"),
    r"outfitters": ("Outfitters", "Shopping"),
    r"netflix": ("Netflix", "Entertainment"),
    r"spotify": ("Spotify", "Entertainment"),
    r"cinepax|nueplex": ("Cinema", "Entertainment"),
    r"dvago|servaid|fazal\s*din": ("Pharmacy", "Health"),
    r"chughtai": ("Chughtai Lab", "Health"),
    r"fiverr": ("Fiverr", "Freelance"),
    r"upwork": ("Upwork", "Freelance"),
    r"payoneer": ("Payoneer", "Freelance"),
    r"edhi": ("Edhi Foundation", "Charity"),
    r"shaukat\s*khanum": ("Shaukat Khanum", "Charity"),
    r"saylani": ("Saylani", "Charity"),
}

# Category keywords (English + common Roman Urdu).
CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "Groceries": ["grocery", "groceries", "sabzi", "vegetables", "fruit", "fruits", "milk", "doodh",
                  "atta", "flour", "rice", "chawal", "eggs", "anday", "bread", "ration", "kiryana", "mart"],
    "Food & Dining": ["lunch", "dinner", "breakfast", "nashta", "khana", "food", "restaurant", "cafe",
                      "coffee", "chai", "tea", "pizza", "burger", "biryani", "shawarma", "snacks", "dhaba"],
    "Transport": ["ride", "taxi", "cab", "rickshaw", "auto", "bus", "metro bus", "train", "fare",
                  "parking", "toll", "motorway", "flight", "ticket"],
    "Fuel": ["petrol", "fuel", "diesel", "cng", "gas station", "pump"],
    "Utilities": ["electricity", "bijli", "light bill", "gas bill", "water bill", "utility", "utilities"],
    "Mobile & Internet": ["internet", "wifi", "wi-fi", "broadband", "mobile load", "load", "easyload",
                          "balance", "package", "recharge", "data bundle"],
    "Shopping": ["clothes", "kapray", "shoes", "shopping", "dress", "shirt", "electronics", "gadget",
                 "mobile phone", "laptop", "online order"],
    "Health": ["medicine", "dawai", "doctor", "hospital", "clinic", "pharmacy", "lab test", "dentist"],
    "Education": ["fee", "fees", "tuition", "books", "course", "university", "school", "college",
                  "stationery", "semester"],
    "Entertainment": ["movie", "cinema", "netflix", "game", "games", "concert", "outing", "subscription"],
    "Rent": ["rent", "kiraya", "hostel"],
    "Charity": ["charity", "sadqa", "sadaqah", "zakat", "donation", "khairat"],
    "Transfers": ["transfer", "sent to", "jazzcash", "easypaisa", "ibft", "raast", "committee"],
    "Salary": ["salary", "tankhwah", "payroll", "stipend"],
    "Freelance": ["freelance", "fiverr", "upwork", "client payment", "project payment"],
}

INCOME_KEYWORDS = [
    "received", "receive", "got paid", "earned", "earn", "salary", "credited", "income",
    "stipend", "refund", "cashback", "bonus", "profit", "mila", "mili", "aaye", "aya",
]
EXPENSE_KEYWORDS = [
    "spent", "spend", "paid", "pay", "bought", "buy", "purchase", "purchased", "debited",
    "kharch", "diye", "diya", "bill", "sent",
]

CURRENCY_ALIASES: dict[str, str] = {
    "rs": "PKR", "rs.": "PKR", "pkr": "PKR", "rupee": "PKR", "rupees": "PKR", "rupay": "PKR",
    "rupaye": "PKR", "₨": "PKR",
    "$": "USD", "usd": "USD", "dollar": "USD", "dollars": "USD",
    "€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR",
    "£": "GBP", "gbp": "GBP", "pound": "GBP", "pounds": "GBP",
    "aed": "AED", "dirham": "AED", "dirhams": "AED",
    "sar": "SAR", "riyal": "SAR", "riyals": "SAR",
}

# =============================================================================
# Spoken numbers (voice transcripts)
# =============================================================================

_UNITS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
}
_TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90,
}
_SCALES = {
    "hundred": 100, "thousand": 1_000, "hazar": 1_000, "hazaar": 1_000, "lakh": 100_000,
    "lac": 100_000, "million": 1_000_000, "crore": 10_000_000,
}
_NUMBER_WORDS = set(_UNITS) | set(_TENS) | set(_SCALES)


def _words_to_number(tokens: list[str]) -> Optional[Decimal]:
    total = Decimal(0)
    current = Decimal(0)
    seen = False
    for tok in tokens:
        if tok == "and":
            continue
        if re.fullmatch(r"\d+(?:\.\d+)?", tok):
            current += Decimal(tok)
        elif tok in _UNITS:
            current += _UNITS[tok]
        elif tok in _TENS:
            current += _TENS[tok]
        elif tok == "hundred":
            current = (current or 1) * 100
        elif tok in _SCALES:
            total += (current or 1) * _SCALES[tok]
            current = Decimal(0)
        else:
            return None
        seen = True
    return total + current if seen else None


def normalize_spoken_numbers(text: str) -> str:
    """'twelve hundred rupees' -> '1200 rupees'; '2 thousand five hundred' -> '2500'."""
    text = re.sub(
        r"\b(" + "|".join(_TENS) + r")-(" + "|".join(k for k in _UNITS if _UNITS[k] < 10) + r")\b",
        r"\1 \2", text, flags=re.IGNORECASE,
    )
    words = text.split(" ")
    out: list[str] = []
    i = 0

    def bare(w: str) -> str:
        return w.lower().strip(",.!?;:")

    while i < len(words):
        w = bare(words[i])
        starts_run = w in _NUMBER_WORDS or (
            re.fullmatch(r"\d+(?:\.\d+)?", w) is not None
            and i + 1 < len(words) and bare(words[i + 1]) in _SCALES and bare(words[i + 1]) != "hundred"
            and i + 2 < len(words) and bare(words[i + 2]) in _NUMBER_WORDS
        )
        if not starts_run:
            out.append(words[i])
            i += 1
            continue
        j = i
        run: list[str] = []
        while j < len(words):
            t = bare(words[j])
            if t in _NUMBER_WORDS or (j == i and re.fullmatch(r"\d+(?:\.\d+)?", t)):
                run.append(t)
            elif t == "and" and run and j + 1 < len(words) and bare(words[j + 1]) in _NUMBER_WORDS:
                run.append(t)
            else:
                break
            j += 1
        value = _words_to_number(run)
        has_quantity = any(t in _UNITS or t in _TENS or t[0].isdigit() for t in run)
        # Skip bare scale words ("2 lakh" is handled by the amount regex) and a lone "one",
        # which is usually a pronoun ("the one at Carrefour").
        if value is None or not has_quantity or (len(run) == 1 and run[0] == "one"):
            out.append(words[i])
            i += 1
            continue
        trailing = re.search(r"[,.!?;:]*$", words[j - 1]).group(0)
        out.append(f"{value.normalize():f}{trailing}")
        i = j
    return " ".join(out)


# =============================================================================
# Regexes
# =============================================================================

_CURRENCY = r"(?:rs\.?|pkr|rupees?|rupay|rupaye|₨|usd|\$|dollars?|eur|€|euros?|gbp|£|pounds?|aed|dirhams?|sar|riyals?)"
_AMOUNT_RE = re.compile(
    rf"(?:(?P<pre>{_CURRENCY})\s*)?"
    r"(?P<num>\d{1,3}(?:,\d{2,3})+(?:\.\d+)?|\d+(?:\.\d+)?)"
    r"\s*(?P<mult>k|thousand|hazar|hazaar|lakh|lac|crore|million)?\b"
    rf"(?:\s*(?P<post>{_CURRENCY}|/-))?",
    re.IGNORECASE,
)
_MULTIPLIERS = {
    "k": 1_000, "thousand": 1_000, "hazar": 1_000, "hazaar": 1_000,
    "lakh": 100_000, "lac": 100_000, "million": 1_000_000, "crore": 10_000_000,
}
_MERCHANT_RE = re.compile(
    r"(?:\bat\b|\bfrom\b|@)\s+(?P<m>[A-Za-z0-9&'.\- ]{2,40}?)"
    r"(?=\s+(?:on|for|today|yesterday|via|using|with|by|in)\b|[,.;!]|\s*$)",
    re.IGNORECASE,
)
_PURPOSE_RE = re.compile(
    r"\b(?:on|for)\s+(?P<p>[A-Za-z&' \-]{2,50}?)"
    r"(?=\s+(?:at|from|today|yesterday|via|using|with|by)\b|[,.;!]|\s*$)",
    re.IGNORECASE,
)
_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


# =============================================================================
# Extraction helpers
# =============================================================================

def _contains_word(text: str, word: str) -> bool:
    return re.search(rf"(?<![a-z]){re.escape(word)}(?![a-z])", text) is not None


def _currency_code(token: Optional[str]) -> Optional[str]:
    if not token or token == "/-":
        return "PKR" if token == "/-" else None
    return CURRENCY_ALIASES.get(token.lower())


def parse_amount(text: str) -> tuple[Optional[Decimal], Optional[str], bool]:
    """
    Return (amount, currency_code, had_currency_marker).
    Priority: first currency-tagged number (bank SMS list the balance later) >
    largest plain number > a plain number that looks like a year.
    """
    plain: list[Decimal] = []
    year_like: list[Decimal] = []
    for m in _AMOUNT_RE.finditer(text):
        start, end = m.span("num")
        # Ignore digits glued to letters/slashes: "xx1234", "15/10/26", "A/C".
        if (start and (text[start - 1].isalpha() or text[start - 1] == "/")) or \
                (end < len(text) and text[end] == "/" and text[end:end + 2] != "/-"):
            continue
        num = m.group("num").replace(",", "")
        try:
            value = Decimal(num)
        except InvalidOperation:
            continue
        if m.group("mult"):
            value *= _MULTIPLIERS[m.group("mult").lower()]
        if value <= 0 or len(num) > 12:
            continue
        if m.group("pre") or m.group("post") or m.group("mult"):
            currency = _currency_code(m.group("pre")) or _currency_code(m.group("post"))
            return value.quantize(Decimal("0.01")), currency, True
        (year_like if re.fullmatch(r"(19|20)\d{2}", num) else plain).append(value)
    pick = max(plain) if plain else (year_like[0] if year_like else None)
    return (pick.quantize(Decimal("0.01")) if pick is not None else None), None, False


def detect_type(lowered: str) -> TransactionType:
    income = sum(_contains_word(lowered, k) for k in INCOME_KEYWORDS)
    expense = sum(_contains_word(lowered, k) for k in EXPENSE_KEYWORDS)
    return "income" if income > expense else "expense"


def detect_known_merchant(lowered: str) -> Optional[tuple[str, str]]:
    for pattern, info in KNOWN_MERCHANTS.items():
        if re.search(rf"(?<![a-z]){pattern}(?![a-z])", lowered):
            return info
    return None


def keyword_category(lowered: str) -> Optional[str]:
    scores: dict[str, int] = {}
    for category, words in CATEGORY_KEYWORDS.items():
        hits = sum(_contains_word(lowered, w) for w in words)
        if hits:
            scores[category] = hits
    if not scores:
        return None
    return max(scores, key=lambda c: scores[c])


def detect_category_mention(text: str) -> Optional[str]:
    """Category named or implied in a question, e.g. 'how much on food?' -> Food & Dining."""
    lowered = text.lower()
    for category in CATEGORIES:
        if _contains_word(lowered, category.lower()):
            return category
    known = detect_known_merchant(lowered)
    return keyword_category(lowered) or (known[1] if known else None)


def detect_date(lowered: str, today: date) -> date:
    if "day before yesterday" in lowered or _contains_word(lowered, "parson"):
        return today - timedelta(days=2)
    if _contains_word(lowered, "yesterday") or _contains_word(lowered, "kal"):
        return today - timedelta(days=1)
    m = re.search(r"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b", lowered)
    if m:
        day, month = int(m.group(1)), int(m.group(2))
        year = int(m.group(3)) if m.group(3) else today.year
        if year < 100:
            year += 2000
        try:
            parsed = date(year, month, day)
            if parsed <= today + timedelta(days=1):
                return parsed
        except ValueError:
            pass
    for idx, name in enumerate(_WEEKDAYS):
        if re.search(rf"\b(?:on|last)\s+{name}\b", lowered):
            delta = (today.weekday() - idx) % 7 or 7
            return today - timedelta(days=delta)
    return today


def _clean_phrase(phrase: str) -> str:
    phrase = _AMOUNT_RE.sub(" ", phrase)
    return re.sub(r"\s+", " ", phrase).strip(" -.,")


# =============================================================================
# Public API
# =============================================================================

@dataclass
class ParseResult:
    amount: Optional[float]
    currency: str
    type: TransactionType
    category: str
    merchant: Optional[str]
    description: Optional[str]
    transaction_date: date
    confidence: float
    missing_fields: list[str] = field(default_factory=list)
    raw_text: str = ""
    normalized_text: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def extract_entities(text: str, today: Optional[date] = None, default_currency: str = "PKR") -> ParseResult:
    """
    Parse a free-text expense/income description into structured fields.

    >>> extract_entities("Spent 1,200 rupees on groceries at Carrefour").category
    'Groceries'
    """
    today = today or date.today()
    original = re.sub(r"\s+", " ", text).strip()
    normalized = normalize_spoken_numbers(original)
    lowered = normalized.lower()

    amount, currency, amount_tagged = parse_amount(normalized)
    txn_type = detect_type(lowered)

    known = detect_known_merchant(lowered)
    merchant: Optional[str] = None
    m = _MERCHANT_RE.search(normalized)
    if m:
        candidate = _clean_phrase(m.group("m"))
        if candidate and not re.fullmatch(r"(the|a|an|my|\d+)", candidate, re.IGNORECASE):
            merchant = candidate.title() if candidate.islower() else candidate
    if known:
        merchant = known[0]

    purpose: Optional[str] = None
    p = _PURPOSE_RE.search(normalized)
    if p:
        purpose = _clean_phrase(p.group("p")) or None

    kw_cat = keyword_category(lowered)
    if known and (kw_cat is None or kw_cat == known[1]):
        category, confidence = known[1], 0.95
    elif kw_cat:
        category, confidence = kw_cat, (0.9 if known else 0.8)
    elif known:
        category, confidence = known[1], 0.85
    else:
        category, confidence = "Other", 0.4

    # Consistency rules between type and category.
    if txn_type == "expense" and category in ("Salary", "Freelance"):
        txn_type = "income"
    if txn_type == "income" and category not in INCOME_CATEGORIES:
        category = "Other"
        confidence = min(confidence, 0.6)

    description = purpose or _clean_phrase(
        re.sub(r"\b(spent|paid|bought|received|got|on|at|from|for|rupees?|rs\.?|pkr)\b", " ",
               normalized, flags=re.IGNORECASE)
    ) or None

    if amount is None:
        confidence = min(confidence, 0.3)
    elif not amount_tagged:
        confidence *= 0.95

    missing = [name for name, value in (("amount", amount), ("merchant", merchant)) if value is None]

    return ParseResult(
        amount=float(amount) if amount is not None else None,
        currency=currency or default_currency,
        type=txn_type,
        category=category,
        merchant=merchant[:120] if merchant else None,
        description=description[:255] if description else None,
        transaction_date=detect_date(lowered, today),
        confidence=round(confidence, 3),
        missing_fields=missing,
        raw_text=original,
        normalized_text=normalized,
    )

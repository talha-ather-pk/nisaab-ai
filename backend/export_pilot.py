"""
Anonymised export of pilot transactions for the RQ1 labelling study.

    python export_pilot.py --init-key               # once: create the pseudonymisation key (outside git)
    python export_pilot.py                          # export + sample into eval/pilot/
    python export_pilot.py --size 350 --calibration 30 --per-user 15 --seed 7

Who is included: only users who gave research consent (terms_accepted_at set) and are not the
shared demo account. Only AI-parsed entries (text, voice, SMS) are exported.

What is written to --out-dir (git-ignored; it is research data):
  sample.csv       the test sample, one row per entry, for review and labelling
  calibration.csv  separate items for the annotators' calibration round (never part of the test set)
  manifest.json    counts, filters, seed, and a fingerprint of the key (never the key itself)

Pseudonyms: P + the first 10 hex digits of HMAC-SHA256(key, user_id). They are stable across
exports with the same key, and can't be reversed or recomputed without it. Keep the key outside
the repository and never share it with the data.

Masking is automatic for phone numbers, CNICs, IBANs, emails, card and account numbers. Personal
names can't be masked reliably, so rows that may contain one are flagged (review_flags) and must be
checked by hand: replace any name in masked_text with [NAME] and set reviewed=yes. labelling.py
refuses to make annotation sheets while a flagged row is unreviewed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import hmac
import json
import os
import random
import re
import secrets
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

from nlp_engine import CATEGORIES, KNOWN_MERCHANTS

DEFAULT_KEY_FILE = Path(os.environ.get("NISAAB_PILOT_KEY_FILE", Path.home() / ".nisaab" / "pilot_export.key"))
DEFAULT_OUT_DIR = Path(__file__).parent / "eval" / "pilot"
AI_SOURCES = ("text", "voice", "sms")
DEMO_TERMS_VERSION = "demo"

SAMPLE_FIELDS = ["item_id", "participant", "transaction_date", "source", "type", "saved_category",
                 "user_corrected", "masked_text", "review_flags", "reviewed"]


# =============================================================================
# Pseudonymisation
# =============================================================================

def load_key(path: Path) -> bytes:
    if not path.exists():
        raise SystemExit(f"No pseudonymisation key at {path}. Create one with: python export_pilot.py --init-key")
    key = path.read_text(encoding="utf-8").strip()
    if len(key) < 32:
        raise SystemExit(f"The key in {path} is too short; create a new one with --init-key.")
    return key.encode()


def init_key(path: Path) -> None:
    if path.exists():
        raise SystemExit(f"{path} already exists. Reusing it keeps pseudonyms stable; delete it only on purpose.")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(secrets.token_hex(32), encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:  # Windows: permissions come from the user profile folder
        pass
    print(f"Created {path}. Keep it outside the repository and back it up privately.")


def pseudonym(key: bytes, user_id: int) -> str:
    return "P" + hmac.new(key, str(user_id).encode(), hashlib.sha256).hexdigest()[:10]


def key_fingerprint(key: bytes) -> str:
    """Identifies which key produced an export without revealing it."""
    return hashlib.sha256(b"nisaab-key-fingerprint:" + key).hexdigest()[:12]


# =============================================================================
# Masking and name flags
# =============================================================================

# Order matters: the most specific patterns run first so a CNIC isn't half-eaten by the phone rule.
_MASKS: list[tuple[str, re.Pattern]] = [
    ("EMAIL", re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b")),
    ("IBAN", re.compile(r"\bPK\s?\d{2}\s?[A-Z]{4}(?:\s?\d){16}\b", re.IGNORECASE)),
    ("CNIC", re.compile(r"\b\d{5}-?\d{7}-?\d\b")),
    ("ACCOUNT", re.compile(r"\b(?:a/c|acc(?:oun)?t|account)\s*(?:no\.?|number|#)?\s*[:#-]?\s*[\*xX]*\d{3,}\b",
                           re.IGNORECASE)),
    ("PHONE", re.compile(r"(?<![\w+])(?:\+92|0092|92|0)[\s-]?3\d{2}[\s-]?\d{7}\b")),
    ("PHONE", re.compile(r"(?<![\w+])(?:(?:\+92|0092)[\s-]?\(?\d{2,3}\)?|\(?0\d{2,3}\)?)[\s-]?\d{7,8}\b")),  # landline
    ("CARD", re.compile(r"\b(?:\d{4}[\s-]){3}\d{1,7}\b")),
    ("ACCOUNT", re.compile(r"[\*xX]{2,}\d{3,}\b")),       # masked by the bank already, e.g. ****1234
    ("ACCOUNT", re.compile(r"(?<![\d,.])\d{9,}(?![\d,.])")),  # long digit runs: account / reference numbers
]


def mask_pii(text: str) -> tuple[str, list[str]]:
    """(masked text, kinds masked). Amounts such as "Rs 15,000" or "1500" are left alone."""
    kinds = []
    for kind, pattern in _MASKS:
        text, n = pattern.subn(f"[{kind}]", text)
        if n:
            kinds.append(kind)
    return text, sorted(set(kinds))


# Common Pakistani given names; a hit means "check this row", not "this is a name".
_COMMON_NAMES = {
    "ali", "ahmed", "ahmad", "hassan", "hussain", "hamza", "bilal", "usman", "umar", "omar", "zain", "saad",
    "fahad", "faisal", "imran", "kamran", "asad", "asim", "adnan", "arslan", "haris", "danish", "waqas", "zeeshan",
    "talha", "taha", "salman", "shoaib", "junaid", "nabeel", "noman", "rizwan", "irfan", "tariq", "yasir", "aamir",
    "amir", "atif", "babar", "shahid", "sajid", "naveed", "nadeem", "khalid", "rashid", "majid", "javed", "abdullah",
    "ayesha", "aisha", "fatima", "zainab", "maryam", "sana", "hina", "sara", "sarah", "amna", "aiman", "iqra",
    "mahnoor", "areeba", "hira", "rabia", "saba", "nida", "mehwish", "sadia", "kiran", "farah", "zara", "alina",
    "anam", "bushra", "noor", "laiba", "maham", "sidra", "uzma", "huma", "shazia", "nadia", "samina", "rubina",
}
_HONORIFICS = r"(?:mr|mrs|ms|miss|dr|sir|madam|sahab|sahib|saab|bhai|bhaiya|baji|apa|uncle|aunty|auntie|chacha|mamu|khala)"
_KNOWN_WORDS = (
    {w for name, _ in KNOWN_MERCHANTS.values() for w in re.findall(r"[a-z]+", name.lower())}
    | {w for c in CATEGORIES for w in re.findall(r"[a-z]+", c.lower())}
    | {"rs", "pkr", "jazzcash", "easypaisa", "raast", "ibft", "bank", "atm", "hbl", "ubl", "mcb", "meezan",
       "allied", "alfalah", "askari", "faysal", "sadapay", "nayapay", "the", "my", "a", "an", "office", "home"}
) - _COMMON_NAMES  # "Gul Ahmed" must not hide "Ahmed bhai": a false alarm is cheap, a missed name is not
_NAME_CONTEXTS = [
    re.compile(r"\b(?:to|from|for|by|with|paid|sent|gave|diye|diya|di)\s+([A-Z][a-z]{2,})\b"),
    re.compile(r"\b([A-Z][a-z]{2,})\s+(?:ko|ne|se|ka|ki|ke)\b"),
    re.compile(rf"\b{_HONORIFICS}\.?\s+([A-Za-z]{{3,}})\b", re.IGNORECASE),
    re.compile(rf"\b([A-Za-z]{{3,}})\s+{_HONORIFICS}\b", re.IGNORECASE),
]


def name_flags(text: str) -> list[str]:
    """Words that might be a person's name, for manual review."""
    found = []
    for pattern in _NAME_CONTEXTS:
        found += pattern.findall(text)
    found += [w for w in re.findall(r"[A-Za-z]+", text) if w.lower() in _COMMON_NAMES]
    hits = []
    for word in found:
        lw = word.lower()
        if lw in _KNOWN_WORDS or re.fullmatch(_HONORIFICS, lw) or lw in hits:
            continue
        hits.append(lw)
    return [f"possible_name:{w}" for w in hits]


# =============================================================================
# Sampling
# =============================================================================

@dataclass
class Entry:
    user_id: int
    transaction_date: date
    source: str
    type: str
    saved_category: str
    user_corrected: bool
    raw_text: str


@dataclass
class SampleRow:
    item_id: str
    participant: str
    transaction_date: str
    source: str
    type: str
    saved_category: str
    user_corrected: str
    masked_text: str
    review_flags: str
    reviewed: str = ""


@dataclass
class SampleResult:
    sample: list[SampleRow]
    calibration: list[SampleRow]
    stats: dict = field(default_factory=dict)


def normalise_for_dedup(text: str) -> str:
    """Near-duplicates ("Careem 400" / "careem 650") collapse to the same key."""
    return re.sub(r"\s+", " ", re.sub(r"\d[\d,.]*", "#", text.lower())).strip()


def draw_sample(entries: Iterable[Entry], key: bytes, size: int = 350, calibration: int = 30,
                per_user: int = 15, min_per_category: int = 10, seed: int = 0) -> SampleResult:
    """
    1. Drop near-duplicate texts (keeping one per normalised text).
    2. Calibration items first, then the test sample; no user contributes more than `per_user`
       items across both, so heavy users can't dominate.
    3. Stratified by the saved category: up to `min_per_category` from every category (so rare ones
       are represented), then the rest drawn at random from what is left (proportional to volume).
    The saved category is only a proxy for the true one; the annotators assign the real label.
    """
    rng = random.Random(seed)
    entries = list(entries)
    seen: set[str] = set()
    unique = []
    for e in sorted(entries, key=lambda e: (e.user_id, e.transaction_date)):
        k = normalise_for_dedup(e.raw_text)
        if k and k not in seen:
            seen.add(k)
            unique.append(e)
    rng.shuffle(unique)

    taken_per_user: Counter = Counter()
    used: set[int] = set()

    def take(candidates: list[int], n: int) -> list[int]:
        picked = []
        for i in candidates:
            if len(picked) == n:
                break
            if i in used or taken_per_user[unique[i].user_id] >= per_user:
                continue
            used.add(i)
            taken_per_user[unique[i].user_id] += 1
            picked.append(i)
        return picked

    order = list(range(len(unique)))
    calibration_idx = take(order, calibration)

    by_category: dict[str, list[int]] = defaultdict(list)
    for i in order:
        by_category[unique[i].saved_category].append(i)
    sample_idx: list[int] = []
    for category in sorted(by_category):
        sample_idx += take(by_category[category], min(min_per_category, max(size - len(sample_idx), 0)))
    sample_idx += take(order, max(size - len(sample_idx), 0))

    def rows(indices: list[int], prefix: str) -> list[SampleRow]:
        out = []
        for n, i in enumerate(indices, 1):
            e = unique[i]
            masked, kinds = mask_pii(e.raw_text)
            flags = [f"masked:{k}" for k in kinds] + name_flags(masked)
            out.append(SampleRow(
                item_id=f"{prefix}{n:04d}", participant=pseudonym(key, e.user_id),
                transaction_date=e.transaction_date.isoformat(), source=e.source, type=e.type,
                saved_category=e.saved_category, user_corrected="yes" if e.user_corrected else "no",
                masked_text=masked, review_flags=";".join(flags),
                # Rows with only automatic masking need no review; possible names do.
                reviewed="" if any(f.startswith("possible_name") for f in flags) else "n/a",
            ))
        return out

    rng.shuffle(sample_idx)  # item order carries no information about users or categories
    sample, calib = rows(sample_idx, "T"), rows(calibration_idx, "C")
    return SampleResult(sample, calib, {
        "entries_exported": len(entries),
        "after_dedup": len(unique),
        "participants": len({e.user_id for e in unique}),
        "sample_size": len(sample),
        "calibration_size": len(calib),
        "sample_by_saved_category": dict(Counter(r.saved_category for r in sample).most_common()),
        "rows_needing_name_review": sum(r.reviewed == "" for r in sample + calib),
        "max_items_per_participant": max(taken_per_user.values(), default=0),
    })


# =============================================================================
# Database + files
# =============================================================================

def load_consented_entries(db) -> list[Entry]:
    from sqlalchemy import select
    from models import Transaction, User

    rows = db.execute(
        select(Transaction.user_id, Transaction.transaction_date, Transaction.source, Transaction.type,
               Transaction.category, Transaction.user_corrected, Transaction.raw_text)
        .join(User, User.id == Transaction.user_id)
        .where(
            User.terms_accepted_at.is_not(None),
            User.terms_version.is_not(None),
            User.terms_version != DEMO_TERMS_VERSION,
            Transaction.source.in_(AI_SOURCES),
            Transaction.raw_text.is_not(None),
        )
        .order_by(Transaction.user_id, Transaction.created_at, Transaction.id)
    ).all()
    return [Entry(uid, d, src, typ, cat, corrected, raw) for uid, d, src, typ, cat, corrected, raw in rows
            if raw and raw.strip()]


def write_rows(path: Path, rows: list[SampleRow]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=SAMPLE_FIELDS)
        writer.writeheader()
        writer.writerows(asdict(r) for r in rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--init-key", action="store_true", help="create the pseudonymisation key and exit")
    parser.add_argument("--key-file", type=Path, default=DEFAULT_KEY_FILE)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--size", type=int, default=350, help="test sample size")
    parser.add_argument("--calibration", type=int, default=30, help="calibration items (kept out of the test set)")
    parser.add_argument("--per-user", type=int, default=15, help="max items per participant")
    parser.add_argument("--min-per-category", type=int, default=10)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--force", action="store_true", help="overwrite an existing sample")
    args = parser.parse_args()

    if args.init_key:
        init_key(args.key_file)
        return
    key = load_key(args.key_file)
    sample_path = args.out_dir / "sample.csv"
    if sample_path.exists() and not args.force:
        raise SystemExit(f"{sample_path} exists (it may already be under review). Use --force to replace it.")

    from database import SessionLocal

    with SessionLocal() as db:
        entries = load_consented_entries(db)
    if not entries:
        raise SystemExit("No consented, non-demo, AI-parsed entries to export yet.")

    result = draw_sample(entries, key, args.size, args.calibration, args.per_user, args.min_per_category, args.seed)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_rows(sample_path, result.sample)
    write_rows(args.out_dir / "calibration.csv", result.calibration)
    manifest = {
        "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "filters": "terms_accepted_at IS NOT NULL AND terms_version <> 'demo'; source IN (text, voice, sms)",
        "seed": args.seed, "size": args.size, "per_user": args.per_user,
        "min_per_category": args.min_per_category,
        "key_fingerprint": key_fingerprint(key),
        **result.stats,
    }
    (args.out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    if result.stats["rows_needing_name_review"]:
        print(f"\n{result.stats['rows_needing_name_review']} row(s) may contain a name. Open sample.csv and "
              "calibration.csv, replace any name in masked_text with [NAME], and set reviewed=yes.")


if __name__ == "__main__":
    main()

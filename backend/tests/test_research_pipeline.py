"""Pilot export (consent filter, pseudonyms, masking, sampling) and the dual-labelling pipeline."""

import csv
import subprocess
import sys
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

from database import SessionLocal
from export_pilot import (Entry, draw_sample, init_key, key_fingerprint, load_consented_entries, load_key,
                          mask_pii, name_flags, pseudonym, write_rows)
from labelling import (agreement_report, cohen_kappa, freeze, gold_type, interpret_kappa, make_sheets,
                       read_csv, run_agreement, verify_checksum, write_csv)
from models import Transaction, User
from security import hash_password

KEY = b"k" * 64
BACKEND = Path(__file__).resolve().parents[1]


# --- masking ------------------------------------------------------------------------------------

@pytest.mark.parametrize("text, kind", [
    ("Sent 5000 to 0300-1234567 via JazzCash", "PHONE"),
    ("call +92 321 7654321", "PHONE"),
    ("03451234567 easypaisa 2000", "PHONE"),
    ("landline 021-34567890 bill", "PHONE"),
    ("CNIC 42101-1234567-1", "CNIC"),
    ("cnic 4210112345671", "CNIC"),
    ("IBAN PK36SCBL0000001123456702 transfer", "IBAN"),
    ("paid ali.raza@gmail.com", "EMAIL"),
    ("card 4111 1111 1111 1111", "CARD"),
    ("A/C No. 0123456789 debited", "ACCOUNT"),
    ("Acct ****4567 debited", "ACCOUNT"),
    ("ref 123456789012 IBFT", "ACCOUNT"),
])
def test_personal_numbers_are_masked(text, kind):
    masked, kinds = mask_pii(text)
    assert f"[{kind}]" in masked and kind in kinds
    assert not any(ch.isdigit() for ch in masked.replace("5000", "").replace("2000", ""))


@pytest.mark.parametrize("text", ["Rs 15,000 groceries", "salary 1500000", "paid 25,000,000 for plot",
                                  "petrol 4,500.50", "Careem 400 on 12/10"])
def test_amounts_and_dates_survive(text):
    assert mask_pii(text) == (text, [])


def test_name_flags():
    assert name_flags("sent 2000 to Ali") == ["possible_name:ali"]
    assert "possible_name:ahmed" in name_flags("Ahmed bhai ko 500 diye")
    assert "possible_name:khan" in name_flags("Dr. Khan fee 2000")
    assert "possible_name:ahmed" in name_flags("Gul Ahmed lawn 4200")  # false alarm on purpose: names win
    assert name_flags("Careem 400") == []
    assert name_flags("paid 300 to Imtiaz") == []
    assert name_flags("ammi ne 3000 bheje") == []


# --- pseudonyms and keys -------------------------------------------------------------------------

def test_pseudonyms_are_keyed_and_stable(tmp_path):
    assert pseudonym(KEY, 7) == pseudonym(KEY, 7)
    assert pseudonym(KEY, 7) != pseudonym(KEY, 8)
    assert pseudonym(KEY, 7) != pseudonym(b"x" * 64, 7)  # unrecomputable without the key
    assert pseudonym(KEY, 7).startswith("P") and len(pseudonym(KEY, 7)) == 11
    assert KEY.decode() not in key_fingerprint(KEY)

    path = tmp_path / "keys" / "pilot.key"
    init_key(path)
    assert len(load_key(path)) == 64
    with pytest.raises(SystemExit):
        init_key(path)  # never silently replaced: that would change every pseudonym
    with pytest.raises(SystemExit):
        load_key(tmp_path / "missing.key")


# --- consent filter (database) -------------------------------------------------------------------

def _user(db, email, accepted=True, version="2026.10"):
    u = User(full_name="Test User", email=email, password_hash=hash_password("Secret123"),
             terms_accepted_at=datetime.now(timezone.utc) if accepted else None,
             terms_version=version if accepted else None)
    db.add(u)
    db.flush()
    return u


def _txn(db, user, text, source="text", category="Groceries"):
    db.add(Transaction(user_id=user.id, amount=100, type="expense", category=category, raw_text=text,
                       source=source, transaction_date=date(2026, 10, 1)))


def test_export_includes_only_consenting_real_participants():
    with SessionLocal() as db:
        ok = _user(db, "ok@example.com")
        no_consent = _user(db, "no@example.com", accepted=False)
        demo = _user(db, "demo@nisaab.app", version="demo")
        _txn(db, ok, "milk 200")
        _txn(db, ok, "manual entry", source="manual")  # not parsed by the AI: excluded
        _txn(db, no_consent, "secret 300")
        _txn(db, demo, "demo 400")
        db.commit()
        entries = load_consented_entries(db)
    assert [(e.user_id, e.raw_text) for e in entries] == [(ok.id, "milk 200")]


# --- sampling ------------------------------------------------------------------------------------

def _entries():
    out = []
    cats = ["Groceries"] * 6 + ["Transport"] * 3 + ["Charity"]
    for uid in range(1, 21):
        for n in range(30):
            out.append(Entry(uid, date(2026, 10, 1) + timedelta(days=n % 28), "text", "expense",
                             cats[n % len(cats)], False,
                             # distinct words: texts that differ only in numbers count as duplicates
                             "item " + "".join(chr(97 + int(d)) for d in f"{uid:02d}{n:02d}") + " 100"))
    out.append(Entry(1, date(2026, 10, 2), "text", "expense", "Groceries", False, "Careem 400"))
    out.append(Entry(2, date(2026, 10, 3), "text", "expense", "Groceries", False, "careem 650"))  # near-duplicate
    return out


def test_sampling_caps_users_stratifies_and_separates_calibration():
    result = draw_sample(_entries(), KEY, size=120, calibration=20, per_user=8, min_per_category=10, seed=1)
    sample, calib = result.sample, result.calibration
    assert len(sample) == 120 and len(calib) == 20
    assert result.stats["after_dedup"] == len(_entries()) - 1

    per_participant = Counter(r.participant for r in sample + calib)
    assert max(per_participant.values()) <= 8  # cap holds across calibration + test
    assert Counter(r.saved_category for r in sample)["Charity"] >= 10  # rare category represented
    assert not {r.masked_text for r in sample} & {r.masked_text for r in calib}
    assert all(r.item_id.startswith("T") for r in sample) and all(r.item_id.startswith("C") for r in calib)
    assert all(r.participant.startswith("P") for r in sample)

    again = draw_sample(_entries(), KEY, size=120, calibration=20, per_user=8, min_per_category=10, seed=1)
    assert [r.masked_text for r in again.sample] == [r.masked_text for r in sample]  # reproducible


def test_flagged_rows_need_review():
    entries = [Entry(1, date(2026, 10, 1), "text", "expense", "Transfers", False, "sent 2000 to Ali 03001234567"),
               Entry(1, date(2026, 10, 2), "text", "expense", "Groceries", False, "milk 200")]
    rows = {r.masked_text: r for r in draw_sample(entries, KEY, size=2, calibration=0, seed=0).sample}
    flagged = rows["sent 2000 to Ali [PHONE]"]
    assert "masked:PHONE" in flagged.review_flags and "possible_name:ali" in flagged.review_flags
    assert flagged.reviewed == ""
    assert rows["milk 200"].reviewed == "n/a"


# --- kappa ---------------------------------------------------------------------------------------

def test_cohen_kappa_textbook_example():
    # 50 items: both yes 20, A yes/B no 5, A no/B yes 10, both no 15 -> po 0.70, pe 0.50, kappa 0.40
    a = ["y"] * 20 + ["y"] * 5 + ["n"] * 10 + ["n"] * 15
    b = ["y"] * 20 + ["n"] * 5 + ["y"] * 10 + ["n"] * 15
    assert cohen_kappa(a, b) == pytest.approx(0.40)
    assert cohen_kappa(a, a) == 1.0
    assert cohen_kappa(["x"] * 5, ["x"] * 5) == 1.0
    assert interpret_kappa(0.40) == "fair" and interpret_kappa(0.85) == "almost perfect"


def test_agreement_report_per_category():
    a = ["Fuel", "Fuel", "Rent", "Rent", "Health", "Health"]
    b = ["Fuel", "Fuel", "Rent", "Health", "Health", "Health"]
    report = agreement_report(a, b, samples=200)
    by = {c.category: c for c in report.per_category}
    assert by["Fuel"].specific_agreement == 1.0
    assert by["Rent"].specific_agreement == pytest.approx(2 / 3)
    assert report.confusions == [("Health", "Rent", 1)]
    assert report.kappa_ci is not None


# --- sheets -> agreement -> freeze -> evaluate ---------------------------------------------------

def _fill(path, labels):
    rows = read_csv(path)
    for r in rows:
        r["category"] = labels[r["item_id"]]
    write_csv(path, ["item_id", "text", "category", "notes"], rows)


def test_full_labelling_workflow(tmp_path):
    entries = [Entry(u, date(2026, 10, d), "text", "expense", cat, False, text)
               for u, d, cat, text in [(1, 1, "Groceries", "milk 200"), (1, 2, "Transport", "Careem 400"),
                                       (2, 3, "Fuel", "petrol 3000"), (2, 4, "Transfers", "sent 500 to Ali"),
                                       (3, 5, "Food & Dining", "biryani 650"), (3, 6, "Salary", "salary 90000")]]
    result = draw_sample(entries, KEY, size=6, calibration=0, seed=0)
    sample = tmp_path / "sample.csv"
    write_rows(sample, result.sample)

    with pytest.raises(SystemExit, match="not reviewed"):
        make_sheets(sample, "main", tmp_path)
    rows = read_csv(sample)
    for r in rows:
        r["masked_text"] = r["masked_text"].replace("Ali", "[NAME]")
        r["reviewed"] = r["reviewed"] or "yes"
    write_csv(sample, list(rows[0]), rows)

    sheet_a, sheet_b = make_sheets(sample, "main", tmp_path)
    assert "saved_category" not in read_csv(sheet_a)[0]  # blind: no model or user label
    assert [r["item_id"] for r in read_csv(sheet_a)] != [r["item_id"] for r in read_csv(sheet_b)] or len(rows) < 3
    assert (tmp_path / "LABELLING_GUIDE.md").exists()

    truth = {r["item_id"]: r["saved_category"] for r in rows}
    _fill(sheet_a, truth)
    disputed = next(i for i, c in truth.items() if c == "Transfers")
    _fill(sheet_b, {**truth, disputed: "other"})  # labels are case-insensitive

    report = run_agreement(sheet_a, sheet_b, "main", tmp_path, samples=100)
    assert report.n == 6 and report.kappa < 1
    disagreements = read_csv(tmp_path / "disagreements_main.csv")
    assert [d["item_id"] for d in disagreements] == [disputed]

    out = tmp_path / "pilot_test_v1.csv"
    with pytest.raises(SystemExit, match="no valid final_category"):
        freeze(sheet_a, sheet_b, tmp_path / "disagreements_main.csv", sample, out)
    disagreements[0]["final_category"] = "Transfers"
    write_csv(tmp_path / "disagreements_main.csv", list(disagreements[0]), disagreements)

    manifest = freeze(sheet_a, sheet_b, tmp_path / "disagreements_main.csv", sample, out, samples=100)
    assert manifest["items"] == 6 and manifest["adjudicated"] == 1
    gold = {r["item_id"]: r for r in read_csv(out)}
    assert gold[disputed]["category"] == "Transfers" and "[NAME]" in gold[disputed]["text"]
    assert next(r for r in gold.values() if r["category"] == "Salary")["type"] == "income"
    assert verify_checksum(out) == manifest["sha256"]

    with pytest.raises(SystemExit, match="frozen already"):
        freeze(sheet_a, sheet_b, tmp_path / "disagreements_main.csv", sample, out)

    # evaluate.py accepts the frozen set and refuses a tampered one.
    run = lambda: subprocess.run([sys.executable, "evaluate.py", "--offline-only", "--bootstrap", "50",
                                  "--test-set", str(out)], cwd=BACKEND, capture_output=True, text=True)
    ok = run()
    assert ok.returncode == 0, ok.stderr
    assert "6 pilot entries" in ok.stdout
    out.write_text(out.read_text(encoding="utf-8-sig") + "x,expense,Other\n", encoding="utf-8")
    bad = run()
    assert bad.returncode != 0 and "changed since it was frozen" in bad.stderr


def test_gold_type():
    assert gold_type("Salary", "expense") == "income"
    assert gold_type("Groceries", "income") == "expense"
    assert gold_type("Transfers", "income") == "income"
    assert gold_type("Other", "expense") == "expense"

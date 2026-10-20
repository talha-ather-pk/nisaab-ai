from datetime import date

import pytest

from nlp_engine import extract_entities, normalize_spoken_numbers

TODAY = date(2026, 10, 18)  # a Sunday


@pytest.mark.parametrize(
    "text, amount, category, merchant, txn_type",
    [
        ("Spent 1,200 rupees on groceries at Carrefour", 1200, "Groceries", "Carrefour", "expense"),
        ("Rs. 850 Careem ride to office", 850, "Transport", "Careem", "expense"),
        ("Paid K-Electric bill Rs 3,400", 3400, "Utilities", "K-Electric", "expense"),
        ("Foodpanda dinner 1650", 1650, "Food & Dining", "Foodpanda", "expense"),
        ("Petrol 6500 at PSO", 6500, "Fuel", "PSO", "expense"),
        ("Received salary 150,000", 150000, "Salary", None, "income"),
        ("Got 1.5k from Fiverr client", 1500, "Freelance", "Fiverr", "income"),
        ("bought medicine for 2,450/- at Dvago", 2450, "Health", "Pharmacy", "expense"),
        ("University fee 2 lakh", 200000, "Education", None, "expense"),
        ("Jazz load 1000", 1000, "Mobile & Internet", "Jazz", "expense"),
        ("lunch at Kolachi 3200 rupees", 3200, "Food & Dining", "Kolachi", "expense"),
        ("2000 diye Ali ko committee ke", 2000, "Transfers", None, "expense"),
        ("Rs 12,000 rent kiraya", 12000, "Rent", None, "expense"),
    ],
)
def test_typed_text(text, amount, category, merchant, txn_type):
    r = extract_entities(text, today=TODAY)
    assert (r.amount, r.category, r.merchant, r.type) == (amount, category, merchant, txn_type)


@pytest.mark.parametrize(
    "spoken, expected",
    [
        ("spent twelve hundred rupees on groceries", "spent 1200 rupees on groceries"),
        ("paid two thousand five hundred for petrol", "paid 2500 for petrol"),
        ("fifteen thousand rent", "15000 rent"),
        ("one thousand and fifty for books", "1050 for books"),
        ("ninety-nine rupees chai", "99 rupees chai"),
        ("2 thousand five hundred at Daraz", "2500 at Daraz"),
        ("the one at Carrefour", "the one at Carrefour"),
    ],
)
def test_spoken_number_normalisation(spoken, expected):
    assert normalize_spoken_numbers(spoken) == expected


def test_voice_transcript_end_to_end():
    r = extract_entities("careem ride to office eight hundred fifty rupees", today=TODAY)
    assert r.amount == 850
    assert r.category == "Transport"
    assert r.merchant == "Careem"


@pytest.mark.parametrize(
    "text, currency, amount",
    [
        ("Netflix $15.99", "USD", 15.99),
        ("Paid 50 AED for lunch", "AED", 50),
        ("Received 200 dollars from Upwork", "USD", 200),
        ("Spent 500 on chai", "PKR", 500),
    ],
)
def test_currency_detection(text, currency, amount):
    r = extract_entities(text, today=TODAY)
    assert r.currency == currency
    assert r.amount == amount


def test_bank_sms_prefers_transaction_amount_over_balance():
    sms = "Your A/C xx1234 debited PKR 2,500.00 at DARAZ on 15/10/26. Avl Bal PKR 48,210.55"
    r = extract_entities(sms, today=TODAY)
    assert r.amount == 2500
    assert r.type == "expense"
    assert r.category == "Shopping"
    assert r.transaction_date == date(2026, 10, 15)


@pytest.mark.parametrize(
    "text, expected",
    [
        ("chai 100 yesterday", date(2026, 10, 17)),
        ("chai 100 day before yesterday", date(2026, 10, 16)),
        ("petrol 5000 on friday", date(2026, 10, 16)),
        ("lunch 900 last sunday", date(2026, 10, 11)),
        ("groceries 3000", TODAY),
        ("fees 5000 on 31/12/26", TODAY),  # future date is ignored
    ],
)
def test_dates(text, expected):
    assert extract_entities(text, today=TODAY).transaction_date == expected


def test_missing_amount_lowers_confidence():
    r = extract_entities("chai with friends", today=TODAY)
    assert r.amount is None
    assert "amount" in r.missing_fields
    assert r.confidence <= 0.3


def test_description_from_purpose_phrase():
    assert extract_entities("Spent 1,200 rupees on groceries at Carrefour", today=TODAY).description == "groceries"

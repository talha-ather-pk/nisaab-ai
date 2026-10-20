"""Personal category learning: unit tests for the classifier and the parse endpoint end to end."""

from conftest import register
from personalization import Example, PersonalClassifier, tokenize


def ex(text, category, merchant=None, corrected=False, type_="expense"):
    return Example(text=text, merchant=merchant, type=type_, category=category, corrected=corrected)


def test_tokenize_drops_amounts_and_filler():
    assert tokenize("Paid 1,250 rupees at Imtiaz for groceries yesterday") == ["imtiaz", "groceries"]


def test_merchant_memory_applies_a_correction():
    model = PersonalClassifier([ex("Careem ride 650", "Fuel", merchant="Careem", corrected=True)])
    p = model.predict("Careem 400", "careem", "expense")
    assert p is not None and p.category == "Fuel" and p.reason == "merchant"


def test_merchant_memory_is_per_type():
    model = PersonalClassifier([ex("Careem ride 650", "Fuel", merchant="Careem", corrected=True)])
    assert model.predict("Careem refund 650", "Careem", "income") is None


def test_one_correction_does_not_take_over_shared_words():
    model = PersonalClassifier([
        ex("Careem ride to office", "Fuel", merchant="Careem", corrected=True),
        ex("office lunch biryani", "Food & Dining"),
        ex("lunch with team at office", "Food & Dining"),
        ex("burger lunch near office", "Food & Dining"),
    ])
    p = model.predict("office lunch 500", None, "expense")
    assert p is None or p.category == "Food & Dining"


def test_repeated_wording_is_learned():
    model = PersonalClassifier([
        ex("committee payment 5000", "Transfers", corrected=True),
        ex("committee 5000 for march", "Transfers", corrected=True),
        ex("groceries at imtiaz", "Groceries"),
    ])
    p = model.predict("committee installment 5000", None, "expense")
    assert p is not None and p.category == "Transfers" and p.reason == "words"


def test_no_prediction_without_known_words():
    model = PersonalClassifier([ex("committee payment", "Transfers", corrected=True)])
    assert model.predict("zzz qqq", None, "expense") is None


def _parse(client, auth, text):
    res = client.post("/api/v1/transactions/parse", json={"text": text}, headers=auth["headers"])
    assert res.status_code == 200, res.text
    return res.json()


def test_parse_learns_from_a_users_correction(client, auth):
    before = _parse(client, auth, "Careem 400")
    assert before["category"] == "Transport" and before["category_source"] == "rules"

    res = client.post("/api/v1/transactions", headers=auth["headers"], json={
        "amount": 650, "category": "Transport", "merchant": "Careem", "raw_text": "Careem 650", "source": "text"})
    txn_id = res.json()["id"]
    res = client.patch(f"/api/v1/transactions/{txn_id}", json={"category": "Fuel"}, headers=auth["headers"])
    assert res.json()["user_corrected"] is True

    after = _parse(client, auth, "Careem 400")
    assert after["category"] == "Fuel" and after["category_source"] == "personal"

    # Learning is per user: someone else still gets the rule engine's answer.
    other = register(client, email="sara@example.com")
    assert _parse(client, other, "Careem 400")["category"] == "Transport"

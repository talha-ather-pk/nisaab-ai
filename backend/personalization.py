"""
Personal category learning (RQ1).

The rule engine in nlp_engine.py is the same for everyone. This module learns each user's own
labelling from the transactions they have saved, so a correction made once is applied next time:

1. Merchant memory: a merchant the user re-labelled is classified their way.
2. Word model: a multinomial Naive Bayes over word tokens, trained on the user's saved
   transactions. Rows the user corrected count CORRECTION_WEIGHT times.

The learned category only replaces the rule engine's choice when it disagrees with it, is at least
MIN_PROBABILITY likely, and at least one of the user's corrections backs it. A single correction
therefore can't take over unrelated text that merely shares a word with it.
"""

from __future__ import annotations

import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Iterable, Literal, Optional

from sqlalchemy import select
from sqlalchemy.orm import Session

from models import Transaction

MIN_PROBABILITY = 0.8
CORRECTION_WEIGHT = 3
TRAINING_LIMIT = 500  # most recent rows per user; keeps parsing fast
MODEL_NAME = "nisaab-personal-nb-v1"

_TOKEN_RE = re.compile(r"[a-z]{3,}")
_STOPWORDS = {
    "the", "and", "for", "from", "with", "spent", "paid", "pay", "bought", "buy", "got", "received",
    "rupees", "rupee", "rupay", "rupaye", "pkr", "today", "yesterday", "kal", "parson", "last",
    "this", "that", "was", "were", "has", "have", "had", "via", "using", "thousand", "hundred",
    "lakh", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
}


def tokenize(text: str) -> list[str]:
    return [t for t in _TOKEN_RE.findall(text.lower()) if t not in _STOPWORDS]


def _merchant_key(merchant: Optional[str]) -> Optional[str]:
    key = re.sub(r"\s+", " ", merchant or "").strip().lower()
    return key or None


@dataclass
class Example:
    text: str
    merchant: Optional[str]
    type: str
    category: str
    corrected: bool


@dataclass
class Prediction:
    category: str
    confidence: float
    reason: Literal["merchant", "words"]


class PersonalClassifier:
    def __init__(self, examples: Iterable[Example]):
        # Everything is keyed by transaction type so income text never yields an expense category.
        self._merchant_votes: dict[tuple[str, str], Counter] = defaultdict(Counter)
        self._class_weight: dict[str, Counter] = defaultdict(Counter)
        self._token_counts: dict[tuple[str, str], Counter] = defaultdict(Counter)
        self._vocab: dict[str, set[str]] = defaultdict(set)
        # Tokens seen in corrected rows, per (type, category): the evidence an override needs.
        self._corrected_tokens: dict[tuple[str, str], set[str]] = defaultdict(set)

        for ex in examples:
            weight = CORRECTION_WEIGHT if ex.corrected else 1
            key = _merchant_key(ex.merchant)
            if ex.corrected and key:
                self._merchant_votes[(ex.type, key)][ex.category] += 1
            tokens = tokenize(f"{ex.text} {ex.merchant or ''}")
            self._class_weight[ex.type][ex.category] += weight
            for t in tokens:
                self._token_counts[(ex.type, ex.category)][t] += weight
            self._vocab[ex.type].update(tokens)
            if ex.corrected:
                self._corrected_tokens[(ex.type, ex.category)].update(tokens)

    def predict(self, text: str, merchant: Optional[str], type_: str) -> Optional[Prediction]:
        key = _merchant_key(merchant)
        votes = self._merchant_votes.get((type_, key)) if key else None
        if votes:
            category, n = votes.most_common(1)[0]
            share = n / sum(votes.values())
            if share >= MIN_PROBABILITY:
                return Prediction(category, round(min(0.97, 0.9 + 0.02 * n) * share, 3), "merchant")

        classes = self._class_weight.get(type_)
        tokens = [t for t in tokenize(f"{text} {merchant or ''}") if t in self._vocab[type_]]
        if not classes or not tokens:
            return None

        vocab_size = len(self._vocab[type_])
        total_weight = sum(classes.values())
        log_scores: dict[str, float] = {}
        for category, weight in classes.items():
            counts = self._token_counts[(type_, category)]
            denom = sum(counts.values()) + vocab_size
            score = math.log((weight + 1) / (total_weight + len(classes)))
            score += sum(math.log((counts[t] + 1) / denom) for t in tokens)
            log_scores[category] = score

        top = max(log_scores.values())
        exp_scores = {c: math.exp(s - top) for c, s in log_scores.items()}
        norm = sum(exp_scores.values())
        category = max(exp_scores, key=exp_scores.__getitem__)
        probability = exp_scores[category] / norm
        if probability < MIN_PROBABILITY or not (set(tokens) & self._corrected_tokens[(type_, category)]):
            return None
        return Prediction(category, round(min(probability, 0.95), 3), "words")


def load_examples(db: Session, user_id: int, limit: int = TRAINING_LIMIT) -> list[Example]:
    rows = db.execute(
        select(Transaction.raw_text, Transaction.description, Transaction.merchant, Transaction.type,
               Transaction.category, Transaction.user_corrected)
        .where(Transaction.user_id == user_id)
        .order_by(Transaction.created_at.desc(), Transaction.id.desc())
        .limit(limit)
    ).all()
    return [
        Example(text=raw or desc or "", merchant=merchant, type=type_, category=category, corrected=corrected)
        for raw, desc, merchant, type_, category, corrected in rows
        if raw or desc or merchant
    ]


def personal_override(examples: list[Example], text: str, merchant: Optional[str], type_: str,
                      rule_category: str) -> Optional[Prediction]:
    """
    The learned category if it should replace the rule engine's choice, else None.
    Shared by the live parser and the evaluation replay so both apply the same decision.
    """
    if not any(ex.corrected for ex in examples):
        return None
    prediction = PersonalClassifier(examples).predict(text, merchant, type_)
    if prediction is None or prediction.category == rule_category:
        return None
    return prediction


def personalize(db: Session, user_id: int, text: str, merchant: Optional[str], type_: str,
                rule_category: str) -> Optional[Prediction]:
    """The user's learned category for this text, or None to keep the rule engine's choice."""
    return personal_override(load_examples(db, user_id), text, merchant, type_, rule_category)

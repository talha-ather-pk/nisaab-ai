-- =============================================================================
-- Nisaab AI — PostgreSQL production schema  (v1)
--
-- Idempotent: safe to run on an empty or an already-initialised database.
--   psql "$DATABASE_URL" -f database/schema.sql
-- Docker: mounted into /docker-entrypoint-initdb.d and applied on first boot.
--
-- Must stay in sync with backend/models.py.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Migration bookkeeping
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     VARCHAR(20) PRIMARY KEY,
    description TEXT        NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Keeps updated_at current on every UPDATE.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id                 BIGSERIAL     PRIMARY KEY,
    full_name          VARCHAR(120)  NOT NULL,
    email              VARCHAR(255)  NOT NULL,
    phone              VARCHAR(20),
    password_hash      TEXT          NOT NULL,
    preferred_currency CHAR(3)       NOT NULL DEFAULT 'PKR' CHECK (preferred_currency ~ '^[A-Z]{3}$'),
    monthly_income     NUMERIC(14,2) CONSTRAINT users_income_nonneg CHECK (monthly_income IS NULL OR monthly_income >= 0),
    is_active          BOOLEAN       NOT NULL DEFAULT TRUE,
    last_login_at      TIMESTAMPTZ,
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT users_email_lowercase CHECK (email = LOWER(email))
);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_uq ON users (email);

DROP TRIGGER IF EXISTS users_set_updated_at ON users;
CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Research consent (migration 2026.10.003). NULL = has not accepted: excluded from research exports
-- and asked to accept on next login. terms_version records which consent text was accepted.
ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_accepted_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_version     VARCHAR(20);

-- -----------------------------------------------------------------------------
-- transactions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
    id               BIGSERIAL     PRIMARY KEY,
    user_id          BIGINT        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    amount           NUMERIC(14,2) NOT NULL CONSTRAINT transactions_amount_positive CHECK (amount > 0),
    currency         CHAR(3)       NOT NULL DEFAULT 'PKR' CHECK (currency ~ '^[A-Z]{3}$'),
    type             VARCHAR(10)   NOT NULL CONSTRAINT transactions_type_check
                                   CHECK (type IN ('expense', 'income')),
    category         VARCHAR(40)   NOT NULL DEFAULT 'Other',
    merchant         VARCHAR(120),
    description      VARCHAR(255),
    raw_text         TEXT,                                       -- original NL / voice / SMS input
    source           VARCHAR(10)   NOT NULL DEFAULT 'manual' CONSTRAINT transactions_source_check
                                   CHECK (source IN ('text', 'voice', 'sms', 'manual')),
    ai_confidence    NUMERIC(4,3)  CONSTRAINT transactions_confidence_range
                                   CHECK (ai_confidence IS NULL OR (ai_confidence >= 0 AND ai_confidence <= 1)),
    user_corrected   BOOLEAN       NOT NULL DEFAULT FALSE,       -- label signal for classifier training
    transaction_date DATE          NOT NULL DEFAULT CURRENT_DATE,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS transactions_user_date_idx
    ON transactions (user_id, transaction_date DESC, id DESC);
CREATE INDEX IF NOT EXISTS transactions_user_category_date_idx
    ON transactions (user_id, category, transaction_date);
CREATE INDEX IF NOT EXISTS transactions_created_at_idx
    ON transactions (created_at);

DROP TRIGGER IF EXISTS transactions_set_updated_at ON transactions;
CREATE TRIGGER transactions_set_updated_at
    BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- budgets  (one limit per user + category + month)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS budgets (
    id              BIGSERIAL     PRIMARY KEY,
    user_id         BIGINT        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    category        VARCHAR(40)   NOT NULL,
    monthly_limit   NUMERIC(14,2) NOT NULL CONSTRAINT budgets_limit_positive CHECK (monthly_limit > 0),
    currency        CHAR(3)       NOT NULL DEFAULT 'PKR' CHECK (currency ~ '^[A-Z]{3}$'),
    month_year      DATE          NOT NULL,                      -- first day of the budgeted month
    alert_threshold INTEGER       NOT NULL DEFAULT 80 CONSTRAINT budgets_threshold_range
                                  CHECK (alert_threshold BETWEEN 1 AND 100),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT budgets_month_year_first_day CHECK (EXTRACT(DAY FROM month_year) = 1),
    CONSTRAINT budgets_user_category_period_uq UNIQUE (user_id, category, month_year)
);

CREATE INDEX IF NOT EXISTS budgets_user_month_year_idx ON budgets (user_id, month_year);

DROP TRIGGER IF EXISTS budgets_set_updated_at ON budgets;
CREATE TRIGGER budgets_set_updated_at
    BEFORE UPDATE ON budgets
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- ai_financial_logs  (audit trail of every AI interaction: parsing, assistant, forecasts)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_financial_logs (
    id               BIGSERIAL    PRIMARY KEY,
    user_id          BIGINT       NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    interaction_type VARCHAR(20)  NOT NULL CONSTRAINT ai_logs_type_check
                                  CHECK (interaction_type IN ('parse', 'assistant', 'forecast')),
    input_text       TEXT         NOT NULL,
    output_text      TEXT,
    intent           VARCHAR(40),
    provider         VARCHAR(20)  NOT NULL DEFAULT 'rules' CONSTRAINT ai_logs_provider_check
                                  CHECK (provider IN ('rules', 'claude')),
    model            VARCHAR(80),
    confidence       NUMERIC(4,3),
    context          JSONB,
    latency_ms       INTEGER      CHECK (latency_ms IS NULL OR latency_ms >= 0),
    input_tokens     INTEGER,
    output_tokens    INTEGER,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ai_logs_user_created_idx ON ai_financial_logs (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_logs_type_created_idx ON ai_financial_logs (interaction_type, created_at DESC);

-- -----------------------------------------------------------------------------
-- savings_goals  (e.g. "Laptop: Rs 150,000 by June")
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS savings_goals (
    id              BIGSERIAL     PRIMARY KEY,
    user_id         BIGINT        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name            VARCHAR(80)   NOT NULL,
    target_amount   NUMERIC(14,2) NOT NULL CONSTRAINT goals_target_positive CHECK (target_amount > 0),
    saved_amount    NUMERIC(14,2) NOT NULL DEFAULT 0 CONSTRAINT goals_saved_non_negative CHECK (saved_amount >= 0),
    currency        CHAR(3)       NOT NULL DEFAULT 'PKR' CHECK (currency ~ '^[A-Z]{3}$'),
    target_date     DATE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS goals_user_idx ON savings_goals (user_id);

DROP TRIGGER IF EXISTS savings_goals_set_updated_at ON savings_goals;
CREATE TRIGGER savings_goals_set_updated_at
    BEFORE UPDATE ON savings_goals
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO schema_migrations (version, description)
VALUES ('2026.10.001', 'Initial schema: users, transactions, budgets, ai_financial_logs')
ON CONFLICT (version) DO NOTHING;

INSERT INTO schema_migrations (version, description)
VALUES ('2026.10.002', 'savings_goals')
ON CONFLICT (version) DO NOTHING;

INSERT INTO schema_migrations (version, description)
VALUES ('2026.10.003', 'users.terms_accepted_at, users.terms_version (research consent)')
ON CONFLICT (version) DO NOTHING;

COMMIT;

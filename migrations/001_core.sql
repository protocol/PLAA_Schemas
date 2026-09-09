-- Bootstrap only in a fresh database, by a dedicated installer superuser.
CREATE ROLE plaa_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
CREATE ROLE plaa_ingest NOLOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
CREATE ROLE plaa_admin NOLOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
CREATE ROLE plaa_backend NOLOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
CREATE ROLE plaa_member_reader NOLOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
CREATE ROLE plaa_aggregate_builder NOLOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
CREATE ROLE plaa_export_reader NOLOGIN NOSUPERUSER NOINHERIT NOBYPASSRLS;
GRANT plaa_member_reader TO plaa_backend;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION btree_gist;
CREATE SCHEMA plaa AUTHORIZATION plaa_owner;
CREATE SCHEMA ingest AUTHORIZATION plaa_owner;
CREATE SCHEMA export AUTHORIZATION plaa_owner;
SET ROLE plaa_owner;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE ALL ON TABLES FROM PUBLIC;
CREATE TYPE plaa.member_status AS ENUM
    ('active','suspended','offboarded');

CREATE TYPE plaa.round_status AS ENUM
    ('draft','open','closed','settled');

CREATE TYPE plaa.activity_cadence AS ENUM
    ('repeatable','recurring','one_time');

CREATE TYPE plaa.verification_method AS ENUM
    ('auto_tracked','manual_review','submission');

CREATE TYPE plaa.submission_source AS ENUM
    ('bot','google_form','auto_tracked','admin');

CREATE TYPE plaa.submission_status AS ENUM ('received','pending_review','accepted','rejected','duplicate','withdrawn');

CREATE TYPE plaa.point_event_type AS ENUM
    ('collected','adjustment','reversal','kudos_given','kudos_received');

CREATE TYPE plaa.allocation_source AS ENUM
    ('incentivized_activities','infra_rewards');

CREATE TYPE plaa.plaa_entry_type AS ENUM
    ('issuance','redemption','adjustment','reversal');

CREATE TABLE plaa.region (
    region_code  text PRIMARY KEY,
    name         text NOT NULL,
    is_active    boolean NOT NULL DEFAULT true,
    valid_from   date NOT NULL DEFAULT current_date,
    valid_to     date,
    updated_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE plaa.asset (
    asset_code   text PRIMARY KEY,
    name         text NOT NULL,
    default_unit text NOT NULL,
    is_active    boolean NOT NULL DEFAULT true,
    valid_from   date NOT NULL DEFAULT current_date,
    valid_to     date,
    updated_by   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE plaa.member (
    aa_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id      uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE, -- external references
    display_name   text,
    status         plaa.member_status NOT NULL DEFAULT 'active',  -- active|suspended|offboarded
    onboarded_at   timestamptz,
    region_code    text REFERENCES plaa.region(region_code),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE plaa.member_identity (
    member_identity_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aa_id      bigint NOT NULL REFERENCES plaa.member(aa_id),
    id_type        text NOT NULL,     -- 'directory_uid' | 'legacy_member_uid' | 'email' | 'surus' | ...
    id_value       text NOT NULL,
    valid_from     date NOT NULL DEFAULT current_date,
    valid_to       date,              -- NULL = current
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    EXCLUDE USING gist (
        id_type WITH =, id_value WITH =,
        daterange(valid_from, valid_to, '[)') WITH &&
    )
);

CREATE TABLE plaa.round (
    round_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    round_number    int NOT NULL UNIQUE,                  -- 1..19..
    period          daterange NOT NULL,                   -- [2026-08-01, 2026-09-01)
    plaa_pool       NUMERIC(20,8) NOT NULL,               -- e.g. 10000
    status          plaa.round_status NOT NULL DEFAULT 'draft', -- draft|open|closed|settled
    narrative       text,                                 -- replaces static frontend copy
    header_description text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    EXCLUDE USING gist (period WITH &&)                   -- no overlapping rounds, ever
);

CREATE TABLE plaa.category (               -- "KPI Pillars"
    category_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE,   -- 'programs', 'knowledge_sharing', ...
    name           text NOT NULL,
    is_active      boolean NOT NULL DEFAULT true
);

CREATE TABLE plaa.round_category_allocation (
    round_id       bigint NOT NULL REFERENCES plaa.round(round_id),
    category_id    bigint NOT NULL REFERENCES plaa.category(category_id),
    weight         NUMERIC(7,6) NOT NULL CHECK (weight >= 0 AND weight <= 1),
    plaa_allocated NUMERIC(20,8) NOT NULL, -- fixed portion of the pool
    PRIMARY KEY (round_id, category_id)
);

CREATE TABLE plaa.activity (
    activity_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text NOT NULL UNIQUE,           -- stable slug, e.g. 'thoughtful-responder'
    name            text NOT NULL,
    description     text,
    category_id     bigint NOT NULL REFERENCES plaa.category(category_id),
    cadence         plaa.activity_cadence NOT NULL,       -- repeatable|recurring|one_time
    verification    plaa.verification_method NOT NULL,    -- auto_tracked|manual_review|submission
    is_active       boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE plaa.activity_point_value (
    activity_point_value_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activity_id    bigint NOT NULL REFERENCES plaa.activity(activity_id),
    valid_from     date NOT NULL,
    valid_to       date,
    points_default NUMERIC(14,2),
    points_min     NUMERIC(14,2),
    points_max     NUMERIC(14,2),
    CHECK (points_min IS NULL OR points_max IS NULL OR points_min <= points_max),
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    EXCLUDE USING gist (
        activity_id WITH =, daterange(valid_from, valid_to, '[)') WITH &&
    )
);

CREATE TABLE plaa.round_activity (          -- which activities are live in a round
    round_id     bigint REFERENCES plaa.round(round_id),
    activity_id  bigint REFERENCES plaa.activity(activity_id),
    PRIMARY KEY (round_id, activity_id)
);

CREATE TABLE plaa.round_region (            -- replaces multiline "regions_unlocked"
    round_id     bigint REFERENCES plaa.round(round_id),
    region_code  text REFERENCES plaa.region(region_code),
    PRIMARY KEY (round_id, region_code)
);

CREATE TABLE plaa.activity_submission (
    submission_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id       uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    aa_id       bigint NOT NULL REFERENCES plaa.member(aa_id),
    activity_id     bigint NOT NULL REFERENCES plaa.activity(activity_id),
    round_id        bigint NOT NULL REFERENCES plaa.round(round_id),
    source          plaa.submission_source NOT NULL,  -- bot|google_form|auto_tracked|admin
    source_ref      text NOT NULL,   -- durable source event key; stable across retries
    evidence_url    text,
    payload         jsonb,           -- raw structured submission data
    status          plaa.submission_status NOT NULL DEFAULT 'received',
    reviewed_by     text,  -- reviewer name captured at review time
    reviewed_at     timestamptz,
    review_note     text,
    submitted_at    timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source, source_ref)
);

CREATE INDEX ON plaa.activity_submission (round_id, status);

CREATE INDEX ON plaa.activity_submission (aa_id, round_id);

CREATE TABLE plaa.point_event (
    point_event_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aa_id       bigint NOT NULL REFERENCES plaa.member(aa_id),
    round_id        bigint NOT NULL REFERENCES plaa.round(round_id),
    activity_id     bigint NOT NULL REFERENCES plaa.activity(activity_id),
    submission_id   bigint REFERENCES plaa.activity_submission(submission_id),
    source          text NOT NULL,
    source_ref      text NOT NULL, -- original business event key, not retry/batch ID
    source_effect   text NOT NULL, -- stable effect key within the source event
    source_occurred_at timestamptz NOT NULL,
    activity_point_value_id bigint REFERENCES plaa.activity_point_value(activity_point_value_id),
    points          NUMERIC(14,2) NOT NULL,         -- negative for corrections
    event_type      plaa.point_event_type NOT NULL, -- collected|adjustment|reversal|kudos_given|kudos_received
    reverses_event_id bigint REFERENCES plaa.point_event(point_event_id),
    note            text,
    created_by      text NOT NULL,                  -- service or admin principal
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_point_event_source_effect
    ON plaa.point_event (source, source_ref, source_effect);

CREATE UNIQUE INDEX uq_point_event_single_reversal
    ON plaa.point_event (reverses_event_id)
    WHERE reverses_event_id IS NOT NULL;

CREATE INDEX ON plaa.point_event (round_id, aa_id);

CREATE INDEX ON plaa.point_event (aa_id, created_at);

CREATE UNIQUE INDEX uq_point_event_submission_credit
    ON plaa.point_event (submission_id)
    WHERE submission_id IS NOT NULL AND event_type = 'collected';

CREATE VIEW plaa.v_member_round_points WITH (security_invoker=true) AS
SELECT aa_id, round_id, SUM(points) AS points
FROM plaa.point_event GROUP BY 1,2;

CREATE TABLE plaa.settlement_batch (
    settlement_batch_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    allocation_source   plaa.allocation_source NOT NULL,
    round_id             bigint REFERENCES plaa.round(round_id),
    source               text NOT NULL,
    source_ref           text NOT NULL,
    source_period        daterange,
    settled_at           timestamptz,
    created_by           text NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (allocation_source, source, source_ref),
    UNIQUE (settlement_batch_id, allocation_source),
    UNIQUE (settlement_batch_id, round_id)
);

CREATE TABLE plaa.round_category_result (
    settlement_batch_id bigint NOT NULL,
    round_id             bigint NOT NULL,
    category_id          bigint NOT NULL REFERENCES plaa.category(category_id),
    total_points         NUMERIC(14,2) NOT NULL,
    plaa_distributed     NUMERIC(20,8) NOT NULL,
    computed_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (settlement_batch_id, category_id),
    FOREIGN KEY (settlement_batch_id, round_id)
        REFERENCES plaa.settlement_batch (settlement_batch_id, round_id)
);

ALTER TABLE plaa.round_category_result
    ADD CONSTRAINT uq_result_round_batch_category
    UNIQUE (round_id, settlement_batch_id, category_id);

CREATE TABLE plaa.round_category_current (
    round_id bigint NOT NULL,
    category_id bigint NOT NULL,
    settlement_batch_id bigint NOT NULL,
    PRIMARY KEY (round_id, category_id),
    FOREIGN KEY (round_id, settlement_batch_id, category_id)
        REFERENCES plaa.round_category_result
        (round_id, settlement_batch_id, category_id)
);

CREATE TABLE plaa.plaa_ledger_entry (
    entry_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aa_id                bigint NOT NULL REFERENCES plaa.member(aa_id),
    round_id             bigint REFERENCES plaa.round(round_id),
    settlement_batch_id  bigint,
    allocation_source    plaa.allocation_source,
    category_id          bigint,
    entry_type           plaa.plaa_entry_type NOT NULL,
    amount               NUMERIC(20,8) NOT NULL,
    effective_at         timestamptz NOT NULL, -- source-supported economic/event time
    source_ref           text NOT NULL,  -- stable per-entry source key
    reverses_entry_id    bigint REFERENCES plaa.plaa_ledger_entry(entry_id),
    note                 text,
    created_by           text NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (settlement_batch_id, allocation_source)
        REFERENCES plaa.settlement_batch (settlement_batch_id, allocation_source),
    FOREIGN KEY (settlement_batch_id, category_id)
        REFERENCES plaa.round_category_result (settlement_batch_id, category_id),
    CHECK (
        entry_type <> 'issuance' OR
        (
            settlement_batch_id IS NOT NULL AND
            allocation_source IS NOT NULL AND
            (
                (allocation_source = 'incentivized_activities' AND category_id IS NOT NULL) OR
                (allocation_source = 'infra_rewards' AND category_id IS NULL)
            )
        )
    ),
    CHECK (
        (entry_type = 'issuance' AND amount > 0) OR
        (entry_type = 'redemption' AND amount < 0) OR
        (entry_type IN ('adjustment','reversal') AND amount <> 0)
    ),
    CHECK (
        (entry_type = 'reversal' AND reverses_entry_id IS NOT NULL) OR
        (entry_type <> 'reversal' AND reverses_entry_id IS NULL)
    ),
    UNIQUE (entry_type, source_ref)
);

CREATE INDEX ON plaa.plaa_ledger_entry (aa_id, created_at);

CREATE UNIQUE INDEX uq_ia_issuance_per_batch_member_category
    ON plaa.plaa_ledger_entry (settlement_batch_id, aa_id, category_id)
    WHERE entry_type = 'issuance' AND allocation_source = 'incentivized_activities';

CREATE UNIQUE INDEX uq_ir_issuance_per_batch_member
    ON plaa.plaa_ledger_entry (settlement_batch_id, aa_id)
    WHERE entry_type = 'issuance' AND allocation_source = 'infra_rewards';

CREATE UNIQUE INDEX uq_plaa_ledger_single_reversal
    ON plaa.plaa_ledger_entry (reverses_entry_id)
    WHERE reverses_entry_id IS NOT NULL;

CREATE VIEW plaa.v_member_balance WITH (security_invoker=true) AS
SELECT aa_id,
       COALESCE(SUM(amount) FILTER (
           WHERE allocation_source = 'incentivized_activities'
       ), 0) AS ia_net_plaa,
       COALESCE(SUM(amount) FILTER (
           WHERE allocation_source = 'infra_rewards'
       ), 0) AS ir_net_plaa,
       COALESCE(SUM(amount) FILTER (
           WHERE allocation_source IS NULL
       ), 0) AS unallocated_net_plaa,
       SUM(amount) AS plaa_balance
FROM plaa.plaa_ledger_entry
GROUP BY aa_id;

CREATE TABLE plaa.buyback_auction (
    auction_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    round_id         bigint REFERENCES plaa.round(round_id),
    auction_number   int NOT NULL UNIQUE,
    source            text NOT NULL,
    source_ref        text NOT NULL,
    opened_at         timestamptz,
    closed_at         timestamptz,
    raw_payload       jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source, source_ref)
);

CREATE TABLE plaa.buyback_bid (
    bid_id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    auction_id           bigint NOT NULL REFERENCES plaa.buyback_auction(auction_id),
    aa_id                bigint NOT NULL REFERENCES plaa.member(aa_id),
    source_ref           text NOT NULL,
    price_usd_per_right  NUMERIC(20,8) NOT NULL CHECK (price_usd_per_right > 0),
    rights_bid           NUMERIC(20,8) NOT NULL CHECK (rights_bid > 0),
    bid_amount_usd       NUMERIC(20,8), -- source-reported amount; NULL if absent
    source_format_version text NOT NULL,
    submitted_at         timestamptz,
    raw_payload          jsonb,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (auction_id, source_ref)
);

CREATE INDEX ON plaa.buyback_bid (auction_id, price_usd_per_right);

CREATE TABLE plaa.trust_holding_snapshot (
    holding_snapshot_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_month date NOT NULL,
    asset_code text NOT NULL REFERENCES plaa.asset(asset_code),
    revision int NOT NULL CHECK (revision > 0),
    quantity NUMERIC(24,8) NOT NULL,
    unit text NOT NULL,
    source_ref text NOT NULL,
    supersedes_snapshot_id bigint UNIQUE
        REFERENCES plaa.trust_holding_snapshot(holding_snapshot_id),
    entered_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (snapshot_month, asset_code, revision)
);

CREATE TABLE plaa.trust_valuation_snapshot (
    valuation_snapshot_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reporting_month date NOT NULL,
    revision int NOT NULL CHECK (revision > 0),
    trust_value_usd NUMERIC(24,8) NOT NULL,
    nav_usd_per_plaa NUMERIC(20,8) NOT NULL,
    source_ref text NOT NULL UNIQUE,
    supersedes_snapshot_id bigint UNIQUE
        REFERENCES plaa.trust_valuation_snapshot(valuation_snapshot_id),
    received_at timestamptz NOT NULL,
    imported_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (reporting_month, revision)
);

CREATE TABLE plaa.audit_log (
    audit_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor        text NOT NULL,          -- service account or admin identity
    action       text NOT NULL,          -- 'submission.accept', 'round.settle', ...
    table_name   text NOT NULL,
    row_pk       text NOT NULL,
    before       jsonb,
    after        jsonb,
    occurred_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ingest.raw_submission (
    raw_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source        plaa.submission_source NOT NULL,
    source_ref    text NOT NULL,
    received_at   timestamptz NOT NULL DEFAULT now(),
    payload       jsonb NOT NULL,
    processed_at  timestamptz,
    error         text,
    UNIQUE (source, source_ref)
);
RESET ROLE;

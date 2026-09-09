# Migration / adoption runbook

**Not a record of a production migration.** This project was built in a directory containing only a private specification and private tooling metadata. No application, live DB, migration history, plaa-sync source or legacy source records were available. Local tests use fictional records in a new disposable PostgreSQL 16.10 cluster only.

## Local validation and migration mechanics

1. Run `make test` (native) or `make test-docker` (isolated Compose). The runner creates database `plaa_service` only inside its own new cluster/container.
2. `public.schema_migration` records migration filename, SHA-256 and applied timestamp. Each file and its history row commit together. Already-recorded files are compared and skipped; changed applied content fails validation. Replays are **not** `CREATE IF NOT EXISTS` guesses that hide drift.
3. All seven migrations run before fixture loading. Audit triggers are installed in migration 002 before any domain rows; later tables install audit before their first fixture rows. Fixtures use actual runtime APIs; only explicit fictional policy/contract seed records use migration-owner authority.
4. The runner tests a second checksum pass, altered-content checksum detection, dependency/RLS/grant introspection, fixtures and full SQL tests. Native auth is local trust inside a mode-0700 temporary tree, no listening TCP address; Docker has no host port or persistent volume. This is not production security configuration.
5. Each run stops/removes only its generated cluster/unique Compose project. It ignores ambient PG connection environment and takes no DSN. If interrupted by an uncatchable kill, inspect only the logged `plaa-disposable-*` path or `plaa-test-*` project before manually removing it; never run global prune/drop commands.

The project has a **fresh-only** supported install boundary. There was no existing schema to upgrade. The checks do not certify compatibility with any operational `trust_holding_snapshots` or applied legacy migration. After adoption, never modify an applied file: add reviewed forward migrations. Do not run these bootstrap role/table statements directly on an existing database.

## Existing-target preflight — required before integration

- Obtain authorized schema-only inventory, role/grant/default-privilege inventory, PostgreSQL/extension versions, applied migration history and plaa-sync contract from the owner. Do not connect merely because a local database has a familiar name.
- Reconcile existing `trust_holding_snapshots` naming/semantics with singular immutable revision tables. Preserve original PKs/source identifiers in restricted crosswalk evidence; do not overwrite or auto-rename a live table.
- Author a separate forward migration and upgrade fixture from that actual supported version. Preflight must **report/quarantine**, not repair by deletion: temporal identity/point-value overlap, empty/infinite intervals, duplicate stable source effects, lifetime settlement collisions, missing provenance/hash/revision, wrong-key Trust predecessors, numeric text/precision errors, orphan references and gross/net API incompatibility.
- Require owner-reviewed resolution manifests for ambiguous records. Never invent source IDs, silently round numbers, merge participants by email, disable triggers/RLS or auto-infer activity history from an opening balance.
- Test both a fresh install and the actual upgrade with reconciliation before applying to staging. Object owners, RLS policies and definer privileges must be checked after any migration, not inferred from tests against a different catalog.

## Source inventory and reconciliation

| Source class | Target / discovery work |
|---|---|
| Membership and historical aliases | `member`, temporal `member_identity`; typed normalization + verified evidence; `ingest.identity_crosswalk` is restricted staging, not another participant PK. Never import access codes by default. |
| Bot/forms/sheets/auto-tracked events | Durable source/ref/revision/time contract, raw landing and manifest, unresolved queue, reviewed submission credit. Cross-batch retry must reuse the original business event key. |
| Historical point snapshots | Preserve original source evidence and distinguish source-confirmed adjustments from reconstructed events; reliable history depth and opening treatment need approval. |
| Monthly rounds/category weights/static catalog | Typed relational config + audited manual region/asset maintenance. Flatten legacy multiline fields only under reviewed source mappings. |
| IA and IR allocations | Confirm source categories/units and allocation authority; record calculation-policy/input cutoff/event IDs/allocation-version snapshots; exact totals by category/member/batch and all-history net balance. |
| Auctions/bids | Quantity-v1 price, quantity, nullable source-reported amount and format/payload. Flag disagreement with calculated notional; never overwrite or infer fills/holdings. New format/auction metadata correction needs a reviewed adapter. |
| Team holdings / Trust valuations | Separate source inventories, months, asset units, source hashes and sequential revisions. Flag missing months, revised files, unit changes and unexplained deltas; no fabricated valuation from quantity. |
| Profile/history/display tables and frontend constants | Replace derived balances with invoker views/APIs; verify old gross field semantics and every consumer before removing source paths. |
| Warehouse | Profile real distinct contributors, proposed coarsenings, suppression and utility; build only owner-approved release adapters. Export/source-audience approvals are independent of unrelated operational cutover. |

For every source record retain durable key, original occurrence time, received time, revision, content hash, original payload, import correlation and actor. Raw identity/evidence/notes/audit may contain PII in production; restrict retention and access accordingly. Explicit changed-payload errors roll back their transaction; a durable conflict queue must be recorded by the external ingest orchestrator in a **separate successful transaction**, not falsely claimed as committed by a failed import. The SQL raw-submission error queue handles unresolved identity without orphan creation.

## Staging / dual run

1. Human approval of source access, policy history, permissions, normalization, precision/tolerance and retention precedes backfill. No production fixtures or policy approvals are shipped here.
2. Deploy audited schema to authorized staging; provision non-owner login credentials outside the repository using infrastructure controls. Group roles are NOLOGIN and NOINHERIT. Keep migration owner credentials away from runtime services.
3. Extend plaa-sync/source adapters and Directory backend, not this schema project into an app. Browser sign-in verification occurs in the backend; bind current verified subject inside the same transaction, then reduce to member-reader. Exercise real pooling cleanup, request authorization, role switching and session failure paths.
4. Deliver admin workflows: configuration, review queue, identity/crosswalk triage, confirmed IA/IR imports and corrections, monthly Trust revision/reconciliation, audit inspection. Narrow DB APIs are interfaces, not a delivered UI or operator usability proof.
5. Backfill idempotently using independently retained source evidence. Compare counts, member/period/category sums, zero issuance sets, hashes, rejected rows, outstanding identity triage, policy/version application and effective/known-as-of history. Sign reconciliation exceptions; do not suppress them to meet a date.
6. Airtable remains authoritative during shadow dual-run. An idempotent compatibility sync can feed dependent reads but must not establish two authoritative writers. Real monthly close + correction + operator baseline timing/error/rework/usability acceptance is required for gate C.

## Recovery evidence before cutover

Approve RPO/RTO, retention horizon and last-safe rollback checkpoint. Configure and **actually test** PostgreSQL backup/PITR restore and replay into an isolated environment with signed reconciliation. The durable replay source must survive loss/restore of the target DB: an access-controlled immutable source journal outside the restored database, or a tested independent source-redelivery mechanism. Raw rows lost in the same restore cannot replay themselves.

Restore drill: record backup identity/hash and cutoff, restore target, independently replay stable event keys, prove zero duplicate effects, reconcile external deliveries and ledger/current pointers, validate audit and RLS, measure RPO/RTO and operator steps. No such production restore drill ran in this task; transaction rollback tests are not backup recovery tests.

Before cutover rollback means abandon shadow writes and retain Airtable authority/evidence. After cutover recover PostgreSQL with PITR + independent replay and reconcile external effects; do not quietly reopen Airtable as a competing writer.

## Human-gated cutover and deletion

Gate A (proposed 30 October 2026): usable staging admin replacement. Gate C (30 November): real operator monthly-close acceptance. Gate B (15 December): signed reconciliation, auth/API/restore readiness, approved applicable exports, single-writer switch, and **zero** Airtable request-path/backend/job/reporting/monthly-manual dependencies. Verify disabled credentials/jobs and agreed observation window; retire Sheet QUERY logic and reverse sync. Dates/owners/capacity are unaccepted proposals.

Sunset proposal: 31 December 2026. Retain only approved access-controlled immutable evidence outside Airtable, with hashes and tested restore. No live/queryable operational base in the following year is the proposed outcome, **not an achieved state**. Base deletion requires explicit product-owner authorization, retention clearance and verified gate B. This repository contains no deletion automation and supplies no deletion authority. If gates slip, name owner, impact and revised date; do not waive them.

## Publication hygiene

The supplied PRD contains operational IDs/links and is ignored alongside `.pi-glla/`. Neither was altered. Copy only reviewed project files to an owner-authorized checkout. Scan staged content and history for secrets/PII/operational links; ignore rules do not remove tracked files. The owner subsequently authorized the private `protocol/PLAA_Schemas` repository. A push runs repository CI; it does not authorize live deployment, production grants, policy decisions or source deletion.

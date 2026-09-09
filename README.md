# PLAA PostgreSQL schemas

Reviewable database implementation of the supplied revised PLAA specification. **No app, production migration, policy approval, deployment, or Airtable sunset is claimed.** Local compatibility baseline: PostgreSQL **16.10** (PostgreSQL 16 features); Python standard library only.

## One command

```sh
make test
```

Requires PostgreSQL 16.10 native tools and Python ≥3.9. On macOS the runner finds `/opt/homebrew/opt/postgresql@16/bin`; elsewhere set `PLAA_PG_BIN` to the directory containing the exact-version tools. Tested locally with Python 3.9.9 and PostgreSQL 16.10 Homebrew. The runner creates a new private temporary cluster, a private Unix socket, nondefault port 55439, and database `plaa_service`. It listens on **no TCP interface**, ignores ambient `PG*` connection settings, checks migration SHA-256 values, loads fictional fixtures, runs tests, then stops/removes only its own cluster. It does not accept a production DSN. Never run PostgreSQL as root.

Alternatively, with a running Docker daemon:

```sh
make test-docker
```

Compose uses `postgres:16.10-bookworm`, no published port, ephemeral tmpfs storage, and a unique project name. Trust authentication is confined to this throwaway container/private native socket; it is **not** deployment guidance. No persistent database volumes or credentials are generated. CI pins Python 3.12.11 and action commit SHAs; the hosted runner/Docker host are not claimed hermetic.

**Observed local evidence:** 7 fresh migrations installed; 7 checksum replays; altered-content checksum rejection; **33 unittest methods passed**; 37 project tables introspected. Docker execution was unavailable (daemon not running); native execution passed. Remote CI evidence is separate: see [GitHub Actions](https://github.com/protocol/PLAA_Schemas/actions) for the exact revision's status. Independent reviewer sign-off remains outstanding. Detailed checks: [review matrix](docs/diego-review-resolution.md).

## Three schemas

| Schema | Purpose | Reader boundary |
|---|---|---|
| `plaa` | Numeric participant identity, temporal catalog/config, submissions, points, IA/IR holdings ledgers, correction pointers, raw bids, immutable Trust revisions, protected audit/context | Member reads use forced RLS and invoker views; admin/ingest use narrow functions |
| `ingest` | Stable source manifests/raw payloads, unresolved submission triage, restricted legacy crosswalk evidence | No member or warehouse reads; reviewed crosswalks do not create auth mappings |
| `export` | Seven explicitly allowlisted **empty** candidate aggregate tables and restricted pending contract records | Warehouse can read only the seven named tables, never core/raw/audit/functions or future tables |

No approved executable export contract exists. `export.build_release` rejects every request. Synthetic sparse/complementary/overlapping-release tests demonstrate why k≥5 alone is insufficient; they are **not** a generic differencing-proof publisher. A reviewed contract-specific forward migration, actual contributor profiling and owner approvals are required before any output is populated.

## Layout and examples

- `migrations/001_core.sql` → extensions, roles, enums, complete PRD entity skeletons.
- `002_integrity.sql` → source manifests, exact numeric validation, immutability, audit, linkage checks.
- `003_config_and_points.sql` → catalog/identity APIs, raw submission processing/review, kudos/corrections.
- `004_settlement_trust_bids.sql` → confirmed-source IA/IR atomic reverse-and-replace, Trust revisions, bids and as-of reads.
- `005_access_exports.sql` → backend transaction context, forced RLS, explicit grants, gated exports.
- `006_review_interfaces.sql` → crosswalk triage, bid revision links, bounded admin reconciliation.
- `007_input_hardening.sql` → finite source dates, numeric NaN rejection, zero-result time provenance and reviewer audit attribution.
- [`examples/synthetic.sql`](examples/synthetic.sql) → readable fictional examples for every core/ingest entity, explicit synthetic policy modes and pending export contract; approved release tables intentionally stay empty.
- [`examples/README.md`](examples/README.md) → walkthrough and expected balances; [`export-preview.json`](examples/export-preview.json) → validated fictional row shapes for all seven export tables, not approved releases.
- [`tests/test_schema.py`](tests/test_schema.py) → positive/negative SQL, actual runtime privilege probes, lock-observed concurrency and rollback tests.
- [`docs/scenarios.md`](docs/scenarios.md) → Given/When/Then scenarios written before implementation.
- [Schema + ERD](docs/schema.md), [decisions and blockers](docs/decisions.md), [migration runbook](docs/migration-runbook.md).

Example member read, **only after a trusted backend has verified a Directory session and authorized its subject**:

```sql
BEGIN;
-- Executed as trusted backend, not by a browser or member DB reader:
SELECT plaa.bind_directory('synthetic-subject-1', 'synthetic-request');
SET LOCAL ROLE plaa_member_reader;
SELECT * FROM plaa.v_member_balance;
SELECT * FROM plaa.balance_as_of('2026-08-31 23:59:59+00');
COMMIT;
```

An arbitrary `SET app.aa_id='2'` does nothing. Binding is stored in a protected table keyed by actual backend PID and transaction ID; the reader cannot bind, insert context or assume a privileged role. The next transaction has no inherited authorization. SQL cannot validate browser sessions: backend verification, pool/driver integration and credential provisioning are production prerequisites.

Settlement imports **confirmed amounts**, not a conversion/allocation algorithm. The fixture shows `plaa.settle(jsonb)` with stable source key, source revision/time, policy/input provenance and expected predecessors. A correction supplies a new key and current batch ID for each affected category (IR uses one monthly round pointer). A zero result supplies an empty issuance array. Failures roll back manifests, reversals, replacements, pointers and audit together. Exact NUMERIC validation precedes typed storage; there is no silent rounding. Net field names are explicit; no previous app/API exists here to require a gross-field compatibility alias.

## Repository and PR workflow

Repository: **[protocol/PLAA_Schemas](https://github.com/protocol/PLAA_Schemas)** (private), created with owner authorization on 8 September 2026. Use `main` as the integration branch. Repository creation does not establish independent schema review, production approval or engineering ownership/capacity.

For changes after the initial baseline:

```sh
git switch main
git pull --ff-only
git switch -c feat/describe-the-change
# Edit migrations, tests, examples and documentation.
make test
git diff --check
git add <reviewed-files>
git commit -m "Describe the schema change"
git push -u origin HEAD
gh pr create --base main
```

1. Inspect existing migrations, integration boundaries and applied history; do not overlay this fresh-only project onto a live schema. Resolve upgrade prerequisites in the runbook.
2. Keep the PR focused; never edit an applied migration. Add a forward migration, regression tests and updated examples/ERD.
3. Review the staged diff, grants/definer functions and actual `make test` evidence. Use the [PR checklist](.github/pull_request_template.md) to record scope, results, risks and unresolved decisions.
4. Request independent database/security review and the requested technical re-review. Record findings, rerun checks and wait for GitHub Actions on the exact PR revision. Do not substitute local results for remote CI evidence.
5. Merge after reviewers approve and required checks pass; prefer squash merge for a focused change. Branch protection/reviewer assignments need maintainer configuration; they are not claimed to be enforced here. Deployment, production credentials, cloud integration and data extraction need separate approval.

`.gitignore` excludes the private supplied PRD (which contains operational identifiers/links), `.pi-glla/`, `.DS_Store`, local secrets and caches. **Ignore rules do not remove already tracked content**: inspect the complete staged diff and history before any future publication. The private PRD is preserved locally; published docs reference sanitized specification sections rather than operational links or source IDs.

## Open production questions

All remain human-gated: kudos receiver-only versus paired economics and historical policy dates; verified Directory mapping/API compatibility and any exceptional legacy-auth ADR; confirmed IA/IR source categories, rounding/calculation authority, earliest reliable history and approved opening adjustments; real export grain/privacy/utility/source-audience approvals and Factorio ownership; named implementers/reviewers, capacity, maintainer responsibilities, proposed dates and support/funding/compensation; retention, independently durable replay, RPO/RTO, restore evidence and deletion authorization. See the [complete decision register](docs/decisions.md). No access-code subsystem is included.

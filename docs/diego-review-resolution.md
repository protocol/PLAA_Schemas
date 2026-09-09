# Technical review resolution and observed checks

Local verification on **8 September 2026**, PostgreSQL **16.10 Homebrew**, Python **3.9.9**. This is implementation evidence, not reviewer/owner acceptance or operational completion.

## Exact command and result

```sh
cd ~/Desktop/PLAA_Schemas
make test
```

Observed final run:

```text
Migrations: 7 installed, 7 checksum replays, changed-content checksum detected
Introspection: 37 project tables; PostgreSQL 16.10; fresh-only upgrade boundary
Ran 33 tests in 9.486s
OK
```

The 33 numbered unittest methods in `tests/test_schema.py` contain multiple SQL assertions/role probes. Fresh installation, fixture loading, checksums and schema introspection run in addition to those methods. Tests use a new private temporary PostgreSQL cluster and clean it up; no existing database was used.

The implementation worker timed out before its final documentation and planned separate reviewer stages. The parent inspected all migrations, tests, fixtures and docs, completed the documentation, added regressions and reran the suite. **Separate independent database/security reviewer sign-off remains outstanding.** At that initial verification, no Git repository or remote existed and GitHub Actions had **not run remotely**. The owner subsequently authorized the private `protocol/PLAA_Schemas` repository; consult its Actions tab for remote results, which are separate from the local evidence above. Docker CLI inspection failed because its daemon was unavailable; the Compose execution path is supplied but unverified locally. Native PostgreSQL was the executed alternative.

## Findings → implementation → tests

Test numbers below refer to `SchemaTests.test_NNN_*` in `tests/test_schema.py`; all listed executable tests passed in the recorded run.

| PRD finding | Implementation | Executed evidence | Still requires human/operational work |
|---|---|---|---|
| 1. Year-end/admin scope | `003`, `005`, `006`: configuration, review, triage, correction and audit/reconciliation APIs. `docs/decisions.md`, `docs/migration-runbook.md` | 005, 021, 024, 026, 032 validate interfaces/audit | Admin UI, real operator monthly close, named owners/capacity, funding, accepted gate dates and dependency-zero evidence are not delivered. |
| 2. Correctable settlement | `002`, `004`, `005`, `006`, `007`: immutable IA results and exact pointers; IR pointer; round locks; expected predecessor; reverse-and-replace; reconciliation; two-clock balances | 013–017, 025–028, 031: multiple corrections, partial category, zero/from-zero, exact replay/conflict, competing corrections, halfway failure, wrong linkage, net totals and late-known reversal | Confirm source allocations/history/calculation authority; integrate profile API. No existing consumer supplied to justify a gross-name compatibility alias. |
| 3. Point-value history | `001` exclusion/PK; `002` freeze/use guards; `003` successor/correction functions | 004, 007, 008, 020, 021: adjacent successor after used open version, rejected overlap/empty/infinite ranges, historical compensation and preserved original amount | Source-specific variable-award adapters and production history approval. |
| 4. Temporal identity | `001` exclusion; `003` typed normalization and event-time resolution; `005` current verified Directory binding | 003, 010, 027: reassignment/adjacency, overlap rejection, unverified email refusal, current status and pool cleanup | Directory backend must actually verify browser sessions and authorized mappings. No access-code system. |
| 5. Submission-less replay | `002` manifest/effect uniqueness; `003` claim, acceptance and atomic policy-gated kudos | 005–007, 021, 022: submission replay, changed batch, changed payload, both kudos modes, failed paired debit rolls back credit | Versioned owner-approved production kudos economics and source mapping. Explicit conflicts currently raise errors; external orchestration must durably quarantine them separately. |
| 6. Audit before data | `002` protected audit triggers before fixtures; `006` crosswalk audit; `007` reviewer-principal capture | 002, 013, 014, 019, 021, 022, 028, 030, 032: first source writes, append-only denial, rollback without false success evidence, temp-catalog spoof regression, reviewer actor | Production actor/session verification, retention and external evidence protection. Owner/superuser can change DDL and disable controls. |
| 7. Trust history | `002`, `004`: separate quantity/valuation manifests, locked sequential predecessor chains and current/as-reported reads | 008, 018, 020, 023, 026: originals retained, revisions, replay/conflict, stale/skipped/wrong-month rejection, exact quantity/unit rules, competing revisions | Trust delivery/source acceptance, real monthly reconciliation, retention and prior-system upgrade mapping. |
| 8. Useful private exports | `005`: seven named persisted candidate tables; no runtime writer; pending contract and always-denied builder. `examples/export-preview.json` | 010–012, 030, 033: private/base/join/function/role/future-object denials, exact column allowlist, sparse/complementary/differencing counterexamples and typed synthetic preview rows | **No production privacy-release engine is enabled.** Synthetic tests demonstrate risks/coarser contributor counts, not a generic suppression algorithm or consumer-approved utility. Real profiling, contract-specific implementation and approvals are required. |
| 9. Raw bids | `001`, `004`, `006`: nullable unmodified source amount, separately named notional, quantity-v1 restriction, immutable bid revision link | 009, 019, 024, 031: $7 source vs $6 notional, NULL preserved, no holdings effect, wrong-member correction denied, invalid dates denied | New bid formats/auction metadata revision adapters and raw-payload retention. No allocation/fill/clearing algorithm. |
| 10. Policy/auth gates | `002` immutable explicit policies; `003` policy requirement; `005` protected transaction context/RLS; `docs/decisions.md` | 006, 010–012, 027, 030: missing/unapproved policy, synthetic production-use denial, context spoof/role switching/search_path/default-execute probes | Actual Directory integration, real production policy approvals and any separately authorized legacy-auth exception. |

## Coverage and limits

- **Schema sense checks:** 001 verifies every core/ingest table has a fictional example and RLS; 029 matches ERD nodes and FK edges to the live catalog. 008/020/031 check exact precision, numeric sentinels, dates and references. 033 type/constraint-checks export previews in temporary copies without authorizing release.
- **Runtime privilege realism:** probes use `SET SESSION AUTHORIZATION` to non-owner runtime roles, not merely a superuser's unrestricted session. A small number of owner probes exercise trigger/constraint defenses; source effects in fixtures use restricted runtime APIs. Fictional policy/contract seed records intentionally require owner authority.
- **Concurrency:** settlement and Trust races assert an observed database lock wait and one stale-predecessor loser; exact retry concurrency returns one effect. This is deterministic local coverage, not load/soak testing.
- **No existing-target upgrade:** only fresh installation plus runner checksum replay is supported. An actual preexisting schema requires an authorized inventory, conflict preflight, reviewed forward migrations and upgrade fixtures. These were not available and were not fabricated.
- **Not implemented:** admin UI, Directory browser-session verification, production ETL/plaa-sync adapters, warehouse delivery/privacy contract builder, cloud provisioning, PITR/independent replay drills, real consumer usability/utility, historical backfill and Airtable sunset.
- **Known narrow APIs:** draft allocation amendments, source-confirmed variable submission awards and auction metadata corrections need further reviewed adapters. Unknown or unsupported workflows cannot use generic direct DML as a workaround.

## Review fixes applied locally

- Explicit `pg_temp` last in every fixed function search path, preventing temporary tables from shadowing unqualified system catalogs used in audit; regression 030.
- Private cluster directory under short `/tmp/plaa-disposable-*` rather than inherited nested macOS TMPDIR, avoiding Unix-domain socket path overflow while retaining mode 0700/no TCP.
- Finite optional business dates and positive auction numbers; stored NUMERIC NaN defense; finite economic time/cutoff required even for a zero-issuance batch; regression 031.
- Review audit `actor` now uses the changing text reviewer principal instead of only the shared database principal; regression 032.
- Synthetic IA input manifest lists the original and compensating point events rather than only the original credit. Source-confirmed amounts remain imported, not recalculated by an invented economic policy.

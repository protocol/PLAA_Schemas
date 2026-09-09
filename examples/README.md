# Reading the examples

Run `make test` from the project root. It creates and destroys its own database; do **not** load these examples into an operational database.

## `synthetic.sql`: a connected operational story

Every `plaa` and `ingest` table receives a fictional example, with audit active. Generated IDs are deterministic only in this fresh, empty fixture database. Applications must use returned IDs rather than assume these values.

1. A manually maintained region and asset support eight synthetic members and verified temporal Directory identities. A reviewed legacy crosswalk remains restricted staging evidence, not a login mapping.
2. Two categories and activities are enabled for one August round, with relational allocations and regions.
3. A raw bot submission is processed through its source manifest, accepted by a text reviewer principal and credited **10 points** using point-value version 1.
4. The used schedule closes on 20 August, with an adjacent **20-point** successor. A historical correction reverses the original 10 and posts **12**, without editing the original value/event.
5. Two explicitly synthetic-only kudos policies demonstrate receiver-only (+10) and paired (+20 / −20) effects. These examples choose no production economics.
6. Confirmed IA amounts of **100 + 50** and IR of **25** are imported with immutable provenance. A separate source-backed opening adjustment is **5**. Member 1's example balance is **60 IA + 25 IR + 5 unallocated = 90**. The whole fixture ledger totals **180**. These are confirmed example amounts, not a points-to-PLAA conversion formula.
7. Team holdings revise **123.12345678 → 124.12345678 units**. Separately supplied Trust value/NAV revisions retain both originals. Quantity never generates a valuation.
8. A bid for **3 Rights at $2** preserves its source-reported **$7**, even though calculated notional is **$6**. Another bid has no source amount and remains NULL. Neither changes holdings.
9. A pending export-contract record illustrates the required metadata. A backend-bound transaction demonstrates the member's RLS read.

Source payloads are fictional; `example.invalid` is not a real evidence link. Each write's source reference, manifest and audit evidence can be followed through [the ERD](../docs/schema.md).

## `export-preview.json`: shapes only, not releases

This file supplies one readable row for **each of the seven export candidates**. They form a separate toy dataset, not aggregates of the operational fixture. Tests check their keys and PostgreSQL types/constraints in temporary copies; the real export tables remain empty.

A contributor count of eight does **not** authorize a release. Related cuts may reveal a suppressed cell by subtraction, and successive releases may isolate one participant. A missing/suppressed value is unavailable, not zero. Actual contract-specific suppression, rounding, cross-release tests and source/consumer approvals must precede any real output.

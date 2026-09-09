# Executable scenarios (specification-first)

Derived from the supplied revised PRD; synthetic examples are not program approval.

| ID | Given | When | Then |
|---|---|---|---|
| S01 | Empty private PostgreSQL 16 database | Apply ordered migrations twice | Dependencies exist; checksums match; no repeated DDL/data effects |
| S02 | One temporal identity | Add adjacent assignment / overlapping or empty interval | Adjacency succeeds; overlap/empty fails; current and historical lookups differ |
| S03 | Used open point schedule | Close after recorded uses and add successor | Original amounts unchanged; adjacent event-time lookup; audit retains open predecessor |
| S04 | Durable raw submission | Accept twice or retry with changed payload | One credit; explicit conflict on changed payload; acceptance atomic |
| S05 | Submission-less kudos | Retry in another batch, paired/receiver-only approved synthetic policies, missing policy | Deterministic effects once; no default economics; missing policy denied |
| S06 | Recorded point | Reverse / historical correction | Exact opposite same member/round/activity; immutable versioned manifest; no second reversal or reversal of reversal |
| S07 | Confirmed IA allocation | Close, correct twice, partially correct, zero then nonzero | Immutable results, reconciled issuance sets, exact current pointer, unaffected categories unchanged |
| S08 | Competing IA/IR corrections | Both expect same predecessor | One winner; stale loser; no partial reversal or pointer mutation |
| S09 | IA/IR reverse-and-replace | Inject transaction failure after posting | Entire write and its audit roll back |
| S10 | Late holdings import and correction | Query effective cutoff versus knowledge cutoff | Both clocks respected; net IA/IR/unallocated sums equal total |
| S11 | Wrong ledger linkage or reversal | Attempt through runtime API or base DML | Invalid source/round/category/member rejected; direct runtime DML denied |
| S12 | Trust quantity and supplied valuation | Replay, revise, branch, skip or race | Sequential same-key chain; original and as-reported reads; no invented valuations |
| S13 | First import | Inspect audit / try mutate audit | Actor/key/before-after/correlation exists from first write; mutation denied |
| S14 | Member SQL reader | Spoof SET, search_path, join, role switch, missing/malformed context | No impersonation; transaction-specific verified backend binding; pooled cleanup fail closed |
| S15 | Warehouse reader without approved contract | Read exports, core, raw, audit, functions or future objects | Only named empty aggregate tables readable; all escape paths denied |
| S16 | Sparse and overlapping synthetic cells | Consider fine-grain totals/revisions versus coarser alternatives | Small/complementary/differencing risks demonstrated; no generic privacy claim or production release |
| S17 | Quantity bid with discrepant or absent source amount | Store/read bid | Source amount preserved or NULL; separately named notional; holdings unchanged |
| S18 | Unapproved economics/source format | Request computed settlement, kudos or unsupported bid format | Fail closed; confirmed allocations only; no rounding, fills or clearing |

Tests map these scenarios to named checks in `tests/test_schema.py`. Operational acceptance, real privacy profiling, restoration and deployment are not simulated as completed.

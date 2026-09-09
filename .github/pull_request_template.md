## Change and reason

<!-- Name the affected schemas, PRD sections and migration numbers. -->

## Validation

- [ ] `make test` or `make test-docker` passed on this exact revision; attach actual command/counts.
- [ ] GitHub Actions passed remotely (do not substitute local results).
- [ ] Positive, rejection, retry/conflict, correction/rollback and concurrency cases updated as applicable.
- [ ] Actual-role RLS, direct-DML denial, search_path and export allowlist checks pass.
- [ ] Synthetic examples, schema/ERD and review-resolution matrix match the changes.

## Migration and review

- [ ] No applied migration edited; forward migration and relevant upgrade preflight tested.
- [ ] Existing-target integration, if any, has an explicit supported starting schema and reconciliation plan.
- [ ] Independent database/integrity reviewer assigned.
- [ ] Security/privacy reviewer assigned for role, function, policy or export changes.
- [ ] Open economic, auth, privacy and operational approvals are listed, not silently selected.
- [ ] Staged files/history contain no private PRD, operational IDs/links, real participant data, secrets or agent metadata.

## Risks / unresolved decisions

<!-- Name owner and required evidence. A schema PR is not production cutover, funding, economic-policy, export-release or Airtable-deletion approval. -->

# W01-Fast bounded real-data scientific parity protocol

Status: experimental design, not an executed parity claim.

## Immutable controls

- Original production reference: `workflow01-final-architecture` at `8febc7b99ce1f7752c7553ed6023976a643f8621`. Do not modify or execute production W01.
- Work only on `w01-fast-development`. No deploy, Zenodo write, Shiny change or downstream dispatch.
- Obtain frozen, read-only local artefacts; avoid downloading the full archived corpus in CI.
- Identity invariants: `(source,source_record_id)` is the authoritative manifestation identifier; length-prefix components to avoid delimiter ambiguity. Numerical row offsets and array indexes may be ephemeral lookups only.

## Phased comparisons

1. **Fixture preparation (bounded):** derive a deterministic identity-key sample from historical manifestations, including unchanged works, singleton additions, suspected duplicate additions, ambiguous DOI/title and source collisions, and previous human adjudications where available. Keep a record of sample selection and historical source file digests.
2. **Candidates:** compare full reference and incremental exact/fuzzy candidate sets as ordered pairs of stable IDs and evidence fields. Report missing/extra evidence, not just pair counts. Do not declare parity from speed or count alone.
3. **Decision ledger:** verify all historical human decisions remain assigned to the same identity pairs regardless of source ordering; ensure no decision is reattached by index.
4. **Clusters:** compare stable identity memberships and preservation of historical cluster IDs for unchanged works, not merely numbers of clusters.
5. **Canonical records:** compare affected work JSONL field-for-field and unchanged work raw JSONL byte-for-byte. Audit repairs, abstract strip actions, and record provenance.
6. **State/recovery:** check snapshot hashes, delta linkages, replayed state, and failed/interrupted resume against uninterrupted deterministic results.
7. **Benchmark:** capture wall-clock runtime, peak memory, object sizes, candidate/decision counts and GitHub Actions minutes. Separate algorithm runtime from download and debug overhead.

## Acceptance criteria

- Zero unexplained mismatch in candidate identity pairs, decisions, cluster membership, unchanged cluster IDs, canonical data, repair audits and record provenance.
- No manifestation loss or duplication; all relevant source records accounted for.
- All authoritative persisted keys stable under row permutations.
- Repeat the same batch twice and replay after simulated interruption with identical resulting state hashes (excluding explicitly variable diagnostics).
- A failed acceptance gate blocks any production migration proposal until the discrepancy is characterised and resolved.

## Scope and cost gate

Begin with a small bounded frozen fixture and local/cheap CI validations. Only broaden to large historical data once path, exact sizes, access authorisation and expected GitHub Actions cost are established. Do not launch production W01 or bulk Zenodo retrieval as part of this document.

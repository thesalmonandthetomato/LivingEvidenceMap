# W01-Fast: validated scope and controlled activation

Status: **non-publishing experimental branch only**, not production-approved.
Branch: `w01-fast-direct-delta`.
Most recent passing end-to-end reviewed-continuation acceptance run:
https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/39981128951
Passing run commit: `7ec50f08c45ad22f578e8d3d494572620d72efe9`.

## Observed acceptance evidence

- Scientific full October nonpublishing validation previously passed; historical identity preservation and direct-delta replay were checked separately. Do not rerun the corpus to test small changes.
- The isolated Shiny decision-return validator rejects mismatched input hashes and incomplete decisions.
- `test_complete_reviewed_continuation.R` invokes the actual `run_full_incremental_update.R --phase canonical --reviewed-root` against synthetic previous state, a pending review checkpoint, approved human repair, and original source streams. It checks rebuilt canonical content against replayed canonical output.
- `test_canonical_repair_application.R` invokes the unchanged production canonical builder and checks a human title edit and application audit.
- Repair-only canonical reconstruction must retire the prior canonical work even if cluster membership does not change.
- Direct-delta writer must **not** emit unchanged manifestation-map upserts for canonical-only repairs.
- `test_routing_contract.py` confirms the legacy default, no Fast publication and no W02 dispatch.
- Tests exercise negative/fail-closed conditions deliberately; error messages in successful jobs may be expected.

## Unresolved blockers before activation

1. **Live review handoff not wired.** `fast_shadow` currently saves a pending checkpoint as a recoverable GitHub Actions artifact with 14-day retention, but does not publish a Fast review queue to the live Shiny backend or automatically ingest the exported approved decisions/repairs. The tested `verify_shiny_return.R` and `resume_review_decisions.R` are local components, not yet an operational Shiny round trip.
2. **No authorised production write path.** Fast remains nonpublishing, and W02 dispatch is intentionally disabled. The legacy default MUST remain intact until a separate explicit activation decision after operational checks.
3. **Recovery and durability.** A 14-day GitHub artifact is not sufficient persistent state for outstanding human review. Define and test an immutable, resumable checkpoint archive before live use.
4. **Operational parity.** Compare the production-shaped handoff, repair provenance, scoring rules and downstream consumer requirements on a controlled frozen update, including genuine Shiny-return data, before considering publication.
5. **Runtime setup.** The small acceptance test uses Ubuntu-provided R packages to avoid the recurring `r-lib/actions/setup-r` download stall. The experimental `fast_shadow` still uses `setup-r`; change only that job if its runtime stalls, with dependencies tested first.

## Controlled activation sequence (not authorised here)

1. Keep `workflow01-final-architecture`, `main`, production W01, W02 and Zenodo state unchanged.
2. Implement the Fast-only Shiny handoff and durable checkpoint restore **only** in the isolated branch; reuse existing production validation modules and avoid reimplementing decisions.
3. Test one frozen, very small incremental source update with a real Shiny round trip, including at least one approved repair; validate complete canonical, pair ledger, map, delta, replay, SHA, audit and rollback equivalence.
4. Review negative cases: missing/tampered decision, missing approval, expired checkpoint, altered historical manifest, partial repair audit, duplicate review keys and a replay mismatch must all fail closed before external mutation.
5. Only after explicit separate approval, plan a controlled release with a backed-up previous state and a named rollback path. Do not infer approval from a passing shadow test.

## Working constraints

- All implementation and validation changes restricted to `w01-fast-direct-delta`.
- No changes to `main`, `workflow01-final-architecture`, the Shiny repository, W02 dispatch or live Zenodo.
- No full-corpus rerun to validate a trivial patch.
- Prefer actual R fixture execution, consolidated tests and inspecting GitHub job results without user supervision.
- No publication or workflow dispatch from this experimental pathway.

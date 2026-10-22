# W01-Fast production-readiness review (22 October 2026)

**Status: validation complete for the frozen October update; not merged or published.**

## Verified

- Direct-delta microfixture: GitHub Actions [39751137745](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/39751137745), success.
- Real October scientific canonical comparison and unchanged W01 replay: [39751536887](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/39751536887), success.
- Real October replay and the existing W02 canonical handoff validator: [39783072131](https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/39783072131), all job steps successful.
- Final October run checks 136,057 source manifestations. Validation has no publication, downstream dispatch, or production branch mutation.

## Safeguards confirmed by code review

- `run_full_incremental_update.R` requires frozen authoritative state and the original source streams; `--delta-writer direct` is opt-in, not the default.
- `stage_production_pair_ledger.R` verifies historical stable-identity-to-index continuity and preserves old pair rows before appending new decisions.
- `update_clusters_by_identity.R` rejects a union involving **two or more historical cluster IDs**. Preserve this fail-closed behaviour in the initial release.
- `write_direct_delta.R` refuses shifted historical manifestation indices, checks affected historical cluster rows, verifies historical provenance retention and creates a delta for the unmodified production replayer.
- `workflow_01_replay_delta.R` and its target state-hash checks remain untouched.

## Initial-release scope

- Permit append-only updates, attachment of new records to at most one historical cluster, and merging of new-only clusters.
- Do **not** automatically merge distinct historical clusters. Such a bridge is a supported *safe stop*, not successful automatic adjudication. Handling historical-cluster aliases and survivor decisions is separate future work.
- Retain the existing W01 production workflow as the rollback route until an independently reviewed switch-over.
- No automatic Zenodo publication, branch merge or W02 dispatch is authorised by these tests.

## Remaining release gate

Review and approve how the isolated implementation is wired into the production entry point, with a rollback to the existing W01 path. Run a final non-publishing smoke test of that **integration**, not another whole-corpus scientific rebuild unless the integration materially changes computation.

The W02 parser fix in `scripts/updater/workflow_02_validate_canonical_handoff.R` is present **only on the experimental branch**; it must not be silently promoted into production as part of W01-Fast.


## Publication contract follow-up (22 October 2026)

- Isolated runtime publication-contract audit validated against a complete synthetic handoff (Actions run 39816392978, PASS). It rejects modified stage checksums, replay failure and absent repair ledger.
- Earlier full October scientific equivalence and legacy W02 handoff were validated in Actions runs 39751536887 and 39783072131 (PASS).
- Inspection of retained artifacts for those runs shows small reports only, **not** the full restored manifestation, canonical, human-gate and delta input state. A further *real-state* publication-contract audit would therefore require an authoritative read-only restoration; no existing retained artifact is sufficient.
- The separate stage_production_handoff.R copies final/canonical outputs but does **not** create the complete canonicalise job artifact: historical state, source union, human-review provenance and checksum file must come from authenticated original processing, not fabricated defaults.
- **Release block:** the experimental workflow copy explicitly rejects selecting Fast. The adapter does not currently enter the live publication job, and must not be treated as production-ready until the full end-to-end contract is established.
- Do not merge to workflow01-final-architecture or enable production Fast based only on the synthetic contract audit. No repeat full October scientific run required if preserving validated scientific algorithms; a targeted authoritative handoff test remains necessary.

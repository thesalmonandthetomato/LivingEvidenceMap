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

## Final acceptance dependency check (22 October 2026)

- Frozen October preparation artifact from run 39643422706 is no longer available through GitHub Actions. Full real-data acceptance cannot reuse that artifact.
- Frozen October outputs retained for run 39783072131 consist of a small report artifact, not full restored/processed state.
- Therefore the combined Fast-output -> publication-shadow validation **cannot** currently be claimed as complete, despite passing synthetic tests and prior full-replay tests.
- Real-output acceptance requires re-creating frozen source state, executing W01-Fast with the verified direct-delta writer, and staging the outputs with genuine review provenance. There is no verified normalised human-repair ledger in the retained reports. Do not substitute historical cumulative repairs for current normalised review decisions, or silently create an empty ledger without substantiated zero-review evidence.
- Even if the final acceptance passes, the production workflow's experimental Fast engine remains explicitly disabled. Enabling production requires separate review of executable routing, human-adjudication handling and the existing Zenodo/W02 lifecycle. This should not be described as just a validation checkbox.


## Controlled production integration checkpoint (23 October 2026)

Branch scope: `w01-fast-direct-delta` only. No deployment, Zenodo upload, Shiny queue publication, W02 dispatch or changes to `workflow01-final-architecture` are authorised.

1. Human adjudication: **NOT COMPLETE.** Fast currently fails closed if the scoring set contains `review` classifications. Unlike the legacy adjudication and canonicalise jobs, it does not build, register and reconsume a Shiny human-review checkpoint. A zero-review certificate is valid only when the current run has no review cases and unchanged historical repair provenance. Do not claim Fast is ready for datasets with uncertain pairs.
2. Publication handoff: **NON-PUBLISHING INTEGRATION ADDED.** The Fast job stages `assemble_publication_shadow.R` after its review provenance certificate, audits the production-format publication contract and retains only an evidence manifest as a small artifact. This does not authorise live Zenodo writes.
3. W02 handoff: **SCIENTIFIC CONTRACT PREVIOUSLY VERIFIED, NO LIVE DISPATCH.** Prior full October W02 contract run was successful. Fast does not dispatch W02. Do not promote any unrelated W02 parser fixes from this branch.
4. Engine switch and rollback: **ISOLATED.** Legacy remains default. Fast preparation checks out this experimental branch and uses metadata-only indexing; legacy preparation checks out the original branch and retains conventional candidates. Fast job cannot reach legacy publish job.
5. Final acceptance: **PENDING.** The routing and fixture tests prove structural contracts, and a previous authoritative October shadow passed; the combined Fast path from the new production entry point has not been executed. A deliberately bounded final test and direct human-review path validation are needed before seeking permission for production release.

Do not merge the workflow merely because structural or zero-review tests pass. The Shiny review/resumption interface is the material outstanding implementation blocker.

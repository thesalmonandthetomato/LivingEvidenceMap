# Workflow 08b: citation chasing design and implementation contract

Status: **design and isolated development only; not active in production**. Agreed 24 October 2026.

## Baseline and rollback

- Production working branch: `workflow01-final-architecture`.
- Immutable pre-development commit SHA: `b7a22548f34e4ae6a27cc8ac7db325da82989de3`.
- Backup branch: `legacy-pre-w08b-20261024`, created at that exact SHA before the first W08b edit.
- Preserve the working W00–W10 workflow behaviour until W08b is validated.
- All W08b work is committed normally and is separately reversible through targeted `git revert`, never history rewriting or force-pushing.
- Git rollback does not delete/revert external Zenodo archives or already published outputs.
- A pre-W08b annotated Git tag was proposed but **has not been created**; the existing backup branch and exact SHA are the verified rollback references.

## Inputs and release identity

- The single authoritative, published W08 pointer and checksum-verified **included-only** canonical JSONL. October baseline: 22,923 included records from W08 run 40028381004.
- Retain W00 source-manifestation identity and identifiers for each canonical work: Lens ID, OpenAlex Work ID and normalised DOI.
- Version-controlled search strategy: `user_input/workflow00_search_strategy.json`, currently **v2**, containing `maricultur*` in `farm_terms`. W08b must resolve and archive the exact version and provider-specific translated expression for every run; never hard-code a truncated search.
- Every iteration is part of the **same monthly update_id** as its originating W00–W08, not a new monthly update.
- First one-off baseline: chase all W08 included seeds. Subsequent monthly rounds: compare W08 included records with the previous accepted W08b seed register.

## Provider routing and cost controls

1. **Lens first** for a seed having a Lens ID or a DOI that Lens can resolve. Obtain reference and citing Lens ID lists with explicit requested API fields, checking completeness/pagination.
2. **OpenAlex only as fallback** for seeds not resolved in Lens **and with a known OpenAlex Work ID**. Do not overlap complete Lens results with OpenAlex merely to increase coverage. A successful Lens zero-result response is not an error.
3. Preserve DOI-only seeds without claiming a successful search; attempt Lens DOI resolution, then record unresolved status if it fails. OpenAlex fallback requires an OpenAlex ID.
4. The two providers' relation schemas and admissible title/abstract/keyword NOT expressions must be tested with small, inexpensive requests before full-corpus execution. Fail closed if equivalent field-limited exclusion cannot be expressed reliably; never silently omit NOT.
5. Deduplicate discovery IDs and maintain all seed→candidate edges with `backward`, `forward` or both and provider evidence. Retrieve candidate bibliographic records by batched IDs **AND NOT the latest translated source-specific original search expression** in title, abstract and keywords. Apply exclusions before bulk candidate download where supported.
6. Deduplicate within and across providers, against historical W01 source identities and against prior W08b candidate history. Only genuinely new candidate manifestations are submitted to W01.
7. Bound API requests, pagination, retries and cost. Archive query text, returned counts, usage, zero-results and failures before authorising the initial full run.

## Persistent state

Use restricted Zenodo archival and checksum-verified repository pointers. Do not edit previously deposited state in place. Design three append/reconcilable datasets:

### Seed register (one row per W08 included canonical work)
`record_id`, `w08_release_id`, `lens_id`, `openalex_id`, `doi`, `preferred_provider`, `lens_resolution_status`, `openalex_resolution_status`, `backward_status`, `backward_completed_at`, `backward_rechecked_at`, `forward_checked_at`, `reference_count_previous`, `reference_count_current`, `reference_count_source`, `latest_error`, `update_id`.

Backward-search eligibility:
- first one-off: every resolvable seed;
- subsequent months: newly included seeds, incomplete/failed seeds, or any completed seed for which its current provider reference count **increased** relative to the count recorded for the prior completed search (e.g., 5→10);
- log decreases or unexpected count inconsistencies for audit, without automatically discarding historical edges.
A backward search only becomes `complete` after all accessible reference IDs have been retrieved and archived. Track provider-specific completeness and timestamps.

Forward-search eligibility: **every resolvable included seed every month**. Refresh the full forward ID set rather than relying exclusively on publication/indexing date filters, because old works can acquire newly indexed citation links. Download bibliographic data only for newly discovered candidate IDs.

### Citation-edge register (one row per seed, related work, direction, provider)
`seed_record_id`, `related_provider_id`, `related_doi`, `direction`, `provider`, `first_seen_at`, `last_seen_at`, `update_id`, `source_request_id`, `status`.
Never erase previously observed evidence when a current provider response differs.

### Candidate register (one row per identity-resolved candidate)
`candidate_key`, `lens_id`, `openalex_id`, `doi`, `first_seen_at`, `last_seen_at`, `provenance_edge_count`, `search_strategy_version`, `not_filter_applied`, `existing_w01_identity`, `previously_submitted`, `w01_handoff_status`, `subsequent_disposition`.
Retain backward/forward/both and all referring seeds as edges, even when candidate records are already represented or excluded.

## One-generation orchestration

Normal monthly W00→W01→W02…W08 yields an accepted included canonical and canonical checksum. W08b then searches only that accepted snapshot. It archives source-state and candidate-state before allowing a **single** supplemental W01-Fast invocation. New citation-chasing manifestations enter W01 under a clearly distinguishable source/provenance pathway and resume W02…W08, retaining the **same** `update_id` and original monthly search provenance. The supplemental W08 completion bypasses W08b, then permits W09→W10. No automatic second citation generation in the same update. Do not enable any of this integration until standalone equivalence and handoff tests pass.

Newly included records produced by citation chasing are eligible for backward chasing in the following monthly cycle (unless explicitly run in a separate future one-off exercise).

## Flow-diagram integration (planned, not yet activated)

W09 Figure 1 should gain a distinct **Citation chasing** box immediately before the final canonical/map box, with counts grounded in the accepted W08b register: seeds backward chased; seeds forward checked; new candidate manifestations; novel works after cross-provider/existing-corpus deduplication; newly included records after supplemental W01–W08; and exclusions after screening. Keep main W00 database-search totals separate and preserve the existing W01/W08 reconciliation identities. Do not fabricate counts or simply add citation candidates to existing included counts; update the final diagram only after a validated reconciliation contract. W10 republishes this W09 figure, with no separate W10 identity transformation.

## Validation and activation gates

1. Verify rollback branch SHA equals the recorded pre-development SHA.
2. Audit canonical source-ID coverage and the v2 search translation (including `maricultur*`).
3. Test Lens relationship field selection, pagination, DOI resolution, NOT filtering and provenance on a small seed sample; fallback OpenAlex only for Lens-unresolved seeds with OpenAlex ID.
4. Test reference-count changes, monthly forward edge set-difference, re-runs, interruptions and resumability.
5. Validate candidate deduplication, existing W01 identity filtering and one-generation same-update handoff using synthetic/local cases before live execution.
6. Benchmark requests, latency and charges before approving full baseline.
7. Only after independent acceptance: activate W08→W08b→supplementary W01→W09 gates, with rollback of the new routing isolated from the original pipeline.

No production stage, trigger or upstream scientific data should be changed by this design document.

## Identifier audit finding (24 October 2026)

GitHub Actions W08b audit run 40099757804 **passed checksum and record-count verification**, but is **not** a provider coverage PASS: its 22,923 W08 included records all have no `manifestations` array in the final W08 JSONL. A total of 15,968 have canonical DOI; Lens/OpenAlex ID coverage from this file alone is zero. Accordingly, do not start citation API tests or treat `manifestations_missing` as permanent unresolved identity. The audit must recover source identifiers from the authoritative restored W01 canonical source-manifestation data, then join by stable canonical `identity.record_id`, requiring exactly one match per included W08 ID and retaining W08 canonical DOI as an independent fallback. Use the existing checksum-verifying W01 baseline-plus-delta restore machinery; never infer provider IDs from unrelated fields or fetch all W00 records to guess identities. The W08 checksum remains `5be8c3e2f236650e13550156f4851220c24add4ff58f81e16d2bb94bf6bd61f1`. Existing `audit_identifiers.R` is a structural diagnostic, not yet the production W08b identifier extractor.

## Implementation progress: checkpointed Lens discovery (24 October)

Validated: `test_workflow08b_edges.yml` completed successfully in run 40110927027; separate Lens API test retrieved all 79 backward and 38 forward IDs from its single seed.

A new isolated R entry point, `scripts/workflow08b/run_lens_discovery.R`, now reads the verified crosswalk CSV and retrieves both directions for bounded Lens-ID seeds, checks identifiers against Lens reported counts, retains append-only local checkpoints, and invokes `merge_edges.R` for deduplicated provider-specific IDs. No GitHub Action has been added for this component; do not repeat long W01 reconstruction just to test it. Example manual invocation in an environment with `LENS_API_TOKEN` and a verified private crosswalk:

```sh
Rscript scripts/workflow08b/run_lens_discovery.R /private/seed_identifier_crosswalk.csv /private/w08b-state 10
```

**Not ready for monthly production:** This manual runner only processes direct Lens-ID seeds. It does not yet handle DOI-based Lens resolution, OpenAlex fallback, comparing fresh monthly forward lists against historical lists, reference-count-triggered backward refresh, permanent Zenodo registration, cross-provider identity resolution, NOT-filtered candidate bibliographic retrieval, or W01/W09 orchestration. Existing output folders must remain private. It is not automatically scheduled or triggered.


## Incremental monthly development (24 October 2026)

- The ten-seed isolated Lens trial is now **10/10 complete**, with preserved restricted Zenodo checkpoint **23623623** (run **40118419800**). The initial four incomplete seeds were caused by Lens omitting zero-direction count fields; this is fixed.
- `scripts/workflow08b/restore_discovery.R` restores the prior restricted checkpoint using Zenodo file checksums. It does not reconstruct W01.
- `scripts/workflow08b/plan_monthly.R crosswalk.csv previous_status.jsonl update_id output_dir` produces an offline deterministic per-seed plan and aggregate route counts. It never sends provider requests.
- The crosswalk now routes unambiguous **DOI-bearing** seeds through Lens DOI resolution *before* OpenAlex fallback; DOI resolution and actual OpenAlex fallback API implementations are still pending.
- `run_lens_discovery.R` accepts an optional fourth argument `update_id`: within that update each complete Lens-ID seed is refreshed once for forward citations, while backward edges are re-emitted only for newly eligible/incomplete seeds or when reported reference counts grow. Historic edges remain in the journal. Subsequent updates must use a checksum-verified restored checkpoint. Existing trial calls without `update_id` retain their skip-completed behaviour.
- `merge_edges.R` now accepts an empty but valid edge journal as an explicit zero-citation result.

**Not yet production-ready:** authoritative prior-month Zenodo pointer registry, monthly forward-edge delta reconciliation, DOI Lens lookup, OpenAlex fallback, licensed NOT-filtered candidate retrieval, cross-provider and W01 identity resolution, one-generation W01-Fast handoff, and Shiny/W09 publication integration. No production W00–W10 execution behaviour has been changed for W08b.

## Bulk Lens retrieval correction

The original per-seed runner was inefficient. As directed, the replacement `scripts/workflow08b/run_lens_bulk.R` follows `nealhaddaway/citationchaser`'s `R/get_refs.R` pattern: one `query.terms.lens_id` array containing **up to 500 distinct seed IDs**, with `size=500` and an explicit list of relationship fields. Returned works are mapped individually to seed record IDs, checked against relationship counts, and checkpointed at seed/edge level. HTTP errors are treated at **batch level**, not attributed to all 500 seeds. Incomplete/paginated responses fail closed, and previous finished seeds are not re-queried during the baseline. The old one-ID runner is retained only for compatibility, not intended for the full baseline.

The bulk runner has been **committed but not yet executed**. It still needs full-corpus orchestration, a private persistent crosswalk and completion of DOI/OpenAlex fallback, candidate filtering, cross-provider identity reconciliation and W01 handoff. The earlier ten-seed and 100-seed checkpoints are still preserved; the latest is Zenodo 23624392.

## November incremental-readiness implementation (31 October 2026)

- The historical October discovery archive at restricted Zenodo record `23627417` was checksum-restored in Actions run `41213640453`. It contains both Lens and OpenAlex seed-status journals, the merged citation-edge CSV and the provider-specific candidate-ID register. The audit counted 16,377 Lens status entries, 1,293 OpenAlex entries, 952,077 distinct direction edges and 336,264 provider-specific candidate IDs. These are not unique study counts.
- `docs/workflow08b/monthly_checkpoint_registry.json` registers this accepted source state. `resolve_previous_checkpoint.R` selects precisely the preceding month; `resolve_monthly_release.R` checks the W01 and authoritative W08 pointers, canonical checksum and population reconciliation and rejects an earlier month's release.
- `plan_monthly.R` now reads both provider journals, flags new seeds, unchanged historical seeds requiring forward checks, same-update completed seeds, DOI changes and provider switches. It fails closed if the required historical journals are unavailable. It is still an offline plan and authorises no API calls.
- `monthly_candidate_delta.R` compares new provider-specific citation IDs against the previous candidate-ID register and preserves all current edges for newly discovered IDs. Provider IDs are not treated as cross-provider work identities.
- Offline tests passed in runs `41211731859`, `41211964103`, `41212266789`, `41213565763`, `41213877544` and `41214000267`; temporary test workflows were deleted after successful verification.
- `workflow08b_monthly_preflight.yml` is a read-only, `workflow_dispatch`-only workflow. For a new completed monthly W00–W08 release, it reconstructs the latest W01 source identities, matches the included W08 seeds, restores the prior W08b checkpoint and produces a private monthly seed plan with an aggregate public artifact. It does **not** retrieve citations, change canonical data, or start W01–W10.

**Activation remains gated:** the current W08/W01 27,726-seed crosswalk audit (run `41211361474`) must pass; then test actual November provider discovery, history/edge delta reconciliation, DOI/OpenAlex fallback, historical W01 identity exclusion, bibliography retrieval and single-generation supplemental W01–W08. Only after those checks should the standard W08→W09 trigger be changed to invoke W08b. The presence of the new preflight is not evidence of automatic November readiness.

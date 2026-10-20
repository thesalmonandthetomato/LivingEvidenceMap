# W01-Fast affected-only canonicalisation adapter: implementation constraints

Verified against unchanged `scripts/updater/workflow_01_build_canonical_jsonl.R` on `w01-fast-development` (20 October 2026).

1. The existing canonical builder reads **all records** from source JSONL input streams and checks both `setdiff(cluster_map$key,all_keys)` and `setdiff(all_keys,cluster_map$key)`. Supplying a partial affected-work map with full source streams therefore fails. Its accepted input contract is a **complete one-to-one key set**, not a selectable work subset.
2. Scientific materialisation (field preference, repairs, abstract stripping, source provenance, JSONL output and manifest) remains in that original builder. Do not rewrite those scientific rules in W01-Fast.
3. An isolated adapter may select **all manifestations of every affected successor work**, then construct isolated filtered source streams with exactly the same source identity keys. Only then can the unchanged production builder be reused in a local-only parity test. This is not yet implemented or approved for production.
4. Any approved data-quality repairs and strip actions must be scoped explicitly by manifestation identity. The original builder fails for unapplied repairs; blindly handing it full-corpus repair directives while providing only affected records is unsafe.
5. The original builder builds key strings using `paste(source,source_record_id,sep="::")`. An adapter must fail closed on any ambiguity or delimiter collision instead of trusting row offsets or lossy keys.
6. An affected-only canonical JSONL **cannot** replace the complete downstream canonical JSONL without separately assembling unchanged prior canonical works and verifying uniqueness, no omissions, identities, schema, and scientific parity. Do not publish partial output.
7. Before integrating, establish a small fixture running the **unmodified** canonical builder on both full data and correctly filtered inputs; compare affected records field-for-field (excluding explicitly run-dependent provenance where appropriate). Verify repair audit, error paths, splits, merges, zero-change batches and row permutations.
8. The current staging script `prepare_affected_canonical_map.R` is intentionally NOT compatible with an unmodified builder passed the full source corpus, and its manifest states this explicitly.

All development is isolated to `w01-fast-development`. The protected `workflow01-final-architecture` branch, W01 production workflow, Zenodo, Shiny and W02 dispatch must remain untouched.

# Workflow 01 persistent deduplication index

This branch prototypes the batch-agnostic Workflow 01 design without changing the existing WoSCC workflow.

## Contract

1. Source harvests remain untouched upstream.
2. Workflow 01 first applies exact within-source identity filtering on `source + source_record_id`.
3. Repeated identical source IDs in the same batch are collapsed. If the same source ID carries conflicting payloads, processing fails and writes an audit table rather than choosing a record silently.
4. Against a prior manifestation registry, only unseen source IDs are promoted as new manifestations.
5. Bibliographic deduplication then compares promoted manifestations against the persistent historical deduplication index and against other promoted manifestations. Historical old-old pairs are never regenerated.
6. The persistent index is a derived acceleration artefact, not the canonical corpus and not the authoritative duplicate-decision store.
7. The index must be reproducible from canonical/provenance data and versioned with hashes and row-count invariants before Zenodo publication.
8. Routine updates append/rebuild only the index rows needed for newly integrated manifestations. A full rebuild is reserved for schema/normalisation changes or integrity repair.

## Files introduced

- `scripts/updater/workflow_01_source_identity_filter.R`: exact source-ID novelty gate.
- `scripts/updater/workflow_01_build_dedup_index.R`: builds a versioned, checksummed index directory from validated normalised metadata and title q-gram signatures.

No scheduled workflow is enabled on this branch. The next implementation step is incremental candidate querying against this index, followed by Zenodo version publication only after local equivalence checks against the current Workflow 01 candidate decisions.

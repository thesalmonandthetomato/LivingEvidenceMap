# Record repair

This note documents the record-repair stage used to improve bibliographic completeness and accuracy while preserving the original Lens source payload.

## Automated abstract repair: Workflow 01B

Workflow 01B first restores the exact abstract supplied by Lens wherever one is present. Records without an abstract but with a DOI are then queried in Europe PMC using an exact DOI match. If Europe PMC returns an abstract for that DOI, the full abstract is written to `canonical.abstract`; the original Lens payload is left unchanged.

A second pass checks canonical abstracts containing either `...` or `…`, because these were found to be strong indicators of Lens truncation in this corpus. These records are again queried by exact DOI. Europe PMC is tried first and OpenAlex second. Any recovered abstract replaces the entire `canonical.abstract`, rather than being appended to the truncated text. OpenAlex abstracts are reconstructed from its abstract inverted index. All replacements retain provenance and repair history, and provider failures are recorded in the audit rather than altering the raw Lens data.

The repair code is implemented in `scripts/updater/repair_ellipsis_abstracts.py` and integrated into `.github/workflows/patch_workflow01b_full_canonical.yml`.

## Persistent canonical repair store

During repair and validation of the historical full-search corpus, the authoritative working copy is:

`data/canonical/current/repair/records.jsonl`

The file contains the complete canonical search-result corpus in the validated JSONL schema. It is stored using Git LFS because the full JSONL exceeds GitHub's ordinary per-file size limit. A small ordinary-Git manifest is stored alongside it at:

`data/canonical/current/repair/manifest.json`

The manifest records the schema version, repair stage, creation time, record count, SHA-256 checksum, source workflow run/artifact and the archive state from which the current repair was produced.

Actions artefacts remain useful as immutable workflow outputs and audit evidence, but they are not the sole authoritative working state. Once a repair stage has been validated, its full-corpus state is persisted in the repository repair store.

## Repair archives

Repair stages are retained under:

`data/canonical/archive/repair/`

The archive records the successive full-corpus states used to construct the current repair corpus. The current sequence begins with automated abstract enrichment/repair and then records subsequent metadata or human-verified repairs. Before a new repair state is promoted to `current/repair/records.jsonl`, the preceding state must remain recoverable in the archive.

The repair process must preserve record cardinality unless a workflow is explicitly intended to add or remove records. Ordinary bibliographic repair must not silently add, delete or merge search-result records.

## Human-verified canonical repairs

Errors or omissions discovered during screening, deduplication, annotation or manual inspection may be repaired directly in the canonical layer when there is sufficient evidence for the correction. Examples include:

- a supplementary-file title incorrectly indexed as the article title;
- a missing or incorrect DOI;
- a missing, truncated or demonstrably incorrect abstract;
- other bibliographic metadata that can be tied unambiguously to the same record.

The following rules apply:

1. **Preserve the source record.** `lens.raw_payload` and equivalent original-source payloads must not be overwritten. Repairs apply to canonical fields only.
2. **Require record-level identity evidence.** A repair must be supported by sufficiently specific bibliographic evidence, normally including a stable identifier such as DOI, PMID/PMCID, exact article identity, or another unambiguous source match. Topical similarity alone is insufficient.
3. **Replace the canonical value, not the evidence trail.** The corrected title, DOI, abstract or other value becomes the canonical value used downstream, while the original value remains recoverable from the raw payload/provenance.
4. **Record provenance.** Each human-verified repair must record the affected Lens/record identifier, fields changed, previous canonical values, replacement values, evidence/source and repair reason in the repair audit/history.
5. **Archive before promotion.** The preceding validated corpus state must remain recoverable before the repaired corpus becomes `data/canonical/current/repair/records.jsonl`.
6. **Validate after repair.** Re-parse the complete JSONL, confirm expected record count and identities, validate the canonical contract/schema, and calculate a new checksum before promotion.
7. **Do not use screening decisions as metadata evidence.** A RETAIN/EXCLUDE judgement can reveal a metadata problem, but the bibliographic correction itself must be independently supported.

### Example: supplementary-file metadata repair

During manual review of the second 200-record Workflow 04 validation set, Lens ID `023-156-696-663-49X` appeared with the title `Table 1.xlsx`, while its abstract clearly belonged to a rainbow-trout crowding-stress article. The parent article was independently identified as:

`Molecular and epigenetic responses to crowding stress in rainbow trout (Oncorhynchus mykiss) skeletal muscle`

DOI: `10.3389/fendo.2025.1571111`

The canonical title and DOI were repaired using the verified parent article metadata. The original Lens raw payload was retained unchanged, and the repair was recorded in `metadata_repair_audit.jsonl`.

## Current production repair state

The current persistent repair corpus was built on 29 August 2026 from the validated Workflow 01B production output, GitHub Actions run `33264142800`, artifact ID `9718474490`, followed by the human-verified metadata repair above.

| Item | Current state |
|---|---:|
| Total canonical records | 21,851 |
| Source Workflow 01B production run | 33264142800 |
| Source Workflow 01B artifact | 9718474490 |
| Current repair record count | 21,851 |
| Current repair SHA-256 | `39d2f8504186c40bc9503340347097fccbcc44e85afcee23de8245daadda51ce` |

The production Workflow 01B run recovered 1,977 abstracts from Europe PMC among 3,767 DOI-bearing records initially missing abstracts. Its ellipsis-repair pass replaced 816 target abstracts: 111 from Europe PMC and 705 from OpenAlex. Provider technical errors were retained in audit output rather than treated as record-level repair evidence. All three principal JSONL outputs were re-parsed at exactly 21,851 records before the production artefact was accepted.

The persistent repair-store workflow is `.github/workflows/persist_canonical_repair_store.yml`. It constructs archived repair states, promotes the latest validated corpus to `data/canonical/current/repair/records.jsonl`, writes the manifest and repair audit, and verifies the committed Git LFS pointers and manifest.

## Sources

- Lens search records: original bibliographic source retained in `lens.raw_payload`.
- Europe PMC REST API: https://europepmc.org/RestfulWebService
- OpenAlex Works API: https://docs.openalex.org/api-entities/works
- Workflow 01B production run: https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/33264142800
- Ellipsis repair script: `scripts/updater/repair_ellipsis_abstracts.py`
- Workflow 01B definition: `.github/workflows/patch_workflow01b_full_canonical.yml`
- Persistent repair-store workflow: `.github/workflows/persist_canonical_repair_store.yml`

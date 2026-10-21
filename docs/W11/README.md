# W11: full-text provenance and retrieval ledger

This branch was forked from `workflow01-final-architecture`. W11 is additive and read-only; it must not change the Workflow 00–10 pipeline, source canonical JSONL, prior deduplication decisions or existing archives.

## Scope of this stage

Reconcile the original OpenAlex full-text retrieval corpus (3,935 DOI attempts in 40 batches, historically archived to restricted Zenodo records) with a **pinned** canonical JSONL snapshot. Preserve one ledger row per canonical record and export unlinked and ambiguous records separately.

The ledger captures: canonical record ID and source JSONL line, canonical DOI, manifestation DOIs, title, year, OpenAlex identifiers, matched retrieval DOI and OpenAlex work, retrieval status and format, Zenodo deposit ID, Zenodo **record DOI only if verifiably returned by Zenodo**, archive filename, internal archive member filename, checksum, source URL, and GitHub retrieval run ID.

Linking rules: normalised DOI equality to the canonical DOI or any original manifestation DOI is acceptable identity evidence. An exact canonical plus matching OpenAlex work ID is stronger corroboration when available. Multiple retrieval matches must be reviewed; do not arbitrarily select one. An OpenAlex work-ID-only match is provisional, not automatically accepted. A canonical record without a DOI must remain in the ledger even without a link. Do not assign a full-text record from title alone unless independently verified title/author/year evidence is available.

A reported retrieval/upload does not prove an archived member has been re-downloaded and integrity checked. Maintain these as separate statuses. A restricted deposit numeric ID is not itself a Zenodo record DOI.

## Deliverables

- `canonical_fulltext_ledger.csv` for every canonical record, including unmatched records
- `review_queue.csv` for uncertain identity links or inaccessible files
- `unlinked_retrievals.csv` for historical retrievals not mapped to the selected canonical corpus
- `summary.json` with totals and corpus-source provenance

Use the standalone `w11-canonical-fulltext-ledger.yml` workflow, selecting the intended canonical Zenodo deposit. Diagnostic artefacts must remain private and temporary. Do not re-run OpenAlex harvesting as part of this stage.

## Following stage (not yet authorised here)

Once the ledger has been validated, identify unmatched canonical records, then attempt **additional full-text retrieval from OpenAlex**, preferring parsable GROBID/XML and using PDFs where XML is unavailable. Track every attempt separately, preserving original W11 provenance and not overwriting canonical coding.

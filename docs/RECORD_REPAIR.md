# Record repair

This note documents the record-repair stage used in Workflow 01B to improve abstract completeness while preserving the original Lens source payload.

## Process

Workflow 01B first restores the exact abstract supplied by Lens wherever one is present. Records without an abstract but with a DOI are then queried in Europe PMC using an exact DOI match. If Europe PMC returns an abstract for that DOI, the full abstract is written to `canonical.abstract`; the original Lens payload is left unchanged.

A second pass checks canonical abstracts containing either `...` or `…`, because these were found to be strong indicators of Lens truncation in this corpus. These records are again queried by exact DOI. Europe PMC is tried first and OpenAlex second. Any recovered abstract replaces the entire `canonical.abstract`, rather than being appended to the truncated text. OpenAlex abstracts are reconstructed from its abstract inverted index. All replacements retain provenance and repair history, and provider failures are recorded in the audit rather than altering the raw Lens data.

The repair code is implemented in `scripts/updater/repair_ellipsis_abstracts.py` and integrated into `.github/workflows/patch_workflow01b_full_canonical.yml`.

## Validation numbers

The validated integrated run was GitHub Actions run `33263112187` on 29 August 2026, using a corpus of 21,851 records.

| Stage | Result |
|---|---:|
| Total records | 21,851 |
| Existing Lens abstracts restored | 17,147 |
| Records missing an abstract but with DOI | 3,767 |
| Missing abstracts recovered from Europe PMC | 1,977 |
| Missing-abstract recovery rate among DOI targets | 52.5% |
| Records containing `...` or `…` before truncation repair | 948 |
| Ellipsis targets with DOI | 840 |
| Ellipsis targets without DOI | 108 |
| Full abstracts replacing ellipsis records from Europe PMC | 113 |
| Full abstracts replacing ellipsis records from OpenAlex | 709 |
| Total ellipsis abstracts replaced | 822 |
| DOI-bearing ellipsis targets not replaced | 18 |
| Provider technical errors during ellipsis repair | 5 |
| Records still containing an ellipsis after repair | 271 |
| Records still ending in an ellipsis after repair | 208 |

The remaining ellipses should not all be interpreted as known truncation. Of the replacement abstracts themselves, 145 contained an ellipsis and 102 ended in one, showing that ellipsis punctuation and/or source-side truncation also occurs in Europe PMC or OpenAlex records.

The final validation re-parsed `lens_records.jsonl`, `records_for_deduplication.jsonl`, and `abstract_enrichment_audit.jsonl`, each at exactly 21,851 records. The validated output artifact was `workflow01b-full-canonical-repaired-33263112187`, artifact ID `9717993946`, SHA256 `2b96f2e7dad7bd56153a8a98fc6358176ae418e34e57b9aac31c2a34d1080bd4`.

## Sources

- Lens search records: original bibliographic source retained in `lens.raw_payload`.
- Europe PMC REST API: https://europepmc.org/RestfulWebService
- OpenAlex Works API: https://docs.openalex.org/api-entities/works
- Validated Workflow 01B run: https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/33263112187
- Ellipsis repair script: `scripts/updater/repair_ellipsis_abstracts.py`
- Workflow definition: `.github/workflows/patch_workflow01b_full_canonical.yml`

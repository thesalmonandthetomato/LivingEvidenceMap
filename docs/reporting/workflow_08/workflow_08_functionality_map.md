# Workflow 08: Human adjudication and final canonical assembly

## Purpose

Workflow 08 resolves all records escalated for human review after Workflows 05–07, applies late Workflow 07 eligibility exclusions, and produces the definitive post-adjudication evidence base. Human decisions are retained as a separate, auditable overlay: archived automated outputs from Workflows 04–07 are not rewritten.

The definitive canonical JSONL contains **included records only**. Excluded records are retained separately as bibliographic metadata plus their final exclusion stage and reason.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
[32,292-work source canonical + validated W03-W07 states]
                         |
                         v
            [locked W08 review queue]
              811 issues / 797 records
                         |
             +-----------+-----------+
             |                       |
             v                       v
 [57 prior decisions]      [754 offline workbook decisions]
             |                       |
             +-----------+-----------+
                         |
                         v
       [validate complete decision ledger]
                         |
                         v
 [apply human decisions + W07 late exclusions]
                         |
                         v
        [temporary full disposition state]
                         |
             +-----------+-----------+
             |                       |
             v                       v
 [19,117 included JSONL]      [13,175 exclusions CSV]
             |                       |
             +-----------+-----------+
                         |
                         v
       [restricted Zenodo record 23020526]
                         |
                         v
                   [Workflow 09]
```

## Components

| Component | Function |
|---|---|
| `scripts/updater/workflow_08_build_review_queue.R` | Builds and locks the human-review queue from validated W05–W07 outputs. |
| `data/adjudication/workflow08/offline_adjudication_spec_2026-09-27.json` | Compact, checksum-bound representation of the completed offline review workbook. |
| `scripts/updater/workflow_08_expand_offline_decisions.R` | Expands the workbook specification, merges prior decisions and verifies exactly one decision for each locked issue. |
| `scripts/updater/workflow_08_finalize_canonical.R` | Applies W03–W08 state to the source canonical population and creates the temporary full disposition state. |
| `scripts/updater/workflow_08_partition_final_outputs.R` | Partitions the full disposition state into the included-only canonical JSONL and separate bibliographic exclusions file. |
| `scripts/updater/workflow_08_archive_to_zenodo.R` | Publishes the included canonical JSONL, exclusions file, adjudication ledger and manifest to restricted Zenodo. |
| `scripts/updater/workflow_08_write_report.R` | Produces the run-specific Workflow 08 methodological report. |
| `.github/workflows/workflow_08_finalize.yml` | Restores validated inputs, validates decisions, assembles and partitions final outputs, archives them and registers the final state. |

## Inputs and methodological rules

The authoritative source population was the **32,292-work** post-deduplication canonical JSONL with SHA-256 `1d3977537c1498a728c9fe04ff958874f4a7727ad344a02ba3ef00adb2f755c7`. Workflow 03 publication-status state, Workflow 04 final screening, Workflow 05 species coding, Workflow 06 geography coding and recoveries, Workflow 07 retained topic assignments and Workflow 07 late exclusions were restored from their validated states.

The locked W08 review queue contained **811 issues across 797 unique records** and had SHA-256 `a8f3203c7cfc252dc53d08cd850cbbb5c3c48b8270cebe8a87eedb1af41e5c16`. Human review comprised **57 earlier decisions** plus **754 decisions made in the offline workbook** `Workflow08_offline_human_review(1).xlsx`, whose SHA-256 was `00e396231ba72f1369e9c763b5e19945a3c3fc8b3fb1a6ccaac8d045d77fbf85`.

Species-NONE cases could be assigned an eligible named species, assigned unspecified species, or excluded. Geography cases could be assigned a country set or `NONE`; grounding-only cases could also accept the existing semantic assignment. Topic-disagreement cases could accept retained automated topics, replace the topic set, exclude the record, or use the reviewer-added `no_code` outcome, which retains the record with no topic assignment. Zero-topic eligibility cases could be retained uncoded or excluded.

The automated outputs of Workflows 04–07 remain immutable. Workflow 08 applies an adjudication overlay. The final analytical canonical JSONL contains only records with final inclusion status. Excluded records are not carried in the canonical JSONL and are instead preserved in a separate exclusions register.

## Processing modes or stages

### Locked intake

The W08 intake was rebuilt and validated in GitHub Actions run `36320650383`. It contained 169 species-NONE issues, 470 unresolved-geography issues, 51 geography evidence-grounding issues, 103 extreme topic-disagreement issues and 18 zero-topic eligibility issues. Records with multiple issues were represented once in the queue but required one decision per issue.

### Offline human adjudication

The offline review workbook separated geography, species, topic disagreement and zero-topic eligibility into distinct worksheets. The completed workbook was reduced to a compact specification of class defaults and record-specific overrides while preserving the workbook SHA-256 as provenance.

### Decision expansion and validation

The finalisation process reconstructed all 754 offline decisions from the compact specification and merged them with the 57 earlier decisions. Expansion failed unless the queue SHA-256 matched, each decision used an allowed outcome, review keys were unique, and all **811** queue issues were resolved exactly once.

The complete adjudication ledger has SHA-256 `db27db784d66dbcfecebbc9b86307db5ea2f680ec9f5e82fd844168fbff1c0e2`.

### Final assembly and partition

The W08 ledger was applied to the canonical evidence base together with the validated W03–W07 states. This produced a temporary all-record disposition state used only to verify final accounting.

Workflow 07 supplied 123 late automatic exclusion candidates. One of those records was already excluded by a W08 human decision, so **122 additional exclusions** are attributed to the W07-late stage in the mutually exclusive final exclusion accounting.

The 32,292-record source population partitions exactly into:

- **19,117 included records**, written to `living_evidence_map_canonical_final.jsonl`;
- **13,175 excluded records**, written to `workflow08_excluded_records.csv`.

Final exclusions are attributed to Workflow 03 = **9**, Workflow 04 = **12,876**, Workflow 07 late = **122**, and Workflow 08 = **168**. These sum exactly to 13,175.

The exclusions CSV contains only:

- `record_id`
- `title`
- `authors`
- `year`
- `journal`
- `volume`
- `issue`
- `pages`
- `doi`
- `exclusion_stage`
- `exclusion_reason`

There are **231 included records with no final topic code** and **53,288 final topic assignments**.

### Corrected archival

The initial W08 archive, Zenodo record **22998606** (DOI `10.5281/zenodo.22998606`), incorrectly treated the 32,292-record all-disposition intermediate as the definitive canonical JSONL. The W08 adjudication and inclusion/exclusion decisions in that intermediate were valid, but its output partition was not the agreed architecture.

GitHub Actions run `36329841121` therefore deterministically repartitioned that already validated post-adjudication state without rerunning human review, model coding or upstream workflows. The corrected partition was first published as restricted Zenodo record **22998934**, DOI **10.5281/zenodo.22998934**. A subsequent lossless reassembly preserved the full upstream Workflow 03–07 annotation/provenance objects in the final canonical records without changing the final inclusion/exclusion decisions or counts. That lossless canonical was published as restricted Zenodo record **23020526**, DOI **10.5281/zenodo.23020526**, which supersedes record 22998934.

## Provenance and documentation

The complete W08 decision ledger records stable review keys, record IDs, issue types, human decisions, final values, rationale, reviewer, resolution timestamp and queue provenance.

The corrected final-output checksums are:

- included canonical JSONL SHA-256: `8a42fe35f3c08bb4cd80824e494b9b579797a2c83286799b999aa9024ce9bb8c`;
- exclusions CSV SHA-256: `d1733b27212d02d1d6d43011fa3fb38cd99ef779882c9ad94b7a7d2860d7c244`;
- W08 adjudication ledger SHA-256: `db27db784d66dbcfecebbc9b86307db5ea2f680ec9f5e82fd844168fbff1c0e2`;
- canonical gzip archive SHA-256: `ffcce9aeae0dfdc914fe47b0e18b390fdddc6a6102e3ab0ff1d23bb5b331756d`.

The included canonical JSONL is 240,405,647 bytes. For Zenodo transfer it is stored as `living_evidence_map_canonical_final.jsonl.gz` (29,865,281 bytes); the uncompressed JSONL SHA-256 remains authoritative. The exclusions CSV is 3,454,999 bytes.

## Storage and archival model

### Permanent repository records

GitHub retains the compact offline-adjudication specification, prior human geography decisions, W08 implementation scripts, workflow definition, this report and the Zenodo pointer/registry. The reviewed workbook itself is represented by its cryptographic checksum and compact decision specification rather than committed as a binary repository file.

### Short-lived GitHub Actions artefacts

Correction run `36329841121` retains the included canonical JSONL, exclusions CSV, complete adjudication ledger, corrected manifest and Zenodo receipt as the Actions artefact `workflow08-corrected-36329841121` for operational verification.

### Durable external archive

The authoritative W08 output is archived as restricted Zenodo record **23020526**, DOI **10.5281/zenodo.23020526**. The deposit contains exactly:

1. `living_evidence_map_canonical_final.jsonl.gz` — gzip-compressed transfer form of the 19,117-record included canonical JSONL;
2. `workflow08_excluded_records.csv` — 13,175 excluded records with bibliographic metadata and exclusion reasons;
3. `workflow08_adjudication_ledger.jsonl` — all 811 W08 issue decisions; and
4. `workflow08_final_manifest.json` — counts, provenance and checksums.

Zenodo records **22998606** and **22998934** are superseded and must not be used as the authoritative W08 handoff.

## Downstream handoff

The included-only Workflow 08 canonical JSONL from Zenodo record 23020526 is the authoritative input to Workflow 09 documentation/output-summary work and subsequently the dashboard/output layer. Downstream workflows must decompress `living_evidence_map_canonical_final.jsonl.gz` and verify the uncompressed SHA-256 `8a42fe35f3c08bb4cd80824e494b9b579797a2c83286799b999aa9024ce9bb8c` before use.

The exclusions CSV is retained for audit, exclusion reporting and PRISMA-style flow reporting. It is not part of the analytical evidence-base input.

## Methods text for research reporting

> **Workflow 08: human adjudication and final assembly.** Records requiring manual resolution after species, geography and topic coding were collated into a checksum-locked review queue comprising 811 issues across 797 records. A single human reviewer adjudicated each issue using a structured offline workbook, with decisions recorded separately from the immutable automated outputs. Human decisions and late automatic exclusions were applied as overlays to the canonical evidence base. From a source population of 32,292 deduplicated records, 19,117 records were retained in the definitive canonical evidence-base JSONL and 13,175 excluded records were exported separately with bibliographic metadata and final exclusion reasons. The complete adjudication ledger and final outputs were checksum-validated and archived in a restricted Zenodo deposit (10.5281/zenodo.23020526).

## Reporting status

**COMPLETE and validated.** All 811 locked W08 issues were resolved exactly once. The 32,292-record source population was partitioned exactly into 19,117 included canonical records and 13,175 exclusions. The included canonical JSONL contains no excluded records. The exclusions file contains only bibliographic identification fields and exclusion stage/reason. The authoritative lossless archive is Zenodo record **23020526**, DOI **10.5281/zenodo.23020526**.

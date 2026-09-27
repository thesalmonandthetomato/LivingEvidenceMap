# Workflow 08: Human adjudication and final canonical assembly

## Purpose

Workflow 08 resolves all records escalated for human review after Workflows 05–07, applies late Workflow 07 eligibility exclusions, and assembles the definitive post-adjudication canonical JSONL. Human decisions are retained as a separate, auditable overlay: the archived automated outputs of Workflows 04–07 are not rewritten.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
[32,292-work canonical JSONL + validated W03-W07 states]
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
 [definitive canonical JSONL: all 32,292 works]
                         |
                         v
      [restricted Zenodo record 22998606]
                         |
                         v
                   [Workflow 09]
```

## Components

| Component | Function |
|---|---|
| `scripts/updater/workflow_08_build_review_queue.R` | Builds and validates the checksum-locked W08 intake from validated W05–W07 outputs. |
| `data/adjudication/workflow08/offline_adjudication_spec_2026-09-27.json` | Compact representation of the completed offline review workbook, bound to its SHA-256 and the locked queue SHA-256. |
| `scripts/updater/workflow_08_expand_offline_decisions.R` | Expands the offline specification, merges the 57 earlier decisions, validates allowed outcomes, and requires exactly one decision for every locked issue. |
| `scripts/updater/workflow_08_finalize_canonical.R` | Applies W03–W08 states to the authoritative canonical JSONL and validates final population and exclusion accounting. |
| `scripts/updater/workflow_08_archive_to_zenodo.R` | Publishes the minimal definitive W08 archive to restricted Zenodo. |
| `scripts/updater/workflow_08_write_report.R` | Produces the run-specific Workflow 08 methodological report. |
| `.github/workflows/workflow_08_finalize.yml` | Orchestrates restoration, validation, assembly, archival and repository registration. |

## Inputs and methodological rules

The authoritative canonical input was the 32,292-work post-W02 lean canonical JSONL with SHA-256 `1d3977537c1498a728c9fe04ff958874f4a7727ad344a02ba3ef00adb2f755c7`. Workflow 03 publication-status state, Workflow 04 final screening, Workflow 05 species coding, Workflow 06 geography coding and recoveries, Workflow 07 retained topic assignments and Workflow 07 late exclusions were restored from their validated states.

The locked W08 review queue contained **811 issues across 797 unique records** and had SHA-256 `a8f3203c7cfc252dc53d08cd850cbbb5c3c48b8270cebe8a87eedb1af41e5c16`. Human review comprised **57 earlier decisions** plus **754 decisions made in the offline workbook** `Workflow08_offline_human_review(1).xlsx`, whose SHA-256 was `00e396231ba72f1369e9c763b5e19945a3c3fc8b3fb1a6ccaac8d045d77fbf85`.

Species-NONE cases could be assigned an eligible named species, assigned unspecified species, or excluded. Geography cases could be assigned a country set or `NONE`; grounding-only cases could also accept the existing semantic assignment. Topic-disagreement cases could accept retained automated topics, replace the topic set, exclude the record, or use the reviewer-added `no_code` outcome, which retains the record with no topic assignment. Zero-topic eligibility cases could be retained uncoded or excluded.

The final JSONL preserves **all 32,292 canonical works**, including excluded works. Exclusion is represented explicitly in each record rather than by deleting the work from the canonical population.

## Processing modes or stages

### Locked intake and human review

The W08 intake was rebuilt and validated in GitHub Actions run `36320650383`. It contained 169 species-NONE issues, 470 unresolved-geography issues, 51 geography evidence-grounding issues, 103 extreme topic-disagreement issues and 18 zero-topic eligibility issues. Records with multiple issues were represented once in the queue but required one decision per issue.

The offline review workbook separated geography, species, topic disagreement and zero-topic eligibility into distinct worksheets. The completed workbook was reduced to a compact specification of class defaults and record-specific overrides, while preserving the workbook SHA-256 as provenance.

### Decision expansion and validation

The finalisation run reconstructed all 754 offline decisions from the compact specification and merged them with the 57 earlier decisions. Expansion failed unless the queue SHA-256 matched, each decision used an allowed outcome, review keys were unique, and all **811** queue issues were resolved exactly once. The resulting complete adjudication ledger had SHA-256 `db27db784d66dbcfecebbc9b86307db5ea2f680ec9f5e82fd844168fbff1c0e2`.

### Final canonical assembly

The assembler started from the authoritative 32,292-work canonical JSONL. Workflow 03 publication-status exclusions and Workflow 04 relevance decisions were applied first. Species, geography and topics were then populated for W04-retained records from W05–W07, with existing pre-baseline geography adjudications and W08 human decisions applied as overlays.

Workflow 07 supplied 123 late automatic exclusion candidates. One of those records was already excluded by a W08 human decision, so **122 additional exclusions** are attributed to the W07-late stage in the mutually exclusive final exclusion accounting. This avoids double-counting.

The final dataset contains **19,117 included** and **13,175 excluded** canonical works. Final exclusions are attributed to Workflow 03 = **9**, Workflow 04 = **12,876**, Workflow 07 late = **122**, and Workflow 08 = **168**; these sum exactly to 13,175. There are **231 included records with no final topic code** and **53,288 final topic assignments**.

### Archival and registration

The definitive canonical JSONL, complete W08 adjudication ledger and final manifest were uploaded to Zenodo by GitHub Actions run `36328298079`. The archival step succeeded and published restricted Zenodo record **22998606**, DOI **10.5281/zenodo.22998606**.

The run's final repository-registration step failed after publication because it attempted `git pull --rebase` after creating local documentation files, leaving a dirty working tree. No data-processing or Zenodo step was rerun. The already-published receipt was recovered from the run artefact and registered directly in the repository. The workflow definition was corrected so future registration pulls occur before report and registry files are generated.

## Provenance and documentation

The complete W08 decision ledger records the stable `review_key`, record ID, issue type, human decision, final value, rationale, reviewer, resolution timestamp, queue SHA-256 and, for offline decisions, workbook identity and SHA-256.

The final manifest records upstream file checksums, canonical population counts, mutually exclusive exclusion counts, numbers of human overrides, final topic totals and final output checksums. Key final checksums are:

- final canonical JSONL SHA-256: `42799b7bf73b311812ec0a48c4a2b0d9d8ea8340f161cb12158b145633bc09da`;
- W08 adjudication ledger SHA-256: `db27db784d66dbcfecebbc9b86307db5ea2f680ec9f5e82fd844168fbff1c0e2`;
- final manifest SHA-256 in the Zenodo deposit: `345ecde4a8b8158ffe38027fe2721e4a8fd02c7aa0af3b04d5a49902872f8a2f`.

The final canonical JSONL is 150,162,775 bytes. The run-specific completion marker also records the locked queue SHA, workbook SHA, 811 resolved issues and 797 unique review records.

## Storage and archival model

### Permanent repository records

GitHub retains the W08 implementation scripts and workflow definition; the compact offline-adjudication specification; earlier human geography decisions; this methodological report; and the Zenodo receipt/pointer and registry. The reviewed workbook itself is represented by its cryptographic checksum and compact decision specification rather than being committed as a binary repository file.

### Short-lived GitHub Actions artefacts

GitHub Actions run `36328298079` retains the assembled canonical JSONL, complete adjudication ledger, final manifest, completion marker and Zenodo receipt as the artefact `workflow08-final-36328298079` for operational verification. This is a cache/verification layer, not the durable archive.

### Durable external archive

The definitive W08 output is archived as restricted Zenodo record **22998606**, DOI **10.5281/zenodo.22998606**. The deposit contains exactly:

1. `living_evidence_map_canonical_final.jsonl`;
2. `workflow08_adjudication_ledger.jsonl`; and
3. `workflow08_final_manifest.json`.

Earlier W03–W07 states remain in their existing archives and are referenced by checksum rather than duplicated in the W08 deposit.

## Downstream handoff

The definitive Workflow 08 canonical JSONL is the authoritative input to Workflow 09 documentation/output-summary work and subsequently to the dashboard/output layer. Downstream workflows must verify SHA-256 `42799b7bf73b311812ec0a48c4a2b0d9d8ea8340f161cb12158b145633bc09da` against the W08 Zenodo pointer before use.

## Methods text for research reporting

> **Workflow 08: human adjudication and final assembly.** Records requiring manual resolution after species, geography and topic coding were collated into a checksum-locked review queue comprising 811 issues across 797 records. A single human reviewer adjudicated each issue using a structured offline workbook, with decisions recorded separately from the immutable automated outputs. Human decisions and late automatic exclusions were then applied as overlays to the canonical evidence base. The final dataset retained all 32,292 canonical records, including excluded records with explicit disposition metadata, and comprised 19,117 included and 13,175 excluded records. The complete adjudication ledger and definitive canonical JSONL were checksum-validated and archived in a restricted Zenodo deposit (10.5281/zenodo.22998606).

## Reporting status

**COMPLETE and validated.** All 811 locked W08 issues were resolved exactly once; all 32,292 canonical works were assembled; exclusion accounting reconciled exactly; final canonical and adjudication-ledger checksums were generated; and the minimal definitive archive was published to Zenodo. The data and archival stages were completed by GitHub Actions run `36328298079`; the successful receipt from that run was subsequently registered in GitHub without rerunning or republishing the dataset.

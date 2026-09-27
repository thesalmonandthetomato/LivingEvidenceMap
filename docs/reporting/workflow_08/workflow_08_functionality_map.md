# Workflow 08: Human adjudication and final canonical assembly

## Purpose

Workflow 08 resolves the human-review cases escalated from Workflows 05–07 and assembles the definitive post-adjudication canonical JSONL. This report is automatically replaced with the validated run-specific report when the finalisation workflow passes and the Zenodo archive is published.

## Functionality map

```text
[W03-W07 validated states]
        |
        v
[locked W08 queue]
        |
        v
[human adjudication]
        |
        v
[final canonical assembly]
        |
        v
[Zenodo archive]
        |
        v
[Workflow 09]
```

## Components

| Component | Function |
|---|---|
| `scripts/updater/workflow_08_expand_offline_decisions.R` | Validates and expands all human decisions against the locked W08 queue. |
| `scripts/updater/workflow_08_finalize_canonical.R` | Applies final decisions and upstream workflow states to the canonical JSONL. |
| `scripts/updater/workflow_08_archive_to_zenodo.R` | Publishes the minimal definitive W08 archive. |
| `.github/workflows/workflow_08_finalize.yml` | Orchestrates final validation, assembly, archival and reporting. |

## Inputs and methodological rules

The finalisation workflow uses only validated, checksum-bound upstream states and the locked W08 review queue. Human decisions are applied as an overlay; archived automated outputs are not rewritten.

## Processing modes or stages

### Human decision validation

All locked review issues must have exactly one final human decision before assembly can proceed.

### Final assembly

The final JSONL retains the complete canonical population and records terminal inclusion, species, geography and topic state.

## Provenance and documentation

Run-specific counts, checksums and archive identifiers are written automatically after a successful finalisation run.

## Storage and archival model

### Permanent repository records

Implementation scripts, the compact offline adjudication specification, this report and the Zenodo pointer/registry are retained in GitHub.

### Short-lived GitHub Actions artefacts

Finalisation outputs are retained temporarily as a GitHub Actions artefact for verification.

### Durable external archive

The definitive canonical JSONL, complete W08 adjudication ledger and checksum/provenance manifest are deposited to restricted Zenodo.

## Downstream handoff

The checksum-verified final canonical JSONL is the authoritative input to Workflow 09.

## Methods text for research reporting

> **Workflow 08: human adjudication and final assembly.** Automated cases requiring human resolution were reviewed against a locked queue and applied as a separate adjudication layer before definitive canonical assembly. Full run-specific methods text is generated after successful finalisation.

## Reporting status

Pending finalisation run and Zenodo publication.

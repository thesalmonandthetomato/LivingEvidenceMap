# Workflow 02: ad hoc actions and baseline-establishment log

## Purpose

This document records finite manual and corrective actions used while establishing the current Workflow 02 baseline. These actions are not part of the automated metadata-enrichment methodology described in `workflow_02_functionality_map.md`.

## One-off canonical correction review

Following the full automated enrichment run, seven residual metadata conflicts were explicitly reviewed outside the automated provider-matching process.

Outcomes:

- six records received approved canonical metadata corrections;
- one record, `work-7e50c9d8a89e9519` (DOI `10.1038/sj.leu.2400523`), was deliberately left without an abstract because the candidate provider abstract belonged to a different publication.

The six accepted corrections comprised:

- one record with a corrected canonical title plus a missing-abstract fill; and
- five records with approved missing-abstract fills.

These corrections were stored as a separate sparse patch and did not alter the automated provider matching rules.

## Correction validation and archive

The correction layer was validated against the automatically enriched 32,292-record canonical state. Exactly six records changed.

Lineage:

- automated enriched canonical SHA-256: `c88d36631512b5b30853fb3ae271db2e456b2a8b5b94925ccf0840e8f8d9156b`;
- correction patch records: 6;
- corrected canonical SHA-256: `4229257bca67c1ff1ebec4b3642ff9df4ac83d9eae99b584b15cbc9c49845902`.

The correction state was archived as restricted Zenodo record `22963024`, DOI `10.5281/zenodo.22963024`, from run `36159140553`.

## Reporting rule

For Workflow 09 and manuscript methods, describe only the automated DOI-based Europe PMC/Scopus enrichment process from `workflow_02_functionality_map.md`.

Use this file only to document the provenance of the current baseline and the finite manual corrections used to establish it.

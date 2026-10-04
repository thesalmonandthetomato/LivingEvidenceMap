# Workflow 09 compact reporting inputs

This directory is the **current, version-controlled reporting handoff for Workflow 09**.

Each accepted Workflow 00-08 stage owns one compact `wXX_summary.json` file. Workflow 01 and Workflow 08 additionally own compact source-provenance snapshots:

- `w01_source_summary.csv` and `w01_source_intersections.csv`: database contribution and exact intersections for the deduplicated corpus;
- `w08_source_summary.csv` and `w08_source_intersections.csv`: the same summaries for the definitive final included corpus.

`manifest.json` records the source run ID and SHA-256 for every current input file.

Workflow 09 should use these compact files for cross-workflow counts, flow reporting and source-overlap figures. It should restore the large Workflow 08 final canonical JSONL only for analyses that genuinely require record-level final data, including the RIS export and final species/geography/topic/publication-year figures.

Files in this directory are overwritten only by a newly accepted state for the owning workflow, so ordinary Git history provides a clear audit trail of reporting-input changes between living-map updates.

# Workflow 09 - reporting and publication package

Workflow 09 regenerates and publishes the final static reporting outputs from the latest authoritative Workflow 08 canonical evidence base.

The full methodological report is:

`docs/reporting/workflow_09/workflow_09_functionality_map.md`

Permanent publication outputs are stored under:

- `docs/reporting/workflow_09/figures/`
- `docs/reporting/workflow_09/figure_code/`
- `docs/reporting/workflow_09/manuscript/`
- `docs/reporting/workflow_09/data/`

The publication workflow is:

`.github/workflows/report_workflow09_figures.yml`

It restores the latest registered Workflow 08 canonical JSONL, verifies its checksum, exports the complete included library to RIS, regenerates all 15 final manuscript figures, renders Methods and Results to Markdown, HTML, Word and PDF, validates the package, and commits the generated outputs back to the `workflow01-final-architecture` branch.

Workflow 09 is reporting-only. It does not modify screening, species, geography or topic decisions. The Workflow 08 canonical JSONL remains authoritative.

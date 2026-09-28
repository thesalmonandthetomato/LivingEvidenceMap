# Workflow 09 publication outputs

The former planning note has been superseded by the implemented Workflow 09 publication package.

Authoritative documentation:

- `docs/reporting/workflow_09/workflow_09_functionality_map.md`
- `docs/reporting/workflow_09/FIGURE_INVENTORY.md`
- `docs/workflow09/README.md`

The production workflow publishes:

- the complete included canonical library as a lightweight RIS file plus checksum manifest;
- all 15 final manuscript figures in PNG and PDF;
- a snapshot of the R code used to generate every figure;
- Methods and Results R Markdown sources;
- rendered Methods and Results in Markdown, HTML, Word and PDF; and
- machine-readable flow counts.

All generated publication outputs are committed under `docs/reporting/workflow_09/` on `workflow01-final-architecture`. Counts and figures are regenerated from the latest registered authoritative Workflow 08 canonical dataset rather than hard-coded baseline values.

The validated paired CiteSource/database-contribution figure remains part of the final package as manuscript Figure 2. The rapidly-emerging-topics development figure is not retained in the final manuscript.

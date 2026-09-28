# Workflow 09: ad hoc development and review actions

This file records non-routine actions used to establish the final Workflow 09 reporting package. These actions are not part of the recurring production methodology.

## 28 September 2026: manuscript figure review and harmonisation

The Workflow 09 figure set was reviewed visually in the draft Results manuscript and several presentation-only inconsistencies were corrected without changing analytical data.

The final plotting changes included:

- removing internal titles, subtitles and below-plot explanatory text from Figures 7-14 so that explanatory wording appears only in manuscript captions;
- standardising Figures 3 and 4 to the same publication-year axis layout, aspect ratio, typography, horizontal reference-grid treatment and right-hand legend placement;
- standardising Figures 7-14 to the x-axis title **Number of records**, common typography, grid treatment and margins;
- changing theme-specific hierarchy plot height to scale with the number of terminal topic rows so small panels, especially Methods, are not vertically stretched;
- increasing Figure 7 right-side plotting space so the Production unique-record count is not clipped; and
- preserving the final umbrella-review figure without the development-stage title/subtitle/footer text.

These were display changes only. Counts and category assignments continued to derive from the authoritative Workflow 08 canonical state.

## 28 September 2026: full publication packaging

Workflow 09 was extended from a review-artifact workflow into a permanent repository publication step.

The final architecture:

1. restores the latest registered Workflow 08 final canonical state;
2. regenerates all manuscript figures from authoritative inputs;
3. exports the complete included canonical record set to RIS;
4. renders Methods and Results to Markdown, HTML and Word;
5. converts the Word outputs to PDF;
6. validates all expected files and checksums; and
7. commits the publication package to the `workflow01-final-architecture` branch.

The generated package is also retained as a GitHub Actions artefact for run-level inspection.

## RIS representation

The RIS export was deliberately designed as a portable bibliographic representation rather than a second canonical data format. It includes every included canonical record, bibliographic metadata, abstracts, final species labels, final country names and retained topic pathways. Nested workflow audit structures and manifestation-level provenance remain authoritative only in the canonical JSONL.

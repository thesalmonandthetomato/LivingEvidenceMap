# MVP isolated validation and controlled-testing readiness

Date: 2026-10-10

## Verified run
- Repository: thesalmonandthetomato/LivingEvidenceMap
- Branch: production-minimal
- Validated head SHA: 34821346d851b9b4be0f8ff2cc30147dd3ec2cab
- GitHub Actions run: https://github.com/thesalmonandthetomato/LivingEvidenceMap/actions/runs/38042946243
- Result: PASS (all job steps successful)
- Isolation: read-only checkout, absent service credentials, outbound networking disabled during processing; artefacts uploaded after restoration.

## Executed coverage
- W00 topic-agnostic scoping Boolean search validator.
- W01 source-identity integrity and checkpoint SHA-256 mismatch rejection; rejection of duplicated, missing and reordered manifestation keys.
- W01 local Shiny-handoff selector: single ready selection, ambiguous ready queue failure, record-specific resolved status, pending status preserved and repeated resolution idempotence. **Does not execute Shiny review itself.**
- W02 manifestation compaction, exact source references and immutable canonical IDs.
- Real linked W02 -> W03 -> W04 -> W05 processing with one synthetic human-retain decision provided at the W04 boundary.
- W03 publication-status exclusion and W04 incremental changed/new/unchanged record handling, malformed-ID rejection and repeated-input stability.
- W05 non-empty retained output and corrected post-close output checksum.
- W06 incremental geography queue/reuse: changed/new records requeued, unchanged coding reused.
- W07 incremental topic queue/reuse and changed-ontology fail-closed behaviour.
- W08 final included/excluded partition checks.
- Actual W08 -> W09 manifest consumption, stage counts and SHA-256 consistency.
- W09 synthetic W00/W01 stage summaries and input manifest assembly.

## Scope and limitations
These results validate components and **selected real producer-to-consumer sequences**, not the entire consecutive W00-W09 run. Some boundaries use independently generated synthetic outputs.

**Not yet validated:**
1. Full consecutive W00 -> W01 -> W02 -> W03 -> W04 -> W05 -> W06 -> W07 -> W08 -> W09 producer-to-consumer run.
2. True W01/W02/W04/W08 Shiny-compatible queue generation, assignment and all decision formats, applying decisions and downstream GitHub dispatch/resumption.
3. Complete Zenodo pointer/chunk reconstruction, all publication checksums and pipeline-wide record accounting from one baseline through its update.
4. Dynamic GitHub workflow expressions, secret permissions and external API functionality when the inert workflows are activated.
5. Shiny branch migration from workflow01-final-architecture to production-minimal, which must not be performed while the latter is inert.
6. Live W09 report generation and W10 deployment from the MVP.
7. Functional topic-agnostic application testing with a fresh review/search strategy.

## Configuration inventory
- There are 28 workflow definitions under .github/workflows-inert/ and 2 temporary active audit/test workflow definitions in .github/workflows/.
- Prior comprehensive audit: docs/validation/comprehensive-dependency-audit-2026-10-10.md. It examined 28 inactive workflows, 198 pipeline scripts and 63 Shiny files; no unresolved literal script/workflow targets were found.
- This static audit has limits around dynamic file paths, permissions and live integrations.

## Readiness assessment
**Suitable for planning a controlled sandbox live-functional test, but not yet certified for production activation or merging to main.** 
Recommended next: construct a truly contiguous fixture-based orchestrator and replay all four Shiny human review contracts; then activate the inert workflows in a separately controlled test environment with temporary credentials and no production writes. Only after passes should migration to main and Shiny branch repointing be considered.

## Change scope
This validation added only temporary validation code and modified the temporary isolated validation workflow on production-minimal. No production services were contacted, no protected branch changed and no original pipeline processing code was modified during this phase. W05 checksum correction occurred in the preceding phase and was reverified.

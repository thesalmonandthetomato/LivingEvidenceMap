# Planned Workflow 09 documentation outputs

Workflow 09 is planned as the documentation and output-summary stage of the LivingEvidenceMap pipeline.

## CiteSource database-contribution summary

Include the CiteSource database-contribution analysis in the Workflow 09 summary report.

For each bibliographic database, report:

- canonical records found in that database;
- canonical records unique to that database;
- canonical records also found in at least one other database;
- percentage of that database's canonical records that are unique to it.

The report should derive these values programmatically from the current CiteSource output (for example, `source_contribution_summary.csv`) rather than hard-coding counts.

### Current verified baseline

Successful reference run:

- GitHub Actions run: `36162730727`
- Job: `108162995274`
- Branch: `workflow01-final-architecture`
- CiteSource artifact: `citesource-database-contribution-36162730727`

| Database | Canonical records found | Unique to database | Also found elsewhere | Unique contribution |
|---|---:|---:|---:|---:|
| OpenAlex | 26,236 | 4,489 | 21,747 | 17.1% |
| Lens | 22,634 | 1,254 | 21,380 | 5.5% |
| Scopus | 19,767 | 3,156 | 16,611 | 16.0% |
| Web of Science | 15,100 | 583 | 14,517 | 3.9% |
| AGRICOLA | 2,727 | 28 | 2,699 | 1.0% |

Interpretation: the "unique to database" count is the marginal contribution of that source after cross-database deduplication: records present in that database and in no other database included in the comparison.

These values are a baseline only. Workflow 09 should always report values from the current run so that documentation remains synchronized with the canonical dataset.


## Paired CiteSource provenance figure

Preserve the validated paired UpSet-style provenance figure for Workflow 09 reporting.

Reference implementation:

- live plotting script: `scripts/reporting/plot_citesource_database_contribution.R`;
- documentation snapshot: `docs/reporting/workflow_09/citesource_database_contribution_figure.R`;
- validated reference run: `36234050130`;
- figure output: `database_contribution_upset.png` / `database_contribution_upset.pdf`.

Figure interpretation:

- black bars = all deduplicated canonical records;
- olive-green bars = Workflow 04 included records;
- left bars = total records contributed by each database;
- top paired bars = exact cross-database intersections at both stages;
- bottom dot matrix = databases defining each exact intersection;
- higher-order overlaps are shown to the left and single-database unique intersections are grouped at the far right, following the original CiteSource/UpSet ordering logic.

Validated baseline used for the paired figure:

| Database | Deduplicated records | Included records |
|---|---:|---:|
| OpenAlex | 26,236 | 17,278 |
| Lens | 22,634 | 15,777 |
| Scopus | 19,767 | 12,821 |
| Web of Science | 15,100 | 11,143 |
| AGRICOLA | 2,727 | 2,370 |

Current concise interpretation used with the figure:

> There’s a lot of overlap between databases, but no single one finds everything. Screening cuts the numbers down, while the overall overlap stays similar, and every database still adds some unique studies.

Workflow 09 should regenerate these counts from the current canonical provenance and inclusion outputs rather than hard-coding the baseline values above.

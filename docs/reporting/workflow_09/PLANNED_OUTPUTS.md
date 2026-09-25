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

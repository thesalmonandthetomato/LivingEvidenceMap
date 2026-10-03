# Workflow 01 identifier and title-assisted deduplication

## Status

This document records the validated Workflow 01 deduplication architecture developed on `w01-identifier-assist-test` in October 2026.

The production integration remains incremental and provenance-preserving. Existing core Workflow 01 scripts for union construction, candidate generation, expensive pair scoring, deterministic rescore, and cluster merging remain unchanged. The added layers reduce avoidable scoring and manual review before the existing clustering stage.

Historical old-old repair is deliberately **not** part of routine updates. It is deferred to a future controlled migration when additional EBSCO databases are incorporated.

## Architecture

The validated sequence is:

1. build the ordinary prior-plus-new W01 manifestation union;
2. generate ordinary W01 candidate pairs unchanged;
3. build a generic identifier registry from the live W01 union inputs;
4. construct guarded safe identifier edges;
5. form provisional safe identifier components and collapse the expensive scoring workload to one representative pair per external component relation;
6. run the existing expensive scorer unchanged on the reduced representative set;
7. run the existing deterministic rescorer unchanged;
8. inject safe identifier duplicate edges with explicit provenance;
9. resolve a narrow set of validated title-wrapper and generic-attachment review cases;
10. run the existing cluster merger unchanged;
11. send only remaining review pairs to adjudication;
12. persist the assisted incremental decision table in the human-review checkpoint so resumed runs reconstruct the same pre-adjudication state.

## Identifier namespaces

The identifier-assist layer recognises the following generic work-level identifiers when present in the W01 union:

- DOI
- PMID
- PMCID
- OpenAlex ID
- Microsoft Academic Graph ID
- CORE ID

Source-local Lens, Scopus, Web of Science, EBSCO, and similar record identifiers remain provenance identifiers and are not treated as generic cross-source work identifiers.

OpenAlex and MAG identifiers are treated as one independent identifier family when counting corroborating families.

## Identifier normalisation and provenance

The layer reads identifiers from the already prepared W01 source inputs and normalised metadata. It does not require a separate raw-source archive fetch.

Each retained identifier row records its manifestation key, source, normalised identifier namespace and value, and identifier provenance.

DOI is also retained from W01 normalised metadata because it is already deterministically normalised upstream.

## Corpus-derived never-auto-resolve registry

`config/workflow01_identifier_never_auto_resolve.csv` contains 46 identifiers identified empirically from the validation corpus:

- 43 DOI values
- 3 PMID values

These identifiers are excluded from automatic identifier resolution.

This registry is a corpus-derived safety control, not a universal blacklist. Its provenance and role must be preserved if the workflow is transferred or templated.

The guard was constructed from groups exhibiting one or more risk signals, including repeated use across multiple manifestations, repeated risky pairings, metadata conflict, or unsupported external canonical metadata.

## Safe identifier rule

A candidate identifier edge is eligible for automatic pre-resolution only when:

1. no identifier on the pair is in the empirical guard registry;
2. publication years are missing or differ by no more than one year; and
3. one of the following evidence rules is satisfied:

   - two or more independent identifier families and normalised-title Levenshtein similarity >= 0.65;
   - DOI only and title similarity >= 0.90;
   - PMID only or OpenAlex/MAG family only and title similarity >= 0.65.

For ordinary update operation, safe edges are emitted only when at least one manifestation is newly appended. This prevents routine incremental runs from silently rewriting historical old-old clusters.

## Validation of identifier rules

The frozen disagreement validation set contained 1,455 identifier-linked pairs that disagreed with the existing W01 clustering:

- 1,091 externally supported same-work pairs;
- 364 known unsafe/risky pairs.

The strict rule recovered 892 of the 1,091 supported same-work pairs.

Observed safety result:

**0 observed false fast-tracks among 364 known unsafe/risky cases.**

This is empirical validation on the frozen corpus. It is not a guarantee of perfect precision on future data.

A subsequent graph-level replay tested the same 364 risky pairs after full transitive clustering:

**0/364 known unsafe/risky pairs merged after transitive closure in the frozen validation corpus.**

The same replay also produced:

- 0 baseline cluster splits;
- 0 unsupported new merged clusters;
- 180 safe identifier edges crossing baseline clusters;
- baseline clusters: 47,153;
- assisted clusters: 47,019;
- cluster reduction: 134.

## Scoring reduction

On the frozen W01 benchmark:

- ordinary unique incremental candidate pairs: 503,245;
- representative pairs selected for expensive scoring: 272,169;
- avoided expensive scoring decisions: 231,076;
- scoring-decision reduction: 45.9172%.

All 272,169 retained representative pairs reproduced the frozen W01 classification and rule exactly when passed through the unchanged scorer and deterministic rescorer.

The earlier full W01 scoring plus rescore path took approximately 52 minutes 32 seconds. The reduced scorer plus rescore path took approximately 21 minutes 42 seconds in the benchmark. This is an observed reduction for the scoring/rescore stages, not a claim about total Workflow 01 runtime.

The optimised identifier builder completed the benchmark in approximately 5 minutes 16 seconds. Peak memory remained about 14.9 GB. A bounded chunked self-join was tested but did not materially reduce peak memory and was slightly slower, so the faster hashed non-chunked implementation is retained.

## Title-assisted review resolution

The title-assist layer acts only on pairs that remain classified as manual review after identifier injection and deterministic rescore. It does not modify non-review pairs.

Original title and provenance fields remain unchanged. Wrapper stripping is used only as derived deduplication evidence.

### Substantive wrapper rule

The validated wrapper vocabulary includes observed forms such as:

- `Peer Review #N of [article title]`
- `Additional file N: ... of [article title]`
- `Supplementary material from [article title]`
- `Supporting Information for [article title]`
- `Author response for [article title]`
- `Decision letter for [article title]`
- `Data/Dataset for/from [title]`

Automatic resolution is used only when stripping the wrapper leaves a substantive title and that derived title is an exact normalised match to the paired article title.

### Generic attachment rule

Validated explicit file-only forms include:

- `Supplementary file N.<extension>`
- `Data Sheet N.<extension>`
- `Table N.<extension>`
- `Image N.<extension>`

A generic attachment is automatically resolved as a duplicate only when all of the following hold:

- exactly one side is a recognised generic attachment;
- abstract hashes are identical;
- the existing W01 scorer reports first-author agreement;
- publication years are missing or differ by no more than one year;
- the DOI pair has a direct parent/supplement relationship of the form parent DOI and parent DOI + `.sN`.

Dataset objects such as `Data from:` records are not covered by this generic attachment rule simply because they share a related title. They may represent distinct research outputs and remain subject to separate evidence rules.

## Title-assist validation

The frozen assisted pre-adjudication queue contained 285 manual-review pairs.

The validated title rules resolved exactly 26:

- 2 wrapper-stripped exact-title pairs;
- 24 generic attachment pairs.

This reduced manual review from 285 to 259 pairs, a 9.1% reduction.

All 26 title-assisted edges were internal to components already connected by other validated evidence, so the title-assist layer reduced manual workload without changing the final cluster count in the frozen replay.

The combined identifier plus title-assist replay retained:

- 0 baseline cluster splits;
- 0 unsupported merged clusters;
- 0/364 known risky pairs merged after transitive closure.

## Retrospective validation limitation

The identifier thresholds and guard policy were developed and tested retrospectively using the same adjudicated corpus.

Results must therefore be described as observed validation performance on the frozen corpus, not as externally validated or guaranteed future precision.

Future materially different corpora should retain the guard mechanism and audit outputs and should be monitored for new risky identifier reuse patterns.

## Historical old-old repair

The strict identifier rule recovered 892 supported historical W01 misses in the validation exercise, but routine update operation intentionally emits automatic identifier edges only when at least one manifestation is appended.

Historical old-old clusters therefore remain unchanged during ordinary updates.

A one-off historical re-deduplication is deferred until additional EBSCO databases are incorporated. That future migration should distinguish provenance for:

- new-versus-existing deduplication;
- new-versus-new deduplication;
- historical-versus-historical repair.

It should run a dedicated graph-level safety audit before replacing the authoritative canonical state, preserve stable work IDs through aliases or explicit ID migration, and regenerate affected downstream W03-W10 outputs after the repaired canonical state is accepted.

## Production files

The minimum permanent implementation set is:

- `.github/workflows/workflow_01_production.yml`
- `config/workflow01_identifier_never_auto_resolve.csv`
- `scripts/updater/workflow_01_identifier_assist_build.R`
- `scripts/updater/workflow_01_identifier_prescore_collapse.R`
- `scripts/updater/workflow_01_identifier_inject_decisions.R`
- `scripts/updater/workflow_01_title_assist_resolve.R`
- this document.

Temporary benchmark workflows, exploratory identifier scripts, wrapper-audit scripts, and unrelated EBSCO/OpenAlex adapter changes are validation artefacts and are not required for production transfer.

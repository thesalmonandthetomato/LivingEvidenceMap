# Lens citation-gap prioritisation plan

## Purpose

This temporary analysis evaluates citation-connected literature that may have been missed by the production database search because it contains eligible salmon terminology but lacks the production farming terminology.

The analysis is deliberately separated from Workflow 04 screening. No OpenAI API screening is authorised by this plan. Citation candidates are prepared and ranked only. Workflow 04 must not be invoked unless explicitly authorised by Neal Haddaway.

## Discovery set

The Lens harvest starts from the authoritative W08 included corpus and its Lens manifestations.

For each included Lens manifestation, the workflow retrieves:

- the Lens seed record;
- records cited by that seed (references);
- records citing that seed (scholarly_citations).

The seed harvest is checkpointed in 34 batches of up to 500 included Lens manifestation IDs. Each completed batch is stored as a separate GitHub Actions artifact.

Citation neighbours are globally deduplicated before metadata retrieval.

## Candidate text filter

Citation neighbours are retained as citation-gap candidates when title, abstract or keywords contain at least one production salmon term:

- salmon
- salmonid*
- Salmo
- Oncorhynchus
- "rainbow trout"

and do not contain any production farming term:

- farm*
- cage*
- pens
- penned
- pen
- aquacultur*
- commercial*

The text filter is applied locally to retrieved Lens metadata. Already included Lens IDs are removed defensively after filtering.

## Information preservation

The preparation stage retains enough information to support later audit, analysis and potential ingestion into the Living Evidence Map.

### Manifestation-level edge table

citation_edges_manifestation_level.csv

One row per unique relation between:

- included canonical record ID;
- included Lens manifestation ID;
- candidate Lens ID;
- direction.

Directions are:

- candidate_cites_seed: the candidate cites an included record;
- seed_cites_candidate: an included record cites the candidate.

This table preserves the original manifestation-level evidence.

### Canonical-level edge table

citation_edges_canonical_level.csv

Duplicate seed manifestations are collapsed so that connectivity counts are based on unique included canonical records rather than the number of Lens manifestations attached to those records.

### Candidate ranking table

candidate_ranking.csv

For each unique candidate, retain:

- Lens ID;
- priority rank;
- number of unique included canonical records connected to the candidate;
- number of included records cited by the candidate;
- number of included records citing the candidate;
- forward-only, backward-only or both direction class;
- title;
- year/date where available;
- source/journal;
- DOI;
- authors;
- keywords;
- publication type;
- Lens references count;
- Lens scholarly citations count;
- metadata availability flag.

Primary ranking is descending n_unique_included_connections.

No cutoff is encoded.

### Ingestion-ready JSONL

candidate_ingestion_ready.jsonl

Each candidate is represented using a canonical-like structure containing:

- identity and Lens ID;
- Lens source/provenance;
- raw Lens payload retained where available;
- title;
- abstract;
- authors;
- year/date;
- source;
- DOI;
- keywords;
- publication type;
- citation-prioritisation metrics;
- the IDs of connected included canonical records;
- discovery method;
- explicit screening_status = "NOT_SCREENED";
- explicit workflow04_api_called = false.

This file is preparatory only. It must not be merged into the production canonical database without a later validated ingestion workflow.

## Prioritised screening analysis

If W04 screening is subsequently authorised, candidates should be screened in descending citation connectivity.

The analysis must track, for each connectivity stratum or screening block:

- candidates available;
- records screened;
- retained;
- excluded;
- unresolved;
- observed inclusion rate;
- cumulative screened records;
- cumulative retained records;
- marginal retained records per additional block screened;
- OpenAI API cost;
- forward/backward/both composition;
- publication-year distribution.

Connectivity strata may initially be summarised as:

- 20+
- 10–19
- 5–9
- 4
- 3
- 2
- 1

These are descriptive bins only and do not define exclusion thresholds.

## Stopping decision

No inclusion-rate cutoff or citation-connectivity cutoff is prespecified.

If screening is authorised, complete higher-connectivity strata first and observe the empirical relationship between connectivity and W04 inclusion.

For a large low-connectivity tail, draw a reproducible random sample rather than automatically excluding the tail. Use that sample to estimate:

- inclusion prevalence in the unscreened stratum;
- uncertainty around that prevalence;
- expected number of additional eligible records remaining;
- expected API cost of screening the remainder.

The eventual stopping decision is therefore an explicit resource-versus-recall judgement informed by observed yield, not an arbitrary connectivity threshold.

Any random sample must store the random seed and sampled candidate IDs so it is exactly reproducible.

## W04 safety constraint

The preparation workflow must not:

- reference OPENAI_API_KEY;
- call the OpenAI Responses API;
- invoke Workflow 04;
- assign screening decisions;
- infer exclusion from citation connectivity.

W04 screening may begin only after an explicit instruction from Neal Haddaway.

## Provenance and recovery

The citation harvest is checkpointed at multiple levels:

1. one artifact per 500-ID seed batch;
2. one global deduplicated neighbour index;
3. one artifact per metadata chunk;
4. final deduplicated candidate results;
5. citation-prioritisation bundle generated from the saved artifacts.

The saved seed records retain the original citation arrays, so seed-to-candidate edges can be reconstructed even if later aggregation fails.

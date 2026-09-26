# Workflow 06: substantive study geography coding

## Purpose

Workflow 06 assigns substantive study geography to the 19,407 records passed through Workflow 05.

The workflow uses a locked semantic geography prompt with GPT-5.6 Luna to identify every country in which the study itself was substantively conducted or which was itself an explicit substantive object of study. It preserves multiple countries and requires exact evidence spans from the supplied title or abstract.

Workflow 06 does not infer a single primary country, does not use author affiliation or other incidental geography, and does not alter species coding.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

    Workflow 05 accepted 19,407-record state
                   |
                   v
    title + abstract for each stable record_id
                   |
                   +-------------------------+
                   |                         |
                   v                         v
    deterministic geography QC        semantic Luna coding
    (previous lexical layer)          locked prompt + schema
                   |                         |
                   |                         v
                   |                  RESOLVED / NONE /
                   |                    UNRESOLVED
                   |                         |
                   +------------+------------+
                                |
                                v
                 compare semantic vs deterministic
                      for quality-control only
                                |
                                v
                  19,407-record geography layer
                                |
                  +-------------+-------------+
                  |                           |
             resolved/none               unresolved/QC
                  |                           |
                  v                           v
           downstream coding          later adjudication

## Components

| Component | Function |
|---|---|
| scripts/reporting/workflow05_geography_semantic_production.R | Production semantic-geography coder. The filename retains its historical prefix, but this code constitutes the semantic geography stage now designated Workflow 06. |
| config/workflow05_geography_semantic_prompt.txt | Locked production geography prompt used by the validated baseline. |
| scripts/reporting/workflow06_geography_semantic_merge.R | Merges and validates the 20 production shards and writes final geography/QC outputs. |
| .github/workflows/workflow_06_geography_merge_recovery.yml | Recovery controller that reused the 20 successful production shards after the original merge-only failure, avoiding repeat model calls. |
| scripts/updater/workflow_06_archive_state_to_zenodo.R | Validates and publishes the sparse accepted W06 geography state to restricted Zenodo storage. |
| scripts/updater/workflow_06_update_zenodo_registry.R | Registers the published Zenodo checkpoint and repository pointer. |
| docs/reporting/workflow_06/workflow_06_functionality_map.md | Methodological and reporting description of the production workflow. |
| docs/reporting/workflow_06/AD_HOC_ACTIONS.md | Separate record of recovery and baseline-establishment actions that are not part of the production method. |

## Inputs and methodological rules

### Authoritative input state

Workflow 06 covers the same 19,407 stable canonical record_id values accepted by Workflow 05.

The final W05 authoritative checkpoint is:

- Zenodo record: 22982751;
- DOI: 10.5281/zenodo.22982751;
- W05 species-layer SHA-256: 85f4003d3835535f6ab1c50691c79159640448642bb7b20974d58856dab44cdf.

The W06 archival workflow independently verifies identity concordance against the validated W05 handoff.

Geography coding itself uses title and abstract. Species codes are not used to infer geography.

### Model and locked prompt

The production model is GPT-5.6 Luna with low reasoning effort.

The locked production prompt SHA-256 is:

ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a

The prompt requires the model to use only the supplied title and abstract except for mapping an explicitly stated, unambiguous subnational place to its country.

### Geography definition

A country qualifies when the title or abstract explicitly establishes that substantive study activity occurred there, including:

- field sampling or observations;
- farm production, monitoring, husbandry or intervention;
- experiments or trials at a stated location;
- study animals, farms, facilities, rivers, coastal areas or ecosystems located there;
- biological, environmental, social or economic data collection;
- interviews, surveys or stakeholder research; or
- a geographically defined case study.

A country can also qualify when a geographically defined industry, policy system, market, aquaculture sector, production system or study material is itself an explicit substantive object of the study.

### Incidental geography exclusion

Countries are not assigned merely from affiliations, institutional names, suppliers or manufacturers, funding bodies, publisher/software information, background discussion, previous studies, incidental policies or industries elsewhere, species/product names that do not locate the study, or general statements about where aquaculture occurs.

### Multiple countries and evidence grounding

The workflow returns every substantively supported country. It does not force a single primary country.

For each returned country, the model must provide the shortest exact, verbatim, contiguous evidence span from the supplied title or abstract that establishes substantive geography.

Subnational places can be mapped to countries when the mapping is unambiguous. The evidence text itself remains verbatim and the mapping is recorded separately.

### Status vocabulary

Each record receives exactly one status:

- RESOLVED: at least one substantive study country can be identified confidently;
- NONE: no substantive country-level study geography is present in the title or abstract;
- UNRESOLVED: substantive geographical evidence exists but cannot be mapped or reconciled confidently.

Absence of geography is NONE, not UNRESOLVED.

## Processing modes or stages

### 1. Prepare the 19,407-record corpus

Records are ordered by stable record_sequence and sharded deterministically across 20 production jobs.

### 2. Run semantic geography coding

Each record is submitted independently to GPT-5.6 Luna with the locked prompt and strict structured-response schema.

The structured output contains geography status, zero or more locations, ISO 3166-1 alpha-3 code, country name, exact evidence span, mapping reason, and record-level geography reason.

### 3. Validate evidence grounding

Every returned evidence span is checked as an exact substring of the supplied title/abstract text.

The validated baseline contains:

- 239 records where evidence_all_grounded = FALSE;
- of these, 235 are classified as ungrounded_evidence discrepancies; and
- 4 are model-call failures, which are also necessarily not grounded.

### 4. Compare with deterministic geography for QC

The earlier deterministic geography fields are retained only as a quality-control comparator.

The semantic result is compared with the deterministic ISO3 set and classified as exact_agreement, deterministic_only_geography, luna_only_geography, different_country_set, ungrounded_evidence, or llm_failure.

The authoritative discrepancy classification is the row-level discrepancy_type field.

Baseline discrepancy counts are:

| Discrepancy type | n |
|---|---:|
| exact_agreement | 15,953 |
| deterministic_only_geography | 1,376 |
| luna_only_geography | 1,136 |
| different_country_set | 703 |
| ungrounded_evidence | 235 |
| llm_failure | 4 |

Thus 3,454 records are flagged as non-exact QC discrepancies.

A legacy boolean exact_agreement aggregate in the recovered merge summary yields 16,120. This differs from the authoritative discrepancy classification because discrepancy_type prioritises model failure and evidence-grounding failure before exact set equality. Reporting and archival QC counts therefore use discrepancy_type.

### 5. Merge and validate all shards

The final merge requires exactly 20 shard CSVs, exactly 20 shard JSONL files, exactly 19,407 merged records, unique record_id values, unique record_sequence values, record_sequence = 1:19407, and identical record identity between merged CSV and raw semantic JSONL.

### 6. Preserve unresolved and QC states

UNRESOLVED, ungrounded-evidence, model-failure and deterministic-discrepancy subsets are retained explicitly for later adjudication/QC. They are not silently coerced into a country assignment.

## Provenance and documentation

Workflow 06 records, where applicable:

- stable canonical record_id;
- record sequence;
- geography status;
- ISO3 country set;
- country-name set;
- exact evidence span(s);
- subnational-to-country mapping reason(s);
- record-level geography reason;
- evidence-grounding result;
- model failure/error state;
- deterministic geography comparison fields;
- discrepancy classification;
- model name and reasoning effort;
- locked prompt SHA-256;
- source production/recovery run;
- upstream W05 identity/checksum; and
- Zenodo publication and file checksums.

### Validated baseline

The validated W06 merged baseline is GitHub Actions run 36265092530, source commit:

9e9a2af88eb6dca76032df63119f9467f7a2a578

Baseline status counts:

- records: 19,407;
- RESOLVED: 7,770 (40.04%);
- NONE: 11,162 (57.52%);
- UNRESOLVED: 475 (2.45%);
- model-call failures: 4;
- records with evidence_all_grounded = FALSE: 239;
- non-exact QC discrepancies: 3,454.

The 475 unresolved records are preserved for later adjudication; they do not indicate an incomplete computational merge.

## Storage and archival model

### Permanent repository records

GitHub retains the production and merge R scripts, locked prompt, recovery workflow definition, Zenodo publication and registry scripts, this functionality/methods report, the separate ad hoc actions report, and lightweight Zenodo registry/pointer metadata.

The complete bibliographic corpus is not duplicated in Git.

### Short-lived GitHub Actions artefacts

Operational artefacts include the 20 production shards and the merged 19,407-record W06 output. These are execution, validation, recovery and handoff aids rather than the authoritative long-term source of truth.

The recovery merge deliberately reused the already completed production shards, avoiding repeat model/API calls.

### Durable external archive

The accepted W06 geography state is published as a restricted Zenodo dataset.

The durable archive contains:

- sparse workflow06_geography_layer.csv;
- raw semantic geography_semantic_final.jsonl;
- unresolved-record subset;
- ungrounded-evidence subset;
- model-failure subset;
- deterministic-QC discrepancy subset;
- discrepancy/status count tables;
- validated summary; and
- the exact locked geography prompt.

The repository registers the checkpoint in docs/workflow06/zenodo_registry.csv and docs/workflow06/zenodo/run-36265092530.json.

## Downstream handoff

Workflow 07 receives the same 19,407 stable record identities for topic coding.

The W06 geography layer is an additive sparse annotation layer keyed by record_id. Downstream assembly should join it by stable identity rather than treat the W06 CSV as a replacement canonical bibliographic dataset.

Records with UNRESOLVED, ungrounded evidence or model failure remain explicitly identifiable for later adjudication.

## Methods text for research reporting

> **Workflow 06: substantive study geography.** Substantive study geography was coded from publication titles and abstracts using a locked structured prompt with GPT-5.6 Luna. Countries were assigned only where the supplied text explicitly established substantive study activity or made a geographically defined system, industry, sector or study material an explicit object of analysis; incidental geography such as affiliations, suppliers and background references was excluded. Multiple countries were retained where supported. Each assigned country required an exact verbatim evidence span from the title or abstract, and subnational places were mapped to countries only when unambiguous. Records were classified as resolved, none or unresolved. Semantic geography assignments were compared with a deterministic geography layer for quality control, while unresolved cases, evidence-grounding failures and model failures were retained explicitly for later adjudication.

## Reporting status

Workflow 06 is considered computationally complete and validated when:

- the accepted 19,407-record identity set is verified;
- the locked prompt checksum is verified;
- all 20 production shards are present;
- the merged CSV and JSONL each contain exactly 19,407 unique matching record_id values;
- all records have an allowed geography status;
- evidence grounding and model failures are explicitly retained;
- unresolved records are retained rather than coerced;
- discrepancy classifications are reproducibly generated; and
- the accepted sparse geography layer is published and registered as a durable Zenodo checkpoint.

The computational conditions are satisfied by run 36265092530. The workflow becomes fully finalised when its Zenodo publication/registration run succeeds.

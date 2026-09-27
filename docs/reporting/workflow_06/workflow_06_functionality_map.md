# Workflow 06: substantive study geography coding

## Purpose

Workflow 06 assigns substantive study geography to records retained after Workflow 05. Its methodological purpose is to produce a reproducible automated geography layer from publication titles and abstracts while separating substantive study geography from incidental place mentions.

The semantic model output is the authoritative automated geography decision. A deterministic geography layer is retained only as an independent quality-control comparator. Deterministic/semantic disagreement does not, by itself, trigger human adjudication.

Records that remain unresolved or invalid after automatic validation and retry are handed to Workflow 08 for human adjudication. Human decisions are applied as a later layer and do not modify the Workflow 06 automated result.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
[Workflow 05 retained records]
           |
           v
[title + abstract]
           |
           +------------------------------+
           |                              |
           v                              v
[deterministic geography]          [semantic geography]
       QC only                    GPT-5.6 Luna + schema
           |                              |
           +--------------+---------------+
                          |
                          v
              [automatic validation]
                          |
             +------------+-------------+
             |                          |
             v                          v
      RESOLVED / NONE          UNRESOLVED / invalid
      accept Luna output        automatic retry/repair
             |                          |
             |                    if still invalid
             |                          |
             v                          v
      [W06 geography layer]   [W08 human adjudication]
             |
             v
      [downstream assembly]
```

## Components

| Component | Function |
|---|---|
| `scripts/reporting/workflow05_geography_semantic_production.R` | Production semantic-geography coder. The filename is historical; methodologically this is Workflow 06. |
| `config/workflow06_geography_semantic_prompt_v2.txt` | Current locked W06 prompt for future production/update runs. |
| `scripts/reporting/workflow06_geography_semantic_merge.R` | Merges and validates production shards. |
| `scripts/reporting/workflow06_recover_failures.R` | Targeted retry of structurally failed semantic calls. |
| `scripts/reporting/workflow06_revalidate_grounding.R` | Revalidates evidence grounding using the final relaxed grounding rules. |
| `.github/workflows/workflow_06_geography_merge_recovery.yml` | Recovery controller used to merge the completed baseline shards without repeating model calls. |
| `scripts/updater/workflow_06_archive_state_to_zenodo.R` | Validates and archives the accepted automated W06 state. |
| `scripts/updater/workflow_06_update_zenodo_registry.R` | Registers the authoritative W06 checkpoint. |
| `docs/reporting/workflow_06/AD_HOC_ACTIONS.md` | Records non-routine baseline recovery and validation actions. |
| `data/workflow08/geography_adjudication_decisions.jsonl` | Human geography decisions made during validation; these belong to W08 and are not part of W06. |

## Inputs and methodological rules

The authoritative input is the stable record set handed forward from Workflow 05. For the validated baseline this contains **19,407 records**.

Workflow 06 uses only the title and abstract for substantive geography coding. Species assignments are not used to infer geography.

The semantic model is **GPT-5.6 Luna** with low reasoning effort and a strict structured-response schema.

The validated historical baseline used prompt SHA-256:

`ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a`

The current locked prompt for future runs is `config/workflow06_geography_semantic_prompt_v2.txt`, SHA-256:

`2ef4a9f2099878ae825395f3f09b329f219bfd3a185d3704a8662c52bcff70ed`

Prompt v2 changes only the evidence-quotation instruction, explicitly requiring one continuous copied span without omitted words or spliced fragments. The substantive geography definition is unchanged.

A country is substantive geography when the title or abstract explicitly establishes study activity there or makes a geographically defined industry, policy system, market, production system, provenance or study material an explicit object of the study. Multiple countries are retained where supported.

Countries are not assigned merely from affiliations, suppliers, funders, publisher information, background discussion, previous studies, incidental comparisons, species names, strain names, language, nationality or external knowledge.

Subnational places may be mapped to countries only when the mapping is unambiguous.

The status vocabulary is:

- `RESOLVED`: one or more substantive countries can be assigned confidently;
- `NONE`: no substantive country-level geography is stated;
- `UNRESOLVED`: substantive geography is present but cannot be mapped or reconciled confidently.

The semantic result is authoritative for automated coding:

- deterministic country/countries + Luna `NONE` -> accept Luna `NONE`;
- deterministic `NONE` + Luna country/countries -> accept Luna country/countries;
- both return different country sets -> accept Luna by default;
- Luna `UNRESOLVED` -> flag for W08;
- semantic output still structurally invalid or ungrounded after automatic retry/validation -> flag for W08.

The deterministic layer therefore serves **QC and regression monitoring only**. It does not override Luna and disagreement alone is not a W08 escalation criterion.

## Processing modes or stages

### Semantic geography coding

Each record is submitted independently with title and abstract, the locked prompt and the structured-response schema. Returned fields include geography status, ISO 3166-1 alpha-3 country codes, country names, evidence spans, mapping reasons and a record-level geography reason.

### Evidence grounding

Evidence is validated against the supplied title and abstract.

The final validator accepts evidence when it is demonstrably recoverable from the source after harmless normalisation, including:

- whitespace and encoded line-break differences;
- non-breaking spaces and HTML entities;
- markup removal;
- typographic quote/dash and punctuation variation;
- model-inserted ellipses where the quoted fragments occur in the source in the same order; and
- compressed quotations where the normalised evidence words occur in the source in the same order.

These relaxations affect evidence-string validation only. They do not allow geography to be inferred from information absent from the title or abstract.

Prompt v2 nevertheless instructs the model to return a single exact contiguous quotation so that relaxed validation should be needed less often in future runs.

### Structural validation and retry

`NONE` must have no locations. `RESOLVED` must contain at least one valid location. Pseudo-country outputs such as global/non-country codes are invalid.

Model/API or structural failures are retried automatically using the locked prompt. If a valid result is obtained, it replaces the failed automated result. If the record remains invalid, it is flagged for W08.

The validated baseline contained four failed calls. Targeted recovery resolved all four as `NONE`, leaving **zero model failures**.

### Deterministic comparison

The semantic ISO3 set is compared with the deterministic ISO3 set for QC.

After technical failure recovery, **3,287 of 19,407 records (16.94%)** have different deterministic and semantic country sets. This statistic is diagnostic only.

The row-level QC classification additionally prioritises evidence-grounding and failure states, so its categories are not identical to a simple country-set disagreement count.

### Human-review escalation

Workflow 06 uses a minimum-escalation rule.

Records are sent to Workflow 08 only when the semantic result remains:

- `UNRESOLVED`;
- structurally invalid after retry;
- a model/API failure after retry; or
- ungrounded after the final automatic evidence validator.

Deterministic/semantic disagreement alone is not sufficient for escalation.

Human confirmation or correction is stored as a W08 layer and is applied after W06.

## Provenance and documentation

For each record or run, W06 retains as applicable:

- stable `record_id`;
- record sequence;
- semantic geography status;
- semantic ISO3 and country-name sets;
- evidence span(s);
- mapping reason(s);
- record-level geography reason;
- grounding-validation result;
- model failure/error state;
- deterministic geography fields;
- deterministic/semantic comparison fields;
- model and reasoning level;
- prompt version/checksum;
- source run and commit;
- upstream W05 checkpoint identity;
- recovery run identifiers where applicable; and
- archive/checksum metadata.

Validated baseline lineage:

- original semantic production run: `36249616391`;
- validated recovery/merge run: `36265092530`;
- failure-recovery runs: `36271055010` and `36271186232`;
- records: **19,407**;
- automated `RESOLVED`: **7,770**;
- automated `NONE`: **11,166**;
- automated `UNRESOLVED`: **471**;
- model failures after retry: **0**.

The archived corrected baseline records **235 original evidence-grounding flags**. Subsequent validation work refined the grounding rules without changing the semantic geography definition; unresolved human decisions arising from validation are stored under Workflow 08 rather than written back into W06.

## Storage and archival model

### Permanent repository records

GitHub retains:

- production, validation, recovery and merge R scripts;
- the locked prompt files;
- workflow definitions;
- methodological documentation;
- lightweight Zenodo registry/pointer metadata; and
- the separation between automated W06 outputs and W08 human decisions.

Bibliographic source data and large generated result sets are not duplicated unnecessarily in Git.

### Short-lived GitHub Actions artefacts

Operational artefacts include production shards, merged semantic results, validation subsets and recovery outputs. These are temporary execution, handoff and recovery artefacts rather than the authoritative long-term archive.

Costly completed model outputs are reused rather than regenerated when a merge or downstream validation step fails.

### Durable external archive

The corrected automated W06 baseline is archived as restricted Zenodo record **22983049**:

`10.5281/zenodo.22983049`

The archived W06 geography-layer SHA-256 is:

`7ac09bd94713cf433df092925fee601d37734837c2e31ddfb7f987d64aea5f91`

The repository pointer is:

`docs/workflow06/zenodo/run-36265092530.json`

and the registry is:

`docs/workflow06/zenodo_registry.csv`

This archive represents the automated W06 state after technical failure recovery. Human geography adjudications are deliberately excluded and stored in W08.

## Downstream handoff

Workflow 06 hands forward a sparse automated geography layer keyed by stable `record_id`.

For ordinary resolved records, downstream processing uses the Luna semantic result irrespective of deterministic agreement.

Records satisfying the minimum-escalation criteria are passed to Workflow 08 with their W06 provenance and issue flags. Workflow 08 records human confirmations/corrections as a separate layer. The final post-W08 JSONL is assembled later from the canonical record plus the accepted workflow layers; W06 does not rewrite the canonical bibliographic record.

Integrity is verified through stable record identity, cardinality checks, prompt/checkpoint checksums and the registered Zenodo checkpoint.

## Methods text for research reporting

> **Workflow 06: substantive study geography.** Substantive study geography was coded from publication titles and abstracts using GPT-5.6 Luna with a locked structured prompt. Countries were assigned only where the supplied text explicitly established substantive study activity or made a geographically defined system, industry, sector, provenance or study material an explicit object of analysis; incidental geography and geography requiring external knowledge were excluded. Multiple countries were retained where supported. Returned evidence was checked against the source text using a grounding validator tolerant of harmless formatting differences and recoverable compressed quotations. An independent deterministic geography layer was used only for quality control and regression monitoring; semantic model decisions remained authoritative when the two methods disagreed. Records that remained unresolved or invalid after automated validation and retry were flagged for subsequent human adjudication.

## Reporting status

Workflow 06 is **finalised and locked** when:

- the W05 input identity is verified;
- the semantic prompt and structured schema are versioned and checksum-locked;
- semantic geography is explicitly defined as the authoritative automated result;
- deterministic geography is explicitly restricted to QC/regression monitoring;
- automatic evidence validation and retry rules are defined;
- minimum W08 escalation criteria are defined;
- the 19,407-record baseline has been merged and validated without duplicate identities;
- technical model failures have been resolved or explicitly escalated;
- the automated baseline is durably archived with checksums; and
- human geography decisions are stored separately in Workflow 08.

These conditions are satisfied. The authoritative automated baseline is Zenodo record **22983049**, DOI **10.5281/zenodo.22983049**. Future W06 runs use prompt v2 and the final relaxed evidence-grounding validator. Human review decisions do not modify W06; they are applied as Workflow 08 adjudication layers.

# Workflow 05: deterministic species coding

## Purpose

Workflow 05 applies deterministic lexical species coding to the 19,407 records retained by Workflow 04.

Its methodological function is to search each retained record's title and abstract for the versioned species vocabulary and assign every matching eligible species coding.

Workflow 05 does not perform relevance screening, geography coding, topic coding, semantic inference, model adjudication, or focal/primary-species selection.

This document is intended to serve two purposes:

1. as a methodological guide to the repository implementation; and
2. as source text for reporting the workflow in a research paper.

## Functionality map

```text
Workflow 04 retained record set
          |
          v
restore exact 19,407 canonical records
          |
          v
read three-column deterministic vocabulary
     coding | entity | terms
          |
          v
normalise title + abstract text
          |
          v
deterministic lexical term matching
          |
          v
collect all named eligible species codes
          |
          +-------------------------------+
          |                               |
    named species found             no named species
          |                               |
suppress generic UNSPEC            retain generic match
if also present                    if present
          |                               |
          +---------------+---------------+
                          |
                          v
             record-level species layer
                          |
                          v
                     Workflow 06
                   geography coding
```

## Components

| Component | Function |
|---|---|
| `.github/workflows/workflow_05_species_coding.yml` | Production controller for restoring the validated Workflow 04 retained corpus, validating the three-column vocabulary, running deterministic species coding, validating outputs, and creating the handoff artefact. |
| `scripts/updater/workflow_05_species_coding.R` | Applies deterministic title/abstract species matching and writes record-level and long-form species outputs. |
| `R/species_detect.R` | Implements case-insensitive lexical matching, markup normalisation, whitespace/hyphen tolerance, scientific-name abbreviation handling, OCR-spacing tolerance, overlap handling, and validated plural behaviour. |
| `config/deterministic_concepts.csv` | Versioned runtime vocabulary with exactly `coding, entity, terms`. |
| `scripts/updater/workflow_05_archive_state_to_zenodo.R` | Validates and publishes the sparse accepted W05 species layer to restricted Zenodo storage. |
| `scripts/updater/workflow_05_update_zenodo_registry.R` | Registers the published Zenodo checkpoint and repository pointer. |
| `docs/reporting/workflow_05/workflow_05_functionality_map.md` | Methodological and reporting description of the production workflow. |
| `docs/reporting/workflow_05/AD_HOC_ACTIONS.md` | Separate record of non-routine baseline-establishment corrections; these are not part of the production methodology. |

## Inputs and methodological rules

### Authoritative input state

The authoritative input is the Workflow 04 retained set:

- records: **19,407**;
- stable identity: canonical `record_id`;
- authoritative Workflow 04 Zenodo record: **22973914**;
- Workflow 04 final screening-layer SHA-256:  
  `fcdfa0ed6c3ed37f0e355fdd13f5843aa4f6dc2224603e68ead00c7aeafa1f6b`.

Workflow 05 may use the verified Workflow 04 Actions handoff cache when available. Otherwise it restores the accepted state from the durable Workflow 04 checkpoint and rematerialises the same retained corpus.

### Runtime coding vocabulary

The runtime vocabulary is:

`config/deterministic_concepts.csv`

It contains **exactly three columns**:

| Column | Meaning |
|---|---|
| `coding` | Canonical value assigned to the record, e.g. `Atlantic salmon`. |
| `entity` | Coding dimension. For the current W05 this is `farmed species`. |
| `terms` | Semicolon-separated deterministic search terms and synonyms. |

The current baseline contains nine coding rows:

- Atlantic salmon;
- Rainbow trout;
- Chinook salmon;
- Coho salmon;
- Sockeye salmon;
- Chum salmon;
- Pink salmon;
- Masu salmon; and
- Unspecified species.

The vocabulary retains the multilingual terms, historical scientific synonyms and observed misspellings identified during development and uncertainty analysis.

The ambiguous term `spring salmon` is deliberately excluded. English `Salmons` and Spanish `salmones` are included under `Unspecified species`.

### Matching rules

The matcher searches **title and abstract only**.

Matching is deterministic and case-insensitive. It supports:

- ordinary capitalisation differences;
- repeated or irregular whitespace;
- whitespace/hyphen separator variants;
- HTML and JATS markup stripping;
- escaped markup such as `&lt;italic&gt;`;
- abbreviated scientific names such as `S. salar`;
- OCR-spaced scientific tokens such as `S almo salar` and `O ncorhynchus mykiss`;
- explicitly listed spelling variants and misspellings; and
- validated plural handling for English salmon/trout common names.

There is **no fuzzy matching** and no semantic inference. Misspellings are matched only when explicitly represented by the validated vocabulary or by the deterministic normalisation rules above.

### Record-level coding rule

Every named eligible species detected in the title or abstract is retained.

There is no ranking or focal-species selection.

If one or more named eligible species are detected, the generic `Unspecified species` coding is suppressed for that record.

Examples:

- `Salmo salar` + generic salmon terminology → `Atlantic salmon`;
- `Salmo salar` + `Oncorhynchus mykiss` → `Atlantic salmon; Rainbow trout`;
- generic salmon terminology only → `Unspecified species`;
- no configured species term → `NONE`.

## Processing modes or stages

### 1. Restore and validate Workflow 04 retained records

The workflow restores the exact 19,407 records retained by Workflow 04 and validates stable, unique `record_id` values.

### 2. Validate the deterministic vocabulary

The workflow requires the runtime vocabulary to contain exactly `coding, entity, terms`. The current W05 baseline requires `entity = farmed species` for all rows.

### 3. Normalise title and abstract text

Markup and formatting artefacts are normalised before matching, including HTML/JATS tags, escaped markup, irregular whitespace, hyphen variants and recognised OCR spacing artefacts.

### 4. Detect deterministic lexical matches

Every configured term is matched case-insensitively against title and abstract. Match-level provenance is retained.

### 5. Derive record-level species codes

All named eligible species detected for a record are retained. If a named eligible species is present, the generic `Unspecified species` code is suppressed. Records with no configured match are coded `NONE` by Workflow 05. `NONE` is an automated review state rather than a terminal species classification and is routed to Workflow 08 for human adjudication.

### 6. Route `NONE` records to Workflow 08

Records with `farmed_species_codes = NONE` are retained in the W05 automated layer but are automatically flagged for downstream human review in Workflow 08. W08 resolves these records to one or more eligible named species, `Unspecified species`, or a relevance/exclusion decision where appropriate. W05 itself does not perform semantic adjudication or rewrite these records.

For the validated baseline, **169 records** enter this W08 species-review queue.

### 7. Validate the final species layer

Before handoff, Workflow 05 requires:

- exactly 19,407 record-level outputs;
- unique stable `record_id` values;
- preserved record order;
- no missing species fields;
- no generic `UNSPEC_SALMON` code where a named eligible species is also present; and
- checksum identity between the runtime vocabulary and the vocabulary recorded in the run manifest.

### 8. Produce operational and durable outputs

The production workflow writes:

| Output | Purpose |
|---|---|
| `workflow05_species_coded.csv` | Operational record-level handoff including record identity, title/abstract and species fields. |
| `species_codes_long.csv` | Long-form record × species-code layer. |
| `species_matches.csv` | Match-level provenance including matched lexical evidence. |
| `species_record_counts.csv` | Aggregate coding counts. |
| `workflow05_manifest.json` | Counts, input/vocabulary checksums and matcher configuration. |

For durable archival, Workflow 05 stores a sparse layer rather than duplicating upstream bibliographic text.

## Provenance and documentation

Workflow 05 records, where applicable:

- stable canonical `record_id`;
- deterministic species code;
- canonical species label;
- matched lexical term;
- title/abstract source of each match;
- match position;
- input record count;
- coded and `NONE` record counts;
- total lexical-match count;
- runtime vocabulary SHA-256;
- output-layer checksums;
- source GitHub Actions run and commit;
- upstream Workflow 04 Zenodo identity and layer checksum; and
- Zenodo publication record and manifest checksum.

The validated production baseline is GitHub Actions run **36268840588**, commit:

`636428716c0a2e66431720dbffaf392e688b5b56`

Validated counts:

- records: **19,407**;
- records coded to at least one species category: **19,238**;
- records coded `NONE`: **169**;
- deterministic lexical matches: **80,831**.

The three-column baseline was compared record-by-record against the immediately preceding validated rebuilt W05 run `36266979542`:

- **19,407 / 19,407 record-level species codings identical**;
- **0 coding differences**.

The earlier validated species-only run `36245194052` differed from the rebuilt baseline for one intentional correction: removal of the ambiguous phrase `spring salmon` as a Chinook synonym. The baseline-establishment history is documented separately in `AD_HOC_ACTIONS.md`.

## Storage and archival model

### Permanent repository records

GitHub retains:

- the Workflow 05 controller;
- deterministic matcher implementation;
- the three-column runtime vocabulary;
- Zenodo publication and registry scripts;
- this functionality/methods report;
- the separate ad hoc actions report; and
- lightweight Zenodo registry/pointer metadata.

The complete bibliographic corpus is not duplicated in Git.

### Short-lived GitHub Actions artefacts

The validated W05 run exposes an operational handoff artefact containing the record-level coded output, long-form codes, lexical matches, counts and run manifest.

Actions artefacts are execution and handoff caches rather than the authoritative long-term source of truth.

### Durable external archive

The accepted sparse W05 state is archived as restricted Zenodo record **22982751**, DOI **10.5281/zenodo.22982751**.

The durable state contains:

- `workflow05_species_layer.csv` with stable `record_id` and species coding fields for all 19,407 records;
- `species_codes_long.csv`;
- `species_matches.csv`;
- `species_record_counts.csv`;
- `workflow05_manifest.json`; and
- the exact `deterministic_concepts.csv` runtime vocabulary.

The archived Workflow 05 species-layer SHA-256 is:

`85f4003d3835535f6ab1c50691c79159640448642bb7b20974d58856dab44cdf`

The repository pointer is:

`docs/workflow05/zenodo/run-36268840588.json`

and the registry is:

`docs/workflow05/zenodo_registry.csv`.

## Downstream handoff

Workflow 06 consumes the same 19,407 stable `record_id` records together with the accepted W05 automated species layer.

The registered Zenodo checkpoint is the authoritative W05 automated state. Workflow 06 should use a verified Actions handoff cache when available and otherwise restore from the registered durable checkpoint.

The **169 W05 `NONE` records are additionally routed to Workflow 08 for human species adjudication**. Their later human decisions are stored as a W08 layer and applied during final post-W08 assembly; they do not modify the archived W05 deterministic checkpoint.

Workflow 06 is responsible for geography coding. Geography is not part of Workflow 05.

## Methods text for research reporting

> **Workflow 05: deterministic species coding.** Records retained after relevance screening were coded for eligible farmed species using deterministic lexical matching of titles and abstracts against a versioned three-column vocabulary comprising canonical coding, entity and semicolon-separated search terms. The vocabulary included scientific and common names, historical synonyms, multilingual terms and spelling variants identified during validation. Matching was case-insensitive and normalised whitespace, hyphen variants, HTML/JATS markup and recognised OCR spacing artefacts. All named eligible species detected in a record were retained; no focal or primary species was inferred. A generic unspecified-salmon code was used only where generic salmon terminology was detected without a named eligible species. Records with no configured match were coded `NONE` and routed to downstream human adjudication rather than treated as a final species classification. Stable record identifiers and match-level lexical provenance were retained for reproducibility.

## Reporting status

Workflow 05 is considered complete and validated when:

- the validated Workflow 04 retained state is identity-checked;
- the runtime vocabulary has exactly `coding, entity, terms`;
- the deterministic matcher passes the regression suite;
- all 19,407 records are processed exactly once;
- record identity and ordering are preserved;
- all species codes and lexical match provenance are retained;
- records coded `NONE` are explicitly identified for Workflow 08 human review rather than treated as terminal species classifications;
- the output passes the validated count and schema invariants; and
- the accepted sparse layer is published and registered as a durable Zenodo checkpoint.

These conditions are satisfied for the current baseline.

**Workflow 05 status: complete, validated, durably archived and ready for Workflow 06 consumption.**

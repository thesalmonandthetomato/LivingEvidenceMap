# Workflow 05: deterministic species coding

## Purpose

Workflow 05 applies deterministic lexical species coding to the 19,407 records retained by Workflow 04.

It has one substantive function:

> search each retained record's title and abstract for the versioned species vocabulary and assign every matching eligible species coding.

Workflow 05 does not perform relevance screening, geography coding, topic coding, semantic inference, model adjudication, or focal/primary-species selection.

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

## Authoritative input

The authoritative input is the Workflow 04 retained set:

- records: **19,407**;
- stable identity: canonical `record_id`;
- authoritative Workflow 04 Zenodo record: **22973914**;
- Workflow 04 final screening-layer SHA-256:  
  `fcdfa0ed6c3ed37f0e355fdd13f5843aa4f6dc2224603e68ead00c7aeafa1f6b`.

Workflow 05 may use the verified Workflow 04 Actions handoff cache when available. Otherwise it restores the accepted state from the durable Workflow 04 checkpoint and rematerialises the same retained corpus.

## Coding vocabulary

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

## Matching rules

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

## Record-level coding rule

Every named eligible species detected in the title or abstract is retained.

There is no ranking or focal-species selection.

If one or more named eligible species are detected, the generic `Unspecified species` coding is suppressed for that record.

Examples:

- `Salmo salar` + generic salmon terminology → `Atlantic salmon`;
- `Salmo salar` + `Oncorhynchus mykiss` → `Atlantic salmon; Rainbow trout`;
- generic salmon terminology only → `Unspecified species`;
- no configured species term → `NONE`.

## Outputs

The production workflow writes:

| Output | Purpose |
|---|---|
| `workflow05_species_coded.csv` | Operational record-level handoff including record identity, title/abstract and species fields. |
| `species_codes_long.csv` | Long-form record × species-code layer. |
| `species_matches.csv` | Match-level provenance including the matched lexical evidence. |
| `species_record_counts.csv` | Aggregate coding counts. |
| `workflow05_manifest.json` | Counts, input/vocabulary checksums and matcher configuration. |

For durable archival, Workflow 05 stores a **sparse layer** rather than duplicating upstream bibliographic text. The Zenodo state contains:

- `workflow05_species_layer.csv` with stable `record_id` and species coding fields for all 19,407 records;
- `species_codes_long.csv`;
- `species_matches.csv`;
- `species_record_counts.csv`;
- `workflow05_manifest.json`; and
- the exact `deterministic_concepts.csv` vocabulary.

## Validated baseline

The authoritative production run is GitHub Actions run **36268840588**, commit:

`636428716c0a2e66431720dbffaf392e688b5b56`

Validated counts:

- records: **19,407**;
- records coded to at least one species category: **19,238**;
- records coded `NONE`: **169**;
- deterministic lexical matches: **80,831**.

The three-column baseline was compared record-by-record against the immediately preceding validated rebuilt W05 run `36266979542`.

Result:

- **19,407 / 19,407 record-level species codings identical**;
- **0 coding differences**.

The earlier validated species-only run `36245194052` differed from the rebuilt baseline for only one record. That change was intentional: the ambiguous phrase `spring salmon` had previously produced a Chinook salmon coding and was removed from the vocabulary.

## Provenance and invariants

Workflow 05 requires:

- exactly 19,407 input records;
- unique, stable `record_id` values;
- exactly the three vocabulary columns `coding, entity, terms`;
- no `spring salmon` term;
- no focal/primary/co-primary species fields or logic;
- no geography logic;
- no LLM/API calls;
- no generic `UNSPEC_SALMON` code on a record that also has a named eligible species;
- exactly one record-level output row per input `record_id`; and
- checksum identity between the runtime vocabulary and the vocabulary recorded in the run manifest.

## Storage and archival model

GitHub retains the workflow implementation, matcher, three-column vocabulary and methodological documentation.

The validated W05 output is exposed temporarily as a GitHub Actions artifact for operational handoff.

The accepted sparse W05 species layer is then published as a **restricted Zenodo dataset** and registered in:

- `docs/workflow05/zenodo_registry.csv`; and
- `docs/workflow05/zenodo/run-36268840588.json`.

The registered Zenodo checkpoint is the authoritative W05 state. Downstream workflows should use a verified Actions handoff cache when available and otherwise restore from the registered durable checkpoint.

## Downstream handoff

Workflow 06 consumes the same 19,407 stable `record_id` records together with the accepted W05 species layer.

Workflow 06 is responsible for geography coding. Geography is not part of Workflow 05.

## Methods text for research reporting

> **Workflow 05: deterministic species coding.** Records retained after relevance screening were coded for eligible farmed species using deterministic lexical matching of titles and abstracts against a versioned three-column vocabulary comprising canonical coding, entity and semicolon-separated search terms. The vocabulary included scientific and common names, historical synonyms, multilingual terms and spelling variants identified during validation. Matching was case-insensitive and normalised whitespace, hyphen variants, HTML/JATS markup and recognised OCR spacing artefacts. All named eligible species detected in a record were retained; no focal or primary species was inferred. A generic unspecified-salmon code was used only where generic salmon terminology was detected without a named eligible species. Records with no configured match were coded `NONE`. Stable record identifiers and match-level lexical provenance were retained for reproducibility.

## Status

Workflow 05 is methodologically complete when:

- the validated Workflow 04 retained state is identity-checked;
- the runtime vocabulary has exactly `coding, entity, terms`;
- the deterministic matcher passes the regression suite;
- all 19,407 records are processed exactly once;
- record identity and ordering are preserved;
- all species codes and lexical match provenance are retained;
- the output passes the validated count and schema invariants; and
- the accepted sparse layer is published and registered as a durable Zenodo checkpoint.

The computational baseline satisfies the coding and validation conditions. The authoritative archival pointer is `docs/workflow05/zenodo/run-36268840588.json`.

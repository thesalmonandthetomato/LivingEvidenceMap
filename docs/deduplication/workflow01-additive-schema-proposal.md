# Workflow 01 additive canonical-schema implementation record

Status: adopted for production W01. Manifestation enrichment and all planned work-level bibliographic fields have passed the full additive regression guard.

This proposal follows the field-preservation audit and quantitative coverage audit. The purpose is to enrich Workflow 01 without changing any existing deduplication or downstream identity semantics.

## Non-negotiable invariants

The following must remain unchanged when the enriched schema is produced:

- `identity.record_id`
- record count
- deduplication `cluster_id`
- deduplication `member_count`
- deduplication status/finality
- the set of manifestation identities defined by `source + source_record_id`
- existing canonical values for:
  - title
  - abstract
  - doi
  - authors
  - year
  - journal
  - volume
  - issue
  - pages
- existing `canonical.field_provenance` entries for those fields

New metadata must not participate in duplicate candidate generation, pair scoring, clustering, or canonical DOI selection.

The regression guard is implemented in:

`scripts/updater/workflow_01_validate_additive_schema.R`

## Adopted work-level additions

The adopted first implementation tranche adds the following bibliographic fields:

- `author_keywords`
- `publication_type`
- `publication_date`
- `language`
- `issn`
- `eissn`
- `issn_l`
- `pmid`

Each added canonical field must also gain an explicit provenance entry.

### Selection principles

**author_keywords**

Author keywords are multi-valued. They should not use the current single-value modal picker.

Proposed rule:

1. collect non-empty author-keyword values from eligible manifestations;
2. trim and collapse internal whitespace only;
3. deduplicate case-insensitively while preserving the first source spelling;
4. retain all distinct bibliographic keyword terms rather than selecting one source's list;
5. preserve source-level author-keyword lists in manifestations;
6. record contributing manifestation keys in author-keyword provenance.

OpenAlex generated keywords/topics/concepts are indexing metadata only and must never contribute to `canonical.author_keywords`.

Scopus STANDARD contributes no author keywords. Workflow 02 may later fill `canonical.author_keywords` only when this W01 value is empty and a retained Scopus EID is available.

**publication_type**

Preserve source-level values in manifestations. At work level, retain the distinct non-empty source-supplied values, deduplicated case-insensitively while preserving first-source spelling. Do not harmonise vocabularies yet because cross-source mappings may be lossy. Record the contributing manifestation keys as provenance. This field must not alter deduplication.

**publication_date**

Preserve source-level dates. At work level, normalise only recognisable ISO-like values and prefer the most specific available value (`YYYY-MM-DD` over `YYYY-MM` over `YYYY`). Among equally specific values, choose the modal value; ties are resolved deterministically. Record contributing manifestation keys as provenance. This must not alter the existing canonical `year`.

**language**

Preserve only explicit source-supplied language values. At work level, retain the distinct non-empty explicit values, deduplicated case-insensitively while preserving first-source spelling, and record contributing manifestation keys as provenance. Do not infer language from title or abstract.

**ISSN/eISSN/ISSN-L/PMID**

Treat as bibliographic identifiers. Preserve source values in manifestations. At work level, retain the distinct explicit identifiers after conservative normalisation: ISSN-family values are upper-cased and rendered as `NNNN-NNNX` when eight valid characters are present; PMID values are reduced to their numeric identifier. Deduplicate normalised values and record contributing manifestation keys as provenance. These identifiers must not feed back into W01 deduplication unless a future separately validated redesign explicitly approves that.

## Adopted manifestation additions

Every manifestation should retain mapped data that was previously discarded:

- explicit source-specific identifiers:
  - Lens ID
  - Scopus EID
  - Scopus ID
  - OpenAlex ID
  - AGRICOLA ID
  - WoS UID
  - PMID where supplied
- author keywords
- publication type
- publication date / first publication date
- ISSN / eISSN / ISSN-L where supplied
- language
- structured authors where available
- affiliations / institutions where supplied

Source-dependent metadata such as OpenAlex open-access/location data and WoS citation counts should remain manifestation/source-specific rather than being promoted to a single canonical truth.

## Structured authors

The current canonical display-author list should remain unchanged for downstream compatibility.

Manifestations should additionally preserve the source's structured author objects where available, including:

- ORCID
- OpenAlex author ID
- AGRICOLA author ID
- WoS ResearcherID
- WoS standard name
- author position
- corresponding-author flag
- indication that Scopus STANDARD supplies first-author-only metadata

This is additive. It must not replace the existing manifestation `authors` field until downstream compatibility has been separately reviewed.

## Completed implementation sequence

1. Added and self-tested the additive regression guard.
2. Extended manifestation preservation additively.
3. Passed the full baseline regression.
4. Added `author_keywords`, publication type, publication date, language and bibliographic identifiers one class at a time.
5. Passed the full regression after every class.
6. Audited principal downstream readers in W02 and W08; additive canonical fields are preserved because these stages mutate existing records rather than reconstructing the canonical object.
7. Adopted the enriched builder as the production W01 canonical output.

The final identifier regression passed for all 32,292 canonical records and 90,137 manifestations with all 32 approved data-quality repairs applied and no existing invariant differences.

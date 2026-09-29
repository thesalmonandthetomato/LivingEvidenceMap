# Workflow 01 additive canonical-schema proposal

Status: implementation in progress. Manifestation enrichment has passed the additive regression guard; work-level fields are being added one class at a time.

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

## Proposed work-level additions

The first implementation tranche should add only fields that are clearly bibliographic and already mapped by multiple sources:

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

Preserve source-level values in manifestations. Work-level canonicalisation should be deterministic and must not alter deduplication. Before implementation, inspect cross-source value vocabularies and define a conservative mapping or retain a source-derived list if harmonisation would be lossy.

**publication_date**

Preserve source-level dates. Work-level selection should prefer a complete ISO date over year-only values and should not alter the existing canonical `year`.

**language**

Preserve where supplied. Do not infer language from title or abstract.

**ISSN/eISSN/ISSN-L/PMID**

Treat as bibliographic identifiers. Preserve source values in manifestations. At work level, retain the deterministically supported identifier(s), with provenance. These identifiers must not feed back into W01 deduplication unless a future separately validated redesign explicitly approves that.

## Proposed manifestation additions

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

## Implementation order

1. Add the regression gate and prove that it passes when baseline is compared with itself.
2. Extend manifestation preservation first.
3. Run the regression gate against baseline.
4. Add work-level bibliographic fields one class at a time.
5. Run the regression gate after every class.
6. Audit downstream parsers against the enriched sample.
7. Only after those checks, adopt the enriched W01 schema as the production canonical output.

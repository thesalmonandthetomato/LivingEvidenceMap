# Workflow 01 field-preservation audit

Status: initial audit, no schema changes applied.

Branch: `workflow01-final-architecture`

## Purpose

Audit the metadata received by Workflow 01 from each of the five database source representations against the fields retained by `scripts/updater/workflow_01_build_canonical_jsonl.R`.

The aim is to identify information that is currently lost during canonical materialisation, classify each field by its appropriate role, and define a lossless-enough canonical/manifestation schema before Workflow 02 enrichment is extended.

## Current Workflow 01 canonical output

The current builder writes these work-level fields under `canonical`:

- `title`
- `abstract`
- `doi`
- `authors`
- `year`
- `journal`
- `volume`
- `issue`
- `pages`
- `field_provenance` for those fields

Each retained source manifestation currently contains:

- `source`
- `source_record_id`
- `title`
- `abstract`
- `doi`
- `authors`
- `year`
- `journal`
- `volume`
- `issue`
- `pages`
- abstract-stripping audit fields

Anything else exposed by the source adapter is currently omitted from the final W01 canonical JSONL.

## Source adapter inventory

### Lens

Workflow 00 exposes the following directly in its canonical-shaped source record:

- `record_id`
- `lens_id`
- `title`
- `abstract`
- `authors`
- `year`
- `source`
- `doi`
- `keywords`
- `publication_type`

The full Lens API record is also retained upstream as `lens.raw_payload`.

Currently lost by W01 materialisation:

- `lens_id` as an explicit source-specific identifier
- `keywords`
- `publication_type`
- any additional Lens-only metadata available only in `raw_payload`

The raw payload should remain an upstream source artefact rather than being duplicated wholesale into every final canonical record, but mapped bibliographic fields should not be discarded.

### Scopus

The Scopus STANDARD adapter exposes:

Identity:
- `scopus_eid`
- `scopus_id`
- `doi`

Mapped fields:
- `title`
- `abstract` = unavailable in STANDARD
- `authors` = first author only in STANDARD
- `first_author`
- `year`
- `publication_date`
- `source`
- `doi`
- `keywords` = unavailable in STANDARD
- `publication_type`
- `affiliations`

The full STANDARD search response is retained upstream as `scopus.raw_payload`.

Currently lost by W01 materialisation:

- explicit `scopus_eid`
- explicit `scopus_id`
- `publication_date`
- `first_author` role information
- `publication_type`
- `affiliations`

Scopus author keywords are not available from the STANDARD search response. The tested Abstract Retrieval API can later fill missing canonical keywords in Workflow 02 for records with a retained Scopus EID.

### OpenAlex

The OpenAlex adapter exposes:

Identity:
- `openalex_id`
- `doi`

Mapped fields:
- `title`
- `abstract`
- `authors`, including OpenAlex author ID, ORCID, author position and corresponding-author flag
- `year`
- `publication_date`
- `source`
- `doi`
- `keywords`
- `publication_type`
- `institutions`
- `open_access`
- `primary_location`

`primary_location` includes:
- source ID
- source display name
- ISSN-L
- ISSN
- landing-page URL
- PDF URL
- OA flag
- version

The full OpenAlex work is retained upstream as `openalex.raw_payload`.

Currently lost or flattened by W01 materialisation:

- `openalex_id`
- author IDs
- ORCIDs
- author positions
- corresponding-author flags
- `publication_date`
- `keywords`
- `publication_type`
- `institutions`
- `open_access`
- `primary_location`
- source identifier
- ISSN-L / ISSN
- location URLs/version

The current `author_strings()` transformation also reduces structured OpenAlex authors to display-name strings.

### AGRICOLA

The AGRICOLA-via-Europe-PMC adapter exposes:

Identity:
- `agricola_id`
- Europe PMC source code
- `doi`

Mapped fields:
- `title`
- `abstract`
- structured `authors`, including author ID
- `year`
- `source`
- `doi`
- `keywords`
- `publication_type`
- `author_string`
- `affiliation`
- `language`
- `first_publication_date`

The full Europe PMC AGRICOLA record is retained upstream as `agricola.raw_payload`.

Currently lost or flattened by W01 materialisation:

- `agricola_id`
- Europe PMC source identity
- author IDs
- `keywords`
- `publication_type`
- `author_string`
- `affiliation`
- `language`
- `first_publication_date`

### Web of Science

The WoS Starter adapter exposes:

Identity:
- `wos_uid`
- `doi`

Mapped fields:
- `title`
- `abstract` = unavailable from Starter
- structured `authors`, including WoS standard name and ResearcherID
- `year`
- `source`
- `doi`
- author `keywords`
- `publication_type`
- `volume`
- `issue`
- `pages`
- `issn`
- `eissn`
- `pmid`
- `source_types`
- `times_cited_wos`

The full WoS Starter response is retained upstream as `wos.raw_payload`.

Currently lost or flattened by W01 materialisation:

- `wos_uid`
- WoS standard author name
- ResearcherID
- `keywords`
- `publication_type`
- `issn`
- `eissn`
- `pmid`
- `source_types`
- `times_cited_wos`

## Initial field classification

This classification is provisional and should be agreed before changing the builder.

| Field | Proposed role | Rationale |
|---|---|---|
| title | canonical + manifestation | Core work metadata |
| abstract | canonical + manifestation | Core work metadata; manifestation differences matter |
| doi | canonical + manifestation | Core identifier; source-specific disagreements matter |
| authors | canonical + manifestation | Core work metadata |
| year | canonical + manifestation | Core work metadata |
| publication_date | canonical + manifestation | Useful bibliographic date finer than year |
| journal/source title | canonical + manifestation | Core publication metadata |
| volume | canonical + manifestation | Core publication metadata |
| issue | canonical + manifestation | Core publication metadata |
| pages/article number | canonical + manifestation | Core publication metadata |
| keywords | canonical + manifestation | Bibliographic keywords; required for downstream search |
| publication_type | canonical + manifestation | Work-level bibliographic characteristic |
| ISSN | canonical + manifestation where supplied | Journal identifier |
| eISSN | canonical + manifestation where supplied | Journal identifier |
| ISSN-L | canonical + manifestation where supplied | Journal identifier |
| PMID | canonical + manifestation where supplied | Stable external identifier |
| language | canonical + manifestation where supplied | Work-level bibliographic characteristic |
| source-specific record IDs | manifestation identity | Required for provenance and source-specific repair |
| ORCID / author IDs / ResearcherID | manifestation structured-author metadata | Preserve identity without forcing cross-source reconciliation in W01 |
| author position / corresponding flag | manifestation structured-author metadata | Source-specific structured authorship |
| affiliations / institutions | manifestation metadata | Useful metadata but source representations differ |
| open-access metadata | manifestation/source-specific metadata | Source-dependent state |
| primary location / landing URL / PDF URL / version | manifestation/source-specific metadata | OpenAlex-specific location information |
| citation counts | source-specific provenance | Time-varying and database-dependent; must not become a single canonical truth |
| source_types | manifestation/source-specific metadata | Database classification |
| raw API payloads | upstream archive only | Preserve upstream, but avoid duplicating very large raw records into canonical JSONL |

## Important structural finding: author information is being flattened

The W01 builder calls `author_strings()` for every manifestation. This converts structured author objects into display strings.

Consequently, information already present upstream can be lost, including:

- ORCID
- OpenAlex author ID
- AGRICOLA author ID
- WoS ResearcherID
- WoS standard author name
- author position
- corresponding-author flag
- Scopus indication that only the first author was available from STANDARD

This is distinct from the keyword omission and needs an explicit design decision.

A safer design is likely to retain:

- a canonical display-author list for current downstream compatibility; and
- structured authors within manifestations, preserving source-specific identifiers and roles.

## Important structural finding: source identities are over-compressed

The current final manifestation retains only `source` and a generic `source_record_id`.

Although that generic ID encodes source identity in many cases, the adapter-specific identifiers are not retained as named fields. This makes downstream source-specific enrichment less direct than necessary.

The manifestation schema should retain an explicit `identifiers` object, for example:

```json
{
  "identifiers": {
    "doi": "...",
    "lens_id": "...",
    "scopus_eid": "...",
    "scopus_id": "...",
    "openalex_id": "...",
    "agricola_id": "...",
    "wos_uid": "...",
    "pmid": "..."
  }
}
```

Only applicable identifiers would be populated for any one manifestation.

## Important structural finding: adapter declarations and builder behaviour disagree

Several adapters explicitly declare `keywords` and `publication_type` as canonical bibliographic fields that are safely mappable. The W01 builder nevertheless ignores them.

Examples:

- Scopus declares `publication_type` safely mappable.
- OpenAlex declares `keywords` and `publication_type` safely mappable.
- AGRICOLA declares `keywords` and `publication_type` safely mappable.
- WoS declares `keywords`, `publication_type`, `volume`, `issue` and `pages` safely mappable.
- Lens already exposes `keywords` and `publication_type` in its source record.

The loss therefore occurs at canonical materialisation, not at source acquisition for those fields.

## Proposed audit rule before implementation

Every adapter field should be assigned one of four explicit dispositions:

1. **canonical + manifestation**: selected deterministically at work level and also retained per source manifestation;
2. **manifestation only**: preserved without forcing a single work-level value;
3. **source-specific provenance only**: retained where useful but never treated as canonical truth;
4. **upstream archive only**: intentionally omitted from the final canonical JSONL because the authoritative raw payload is already archived and the field is not needed downstream.

No mapped field should be silently dropped.

## Next audit steps

1. Inspect the actual source records/coverage outputs to quantify field availability for each database.
2. Check whether Lens raw records expose additional high-value bibliographic fields that are not currently mapped by Workflow 00.
3. Define exact canonical selection rules for multi-valued fields, especially keywords, publication type, identifiers and publication date.
4. Define structured manifestation schema for authors and source-specific identifiers.
5. Check every downstream workflow for assumptions about the current `living-evidence-map-canonical-v1` schema before changing it.
6. Only after those checks, revise the W01 canonical schema and add regression tests demonstrating that mapped fields are no longer silently lost.

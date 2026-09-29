# Workflow 01 production canonical schema

Status: adopted production schema on `workflow01-final-architecture`.

The production builder is:

`scripts/updater/workflow_01_build_canonical_jsonl.R`

The schema remains identified as `living-evidence-map-canonical-v1`. The enrichment is additive: existing record identity, deduplication semantics and pre-existing canonical fields remain unchanged.

## Canonical work object

The `canonical` object contains the established fields:

- `title`
- `abstract`
- `doi`
- `authors`
- `year`
- `journal`
- `volume`
- `issue`
- `pages`

and the adopted additive bibliographic fields:

- `author_keywords`
- `publication_type`
- `publication_date`
- `language`
- `issn`
- `eissn`
- `issn_l`
- `pmid`

`canonical.field_provenance` contains provenance for both the established and additive fields.

## Manifestations

Every source manifestation retains its established identity and bibliographic fields plus a `manifestation_metadata` object. That object may contain:

- native source identifiers;
- author keywords;
- non-author indexing terms where appropriate;
- publication type and publication date;
- language;
- ISSN-family identifiers and PMID;
- structured authors;
- affiliations or institutions;
- source-specific metadata.

Only metadata actually supplied or mapped from the source is populated. Raw source payloads remain authoritative upstream in Workflow 00 archives and are not duplicated wholesale into canonical JSONL.

OpenAlex generated keywords/topics/concepts are non-author indexing metadata and must never populate `author_keywords`.

## Selection rules

- Author keywords: union distinct genuine source author/article keywords; whitespace-normalised and case-insensitively deduplicated.
- Publication type: union distinct source-supplied values; no cross-source vocabulary harmonisation.
- Publication date: prefer the most specific ISO-like value, then modal selection among equally specific values.
- Language: explicit source values only; no inference from title or abstract.
- ISSN/eISSN/ISSN-L: conservative normalisation to `NNNN-NNNX` when eight valid characters are supplied.
- PMID: numeric identifier only.

None of these additive fields participates in W01 duplicate candidate generation, pair scoring, clustering or canonical DOI selection.

## Validated invariants

Full additive regression passed against the authoritative current W01 state:

- 32,292 canonical work records;
- 90,137 source manifestations;
- 32 approved data-quality repairs applied;
- no differences in existing identity, deduplication, manifestation identity, established canonical fields or established provenance.

The production finalisation workflow validates the enriched schema boundary across the complete generated canonical JSONL before archival.

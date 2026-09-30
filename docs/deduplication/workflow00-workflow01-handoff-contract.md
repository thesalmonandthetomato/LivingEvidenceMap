# Workflow 00 -> Workflow 01 handoff contract

Status: adopted production contract. Adapter semantics, enriched manifestation preservation and work-level bibliographic fields have passed full additive-regression validation.

Branch: `workflow01-final-architecture`

## Purpose

Workflow 00 is the immutable source-acquisition layer. Each selected database harvest is archived as a separate restricted Zenodo artefact, checksummed, and addressable through the accepted Workflow 00 state.

Workflow 01 is the reconciliation/deduplication layer. It must receive enough normalised metadata from each W00 source harvest to:

1. perform the existing deduplication unchanged;
2. preserve useful source metadata in each manifestation;
3. construct an enriched canonical work record without silently discarding source information;
4. retain enough source identity to trace every canonical value back to the archived W00 source record.

Raw API payloads remain authoritative in W00 archives. They are not duplicated wholesale into W01 canonical JSONL.

## W00 archival invariants

Already established:

- each source harvest is archived independently as:
  `LivingEvidenceMap_workflow00_run-<run>_<source>-harvest.tar.gz`;
- each archive has byte size and SHA-256 recorded;
- each source archive is published to a restricted Zenodo record;
- the W00 state points to the exact archive, GitHub run, Zenodo record and native-ID registry;
- W00 state validation verifies archive metadata and native-ID registries;
- W01 restores the authoritative source archives from Zenodo before processing.

No change is required to this archival architecture.

## Handoff principles

### 1. Source identity is immutable

The W00 -> W01 handoff must preserve:

- generic `source_record_id`;
- native source identifier(s);
- DOI where supplied;
- source provider.

These values must never be rewritten merely because additional metadata are preserved.

### 2. Deduplication inputs remain unchanged

Adding fields to the handoff must not change:

- duplicate candidate generation;
- pair scoring;
- canonical cluster IDs;
- cluster membership;
- canonical DOI selection;
- existing source manifestation keys.

New fields are informational until separately approved for deduplication use.

### 3. No mapped field is silently discarded

Every mapped field exposed to W01 must have an explicit disposition:

- canonical + manifestation;
- manifestation only;
- source-specific provenance only;
- upstream raw archive only;
- explicitly excluded.

### 4. Author keywords are a distinct semantic field

`author_keywords` means author/article-supplied keywords only.

Accepted sources:

- Web of Science `authorKeywords`;
- Scopus Abstract Retrieval `author-keyword` (Workflow 02 enrichment, not W00 STANDARD search);
- Europe PMC `keywordList.keyword` (Workflow 02 enrichment);
- Lens `keywords`, retained with Lens provenance as article keywords;
- AGRICOLA-via-Europe-PMC `keywordList.keyword` where present.

Explicitly excluded:

- OpenAlex `keywords`;
- OpenAlex concepts/topics;
- MeSH headings;
- any generated/indexing vocabulary not supplied as article keywords.

## Source-specific handoff contract

### Lens

W00 currently provides:

Identity:
- `lens_id`
- `record_id`
- DOI where available

Mapped bibliographic fields:
- title
- abstract
- authors
- year
- source/journal
- DOI
- keywords
- publication type

Required W01 handoff:

Canonical-capable:
- title
- abstract
- authors
- year
- journal/source
- DOI
- `author_keywords` from Lens `keywords`
- publication type

Manifestation identity:
- lens_id
- source_record_id

Manifestation preservation:
- all canonical-capable fields above
- any additional mapped Lens bibliographic fields added later

Raw Lens payload remains in W00 archive only.

### Scopus

W00 STANDARD search / W01 adapter currently provides:

Identity:
- Scopus EID
- Scopus ID
- DOI

Mapped fields:
- title
- first author only
- year
- publication date
- journal/source
- DOI
- publication type
- affiliations
- no abstract from STANDARD
- no author keywords from STANDARD

Required W01 handoff:

Canonical-capable:
- title
- year
- journal/source
- DOI
- publication date
- publication type

Manifestation identity:
- Scopus EID
- Scopus ID
- source_record_id

Manifestation preservation:
- first-author-only structured authorship
- explicit flag/role that authorship is incomplete
- affiliations
- publication date
- publication type
- DOI

Workflow 02 may later enrich missing:
- title
- abstract
- `author_keywords`

using authenticated Scopus Abstract Retrieval, preferably by retained EID.

### OpenAlex

W00 / adapter currently provides:

Identity:
- OpenAlex work ID
- DOI

Mapped fields:
- title
- reconstructed abstract
- structured authors:
  - OpenAlex author ID
  - display name
  - ORCID
  - author position
  - corresponding-author flag
- year
- publication date
- journal/source
- DOI
- OpenAlex `keywords`
- publication type
- institutions
- open-access metadata
- primary location:
  - source ID
  - source display name
  - ISSN-L
  - ISSN
  - landing-page URL
  - PDF URL
  - OA flag
  - version

Required change before canonical enrichment:

- rename/reclassify current OpenAlex `mapped_fields$keywords` as generated/indexing terms, e.g. `indexing_terms` or `openalex_keywords`;
- do not expose them as `author_keywords`;
- preserve them at manifestation/source-specific level only if useful.

Canonical-capable:
- title
- abstract
- authors display list (existing behaviour remains unchanged)
- year
- publication date
- journal/source
- DOI
- publication type
- ISSN / ISSN-L where available

Manifestation identity:
- OpenAlex work ID
- source_record_id

Manifestation preservation:
- structured authors and IDs
- institutions
- OpenAlex generated/indexing terms, explicitly labelled non-author
- OA metadata
- primary-location metadata
- source identifiers and URLs

### AGRICOLA via Europe PMC

Adapter currently provides:

Identity:
- AGRICOLA ID
- Europe PMC source code
- DOI

Mapped fields:
- title
- abstract
- structured authors including author ID where present
- year
- journal/source
- DOI
- `keywordList.keyword`
- publication type
- author string
- affiliation
- language
- first publication date

Required W01 handoff:

Canonical-capable:
- title
- abstract
- authors
- year
- journal/source
- DOI
- `author_keywords` from `keywordList.keyword`
- publication type
- language
- publication date

Manifestation identity:
- AGRICOLA ID
- Europe PMC source
- source_record_id

Manifestation preservation:
- structured authors / author IDs
- author string
- affiliation
- language
- first publication date
- author keywords
- publication type

Current authoritative W01 source state contains zero populated AGRICOLA keyword lists, but the field remains valid in the contract for future records.

### Web of Science

W00 / Starter adapter currently provides:

Identity:
- WoS UID
- DOI

Mapped fields:
- title
- structured authors:
  - display name
  - WoS standard name
  - ResearcherID
- year
- journal/source
- DOI
- explicit author keywords
- publication type
- volume
- issue
- pages
- ISSN
- eISSN
- PMID
- source types
- WoS citation count
- no abstract from Starter

Required W01 handoff:

Canonical-capable:
- title
- authors display list
- year
- journal/source
- DOI
- `author_keywords`
- publication type
- volume
- issue
- pages
- ISSN
- eISSN
- PMID

Manifestation identity:
- WoS UID
- source_record_id

Manifestation preservation:
- structured authors / ResearcherID / WoS standard name
- explicit author keywords
- publication type
- ISSN/eISSN/PMID
- source types

Source-specific provenance only:
- WoS citation count, because it is time-varying and database-specific

## Common normalised manifestation contract

Every W01 manifestation should be allowed to expose the following additive structure:

```json
{
  "source": "wos",
  "source_record_id": "wos:WOS:...",
  "identifiers": {
    "doi": "10....",
    "lens_id": null,
    "scopus_eid": null,
    "scopus_id": null,
    "openalex_id": null,
    "agricola_id": null,
    "wos_uid": "WOS:...",
    "pmid": "..."
  },
  "title": "...",
  "abstract": null,
  "authors": ["..."],
  "structured_authors": [],
  "year": 2024,
  "publication_date": "2024-...",
  "journal": "...",
  "volume": "...",
  "issue": "...",
  "pages": "...",
  "author_keywords": ["..."],
  "publication_type": ["..."],
  "issn": ["..."],
  "eissn": ["..."],
  "issn_l": ["..."],
  "language": ["..."],
  "affiliations": [],
  "institutions": [],
  "source_specific": {}
}
```

Only fields supplied by the source are populated.

Existing manifestation fields remain unchanged. New fields are additive.

## Production canonical additions

The following are now part of the production W01 canonical work object:

- `author_keywords`
- `publication_type`
- `publication_date`
- `language`
- `issn`
- `eissn`
- `issn_l`
- `pmid`

Existing canonical fields remain unchanged.

### Author-keyword consolidation

For each deduplicated work:

1. collect `author_keywords` from eligible manifestations only;
2. trim leading/trailing whitespace;
3. collapse repeated internal whitespace;
4. remove empty values;
5. deduplicate case-insensitively while preserving the first retained spelling;
6. do not stem, synonymise, singularise, translate or otherwise semantically normalise;
7. retain provenance linking each canonical keyword to contributing manifestation key(s).

Distinct terms are not conflicts. For example, `sea lice` and `Lepeophtheirus salmonis` both survive.

## Adopted adapter semantics

1. **OpenAlex**
   - generated `keywords` are classified as non-author `indexing_terms`;
   - they remain manifestation/source-specific metadata and never populate `canonical.author_keywords`.

2. **Lens**
   - expose current `keywords` to the common handoff explicitly as `author_keywords` / article keywords with Lens provenance.

3. **AGRICOLA**
   - expose `keywordList.keyword` explicitly as `author_keywords`.

4. **WoS**
   - rename or alias `authorKeywords` mapping explicitly to `author_keywords`.

5. **Scopus**
   - keep W00 STANDARD `author_keywords` empty;
   - preserve EID so W02 can retrieve author keywords later.

No W00 search/API behaviour needs to change for these steps.

## Production validation requirements

The adopted schema is protected by the following invariants:

1. baseline-vs-enriched W01 regression must pass for all 32,292 current records;
2. record IDs must be identical;
3. cluster IDs and membership must be identical;
4. source + source_record_id manifestation identity sets must be identical;
5. existing canonical DOI/title/abstract/authors/year/journal/volume/issue/pages must be identical;
6. existing field provenance must be identical;
7. every newly populated manifestation field must trace to a source adapter value;
8. OpenAlex generated terms must never appear in `canonical.author_keywords`;
9. every canonical author keyword must trace to at least one eligible manifestation;
10. no newly preserved field may influence deduplication until separately approved and validated.

## Validation status

The complete enriched W01 schema has passed additive regression against the authoritative current baseline of 32,292 canonical works and 90,137 source manifestations. Existing identities, deduplication state, canonical title/abstract/DOI/authors/year/journal/volume/issue/pages and their provenance remained unchanged.

Validated production additions are:

- rich source-specific `manifestation_metadata`;
- `canonical.author_keywords`;
- `canonical.publication_type`;
- `canonical.publication_date`;
- `canonical.language`;
- `canonical.issn`;
- `canonical.eissn`;
- `canonical.issn_l`;
- `canonical.pmid`.

The production finalisation workflow now validates the presence of these canonical fields and provenance entries across the entire output, verifies manifestation metadata on every manifestation, and explicitly guards against OpenAlex generated terms entering manifestation author keywords.

## Generic source ingestion architecture

Workflow 01 source ingestion is no longer limited to the original five databases.

The authoritative source catalogue is:

`config/workflow01_source_catalogue.json`

Each catalogue entry declares:

- a stable source namespace;
- the acquisition/restoration kind;
- the prepared W01 input path;
- for manual RIS sources, the W00 registry that identifies the published restricted Zenodo record.

Two restoration classes are currently supported:

1. `workflow00_state`: the established W00 composite state used for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science;
2. `manual_ris`: a published restricted W00 RIS archive restored from Zenodo using its committed W00 registry.

The catalogue is converted into a validated W01 source-input manifest. Union construction emits a corresponding manifest for the complete prior-plus-new manifestation union. Candidate generation, scoring and canonicalisation consume this manifest rather than a hard-coded source list.

New source providers therefore use their stable lower-case W00 `database.short_name` directly as the W01 `source` namespace, except for the retained legacy aliases:

- `agricola_via_europe_pmc` -> `agricola`;
- `wos_starter` -> `wos`.

The manifestation identity remains:

`source + source_record_id`

No additional search-event identifier is introduced into the canonical JSONL.

### Manual-RIS validation

The generic ingestion route was validated against the current authoritative W01 state in GitHub Actions run `36727268372`.

The validation restored:

- CAB Abstracts: 26,816 manifestations;
- ProQuest Dissertations & Theses Global: 1,574 manifestations.

It then confirmed:

- 90,137 historical W01 manifestations were preserved in their exact existing row order;
- 28,390 new manifestations were appended;
- the seven-source union contained 118,527 manifestations;
- CAB contributed exactly 26,816 rows to the normalised metadata index;
- ProQuest contributed exactly 1,574 rows;
- no existing manifestation identity was lost or reordered.

This validation stopped after metadata indexing. It did not run duplicate scoring, LLM adjudication or canonical publication.

### Durable state

The source-generic contract also applies to:

- incremental scoring;
- Workflow 01 delta construction;
- delta replay;
- human-review checkpoint creation;
- checkpoint source reconstruction;
- resume-after-human-review canonicalisation.

Source files are discovered from the current W01 seed/source manifest and persisted by source namespace. A newly introduced source may therefore have no corresponding file in the previous state; it is treated as an append-only new source. Existing sources may never disappear or change their historical prefix.

## Remaining downstream work

Workflow 02 may fill missing title, abstract and author keywords using separately validated Europe PMC and Scopus enrichment. Future database additions should be registered through the W01 source catalogue and must preserve the established W01 identity and deduplication semantics.

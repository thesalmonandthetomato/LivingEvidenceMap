# Workflow 02 repair / enrichment specification

Status: design specification only. Implement after Workflow 01 deduplication is validated.

## Input

The deduplicated canonical publication records produced by Workflow 01.

Do not enrich every raw source manifestation independently.

## Eligibility for Europe PMC lookup

A canonical record is eligible only when:

1. it contains a DOI; and
2. at least one of the following is true:
   - title is empty;
   - title contains a literal ellipsis (`...`) or Unicode ellipsis (`…`);
   - abstract is empty;
   - abstract contains a literal ellipsis (`...`) or Unicode ellipsis (`…`).

No lookup is required for a complete title and complete abstract.

## Lookup policy

- Normalise DOI before querying.
- Query Europe PMC by DOI.
- Query once per unique DOI.
- Use exact DOI matching for automatic repair.
- Batch DOI requests where supported to reduce API calls.
- Retry transient provider failures with checkpointed progress.
- Do not use fuzzy title matching for automatic repair unless explicitly introduced and separately validated.

## Repair policy

Only repair fields that triggered eligibility:

- empty title -> fill from exact-DOI Europe PMC result if available;
- ellipsis title -> replace with complete Europe PMC title if available;
- empty abstract -> fill from exact-DOI Europe PMC result if available;
- ellipsis abstract -> replace with complete Europe PMC abstract if available.

Do not overwrite a complete title or complete abstract merely because Europe PMC differs.

## Provenance

For every attempted DOI, retain:

- canonical record identifier;
- normalised DOI;
- provider;
- match method;
- lookup status;
- original title and/or abstract for any repaired field;
- replacement title and/or abstract;
- timestamp;
- provider response identifier where available.

Raw source manifestations remain unchanged.

## Output

A repaired canonical record set plus a machine-readable repair audit.

The repaired canonical set becomes the input to downstream screening and coding workflows.

# Updater Pipeline — Workflow 01B: abstract enrichment

**Status:** development implementation
**Scope:** Europe PMC abstract recovery between Lens ingestion and deduplication
**Last reviewed:** 2026-08-28

## Purpose

Enrich Workflow 01 Lens records that have a DOI but no abstract, then emit canonical JSONL ready for Workflow 02 deduplication.

## Boundary

```text
Workflow 01: Lens ingestion
  -> Workflow 01B: Europe PMC abstract enrichment
  -> Workflow 02: deduplication
```

Workflow 01B does not deduplicate, screen, annotate, adjudicate, classify topics, merge into the master, or update the dashboard.

## Rules

- `lens.raw_payload` is immutable and is never overwritten.
- Existing Lens/canonical abstracts are never replaced.
- Only DOI-bearing records missing an abstract are queried externally.
- The sole enrichment source is Europe PMC, queried by exact DOI.
- Lens-provided URLs are not scraped.
- Crossref is not queried.
- No title search is used.
- Failure to recover an abstract does not remove the record.
- Every input record is emitted exactly once.

## Deduplication-ready canonical object

Workflow 02 treats a present `canonical` object as authoritative. Workflow 01B therefore writes a complete canonical bibliographic object rather than only adding `canonical.abstract`:

- `record_id`
- `lens_id`
- `title`
- `authors`
- `year`
- `source`
- `doi`
- `abstract`

The complete original Lens record remains available under `lens.raw_payload`.

## Provenance

Each record receives `abstract_enrichment` containing status, DOI, Europe PMC retrieval time where applicable, and the Europe PMC attempt/outcome. A separate JSONL audit and run report are also emitted.

## Status values

- `existing_abstract`
- `missing_no_doi`
- `abstract_recovered`
- `no_abstract_recovered`

Technical failures are retained inside attempt provenance and do not cause bibliographic records to disappear.

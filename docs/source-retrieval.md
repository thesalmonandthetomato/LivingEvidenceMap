# Source retrieval architecture

## Frozen baseline

The multi-source retrieval baseline is preserved in GitHub Release:

`source-baselines-2026-09-20`

Release:
https://github.com/thesalmonandthetomato/LivingEvidenceMap/releases/tag/source-baselines-2026-09-20

It contains:

- Scopus full-search archive
- OpenAlex full-search archive
- AGRICOLA-via-Europe-PMC full-search archive
- Lens baseline JSONL from `canonical-repair-store`, retaining `lens.raw_payload`
- per-source provenance manifests
- `SHA256SUMS`

The Lens asset is a lossless per-record source snapshot, not the original paginated Lens API response files.

These baseline assets are historical evidence and must not be silently replaced. A later full search creates a new snapshot.

## Retrieval modes

The common retrieval contract is defined in:

`config/source_retrieval_modes.yml`

The dispatcher is:

`.github/workflows/source_retrieval.yml`

Manual inputs:

- source: `all | lens | scopus | openalex | agricola`
- mode: `full | fortnightly | quarterly`

### full

Run the complete source search. Use only for a new baseline, a changed search strategy, or explicit re-baselining.

### fortnightly

Routine living-evidence retrieval using the last successful checkpoint with a 14-day backward overlap.

- Lens: `created` date window
- Scopus: `LOAD-DATE`
- AGRICOLA/Europe PMC: `UPDATE_DATE`
- OpenAlex: full-refresh fallback until premium `from_updated_date` entitlement is verified

### quarterly

Full reconciliation sweep. This is deliberately broader than the fortnightly update and is intended to catch delayed indexing and metadata changes.

## Source state

Successful retrieval checkpoints are stored under:

`state/source_retrieval/`

A failed retrieval must never advance these files.

Each successful retrieval uploads a raw/intermediate Actions artefact retained for 30 days and then advances the source state only after the selected retrieval job succeeds.

## Cost and provenance rules

Before any fresh external call, check whether the required source snapshot or intermediate artefact already exists.

Downstream validation, sidecar generation, reconciliation, deduplication, or formatting changes must reuse preserved artefacts rather than repeating source API calls.

See `AI_ASSISTANT_GUIDELINES.md` for the repository-wide operating rules.

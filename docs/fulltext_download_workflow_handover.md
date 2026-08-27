# LivingEvidenceMap — full-text acquisition workflow handover

**Snapshot:** 2026-08-27  
**Purpose:** canonical handover for the provenance and operation of the OpenAlex → GROBID/PDF → GitHub checkpoint → private Zenodo full-text acquisition pipeline.

## Read this first

This document describes the acquisition pipeline only. It is deliberately separate from the downstream AI-coding handover in `docs/fulltext_coding_workflow_handover.md`.

The acquisition pipeline supplies the full texts; the AI coding pipeline consumes them later. Do not alter the coding prompt/schema while troubleshooting acquisition unless a separate coding issue is demonstrated.

## Corpus origin and DOI provenance

The full-text download plan was derived from the LivingEvidenceMap corpus's DOI records and an OpenAlex metadata/content audit. The documented audit basis was:

- 11,291 DOI records checked;
- 11,265 exact OpenAlex DOI matches;
- 6,199 OpenAlex OA records;
- 3,935 works with PDF content;
- 3,705 works with GROBID XML;
- all 3,705 GROBID works also had PDF;
- 230 works had PDF only;
- no works were GROBID-only.

The resulting download corpus is therefore **3,935 files, one per work**: 3,705 GROBID TEI XML files plus 230 PDF-only files. GROBID is preferred whenever available, so the same work is not downloaded in both formats.

The DOI → OpenAlex mapping is represented in the candidate files:

- `data/openalex_grobid_candidates.csv`
- `data/openalex_pdf_candidates.csv`

The downloader itself uses the `input_doi` and `openalex_id` fields from these candidate tables. It requires an exact DOI match and a valid OpenAlex content flag before including a work in the plan.

## Historical manual stage and reconstruction of batches 1–5

The acquisition pipeline began with manually initiated batches while the OpenAlex acquisition pathway was being developed and tested. We have now reconstructed the **membership of the first five manual batches** from the downloader's deterministic planning logic and the subsequent Batch 6 run; this supersedes the earlier caution that the batch membership might be unrecoverable.

The downloader constructs one deterministic plan from the candidate tables, then assigns sequential positions and groups them into batches of 100. The batch boundaries are therefore:

| Batch | Download-plan positions | Historical status |
|---|---:|---|
| 1 | 1–100 | manually initiated |
| 2 | 101–200 | manually initiated |
| 3 | 201–300 | manually initiated |
| 4 | 301–400 | manually initiated |
| 5 | 401–500 | manually initiated |
| 6 | 501–600 | first scheduled/automated batch |

The current downloader explicitly uses `BATCH_SIZE = 100` and computes the batch slice from `(batch_number - 1) * 100`. This means batches 1–5 were the first 500 records in the frozen download plan, rather than arbitrary sets of 100 DOIs.

The plan itself is deterministic:

1. include GROBID candidates where `doi_exact_match == TRUE` and `has_grobid_xml == TRUE`;
2. then include PDF candidates where `doi_exact_match == TRUE`, `has_pdf == TRUE`, and the DOI is not already in the GROBID set;
3. represent each work by DOI, OpenAlex Work ID, content URL and format;
4. reject a plan containing duplicate DOIs;
5. batch the resulting plan into groups of 100.

A subsequent real Batch 6 Actions run provides an independent boundary check: run `32954157932` reports **Batch 6/40: files 501–600**, and its manifest contains `batch_position` values beginning at 501. Thus the end of manual batch 5 is established at position 500 and the beginning of automated batch 6 at position 501.

### What this establishes, and what it does not

**Established:** the exact DOI membership of batches 1–5 can be reconstructed deterministically as positions 1–500 of the download plan defined by the candidate tables and downloader code. To reproduce the exact DOI lists, take rows 1–500 of the plan produced by the current/compatible `build_plan()` logic, preserving its order.

**Not established from the surviving permanent files alone:** the individual GitHub Actions run IDs, timestamps, artifact IDs, and Zenodo receipt details for each of manual batches 1–5. Those are historical execution metadata and should be recovered from the relevant Actions history/artifacts if needed. They are not necessary to establish DOI membership.

This distinction is intentional: do not infer historical run metadata merely from batch membership.

## Deterministic download plan

The downloader constructs the plan as:

1. Include GROBID candidates where `doi_exact_match == TRUE` and `has_grobid_xml == TRUE`.
2. Include PDF candidates where `doi_exact_match == TRUE`, `has_pdf == TRUE`, and the DOI is not already in the GROBID set.
3. Represent each work by DOI, OpenAlex Work ID, content URL and format.
4. Reject a plan containing duplicate DOIs.
5. Batch the resulting plan in groups of **100 content files maximum**.

The planned 3,935 files therefore form 40 batches:

- batches 1–37: 100 GROBID XML each;
- batch 38: final 5 GROBID XML + first 95 PDF-only files;
- batch 39: 100 PDF-only files;
- batch 40: final 35 PDF-only files.

OpenAlex content URLs are requested using the OpenAlex API key. The downloader validates received content: PDFs must have PDF magic bytes; GROBID responses must contain a TEI marker. Gzip-compressed GROBID responses are handled. Transient errors are retried.

## Evolution of the pipeline

The Git history documents this progression:

1. OpenAlex full-text audit and candidate selection.
2. Initial OpenAlex full-text downloader.
3. Manual batch workflow with a maximum of 100 content files.
4. Private Zenodo draft storage for durable batch archives.
5. Authentication/diagnostic fixes for OpenAlex content downloads.
6. GROBID validation and gzip handling.
7. Partial-batch checkpointing and recoverable failures.
8. Provenance recording linking DOI/OpenAlex IDs to workflow and Zenodo.
9. Automated daily progression through batches 6–40.
10. Current provenance registry and downstream Zenodo coding workflow.

Relevant historical commits include:

- `91ad96a2aa51fdd3ba5925b9e9f928b468b07a59` — Add OpenAlex full-text batch downloader
- `66b5e63f370ad437294471fcb0de47061010bba0` — Add manual OpenAlex full-text download workflow
- `9953d328cab2e81295897b488c243bf9512604f2` — Document OpenAlex full-text download pathway
- `f563b29aab82a00ba8e53168de6efe4f02ab27c1` — Store OpenAlex full-text batches in private Zenodo drafts
- `dca9450fcb22f1e7384d251a36147eead21d97bc` — Upload OpenAlex full-text batches to private Zenodo drafts
- `a8094b3c2a6da43c2a6da43ae2c18ba1ad503ac757230d98` — Preserve partial OpenAlex batch progress on failure
- `8477bb44801615e4eaa283abf2221c8132203a7a` — Checkpoint OpenAlex files before Zenodo upload
- `12fea08a5a9b617ea058bdb4d1581cfb90c673da` — Add partial-batch Zenodo depositor
- `2fbef5eb7d9f9c2fd2cd12bdbf5d1d853f719433` — Record DOI/OpenAlex to workflow and Zenodo provenance
- `d2c10cd14e36035c3a61b2c60eab205d869cbc02` — Record OpenAlex batch 6 provenance

## Current GitHub Actions workflow

Workflow:

`.github/workflows/openalex_fulltext_download.yml`

The current workflow supports both manual dispatch and a daily schedule. The schedule is configured to calculate batch numbers from a start date, beginning at batch 6 and ending at batch 40. The current file records:

- `SCHEDULE_START_DATE = 2026-08-26`
- `SCHEDULE_START_BATCH = 6`
- `LAST_BATCH = 40`
- cron = `0 9 * * *` UTC
- manual input `batch_number` from 1–40
- one global concurrency lock `openalex-fulltext-zenodo`
- Ubuntu runner, Python 3.12
- 240-minute job timeout

The scheduled workflow was deliberately introduced only after the early manual testing period. **If acquisition must remain manual in a future phase, disable/remove the schedule rather than changing the downloader logic.**

## Download stage

The workflow calls:

`scripts/download_openalex_only.py`

which imports the planning and download functions from:

`scripts/download_openalex_fulltext.py`

The OpenAlex-only wrapper deliberately does not invoke Zenodo mode, keeping acquisition and downstream storage as separate stages within the workflow.

For each batch, the workflow:

1. determines the batch;
2. restores its batch-specific cache;
3. downloads OpenAlex content;
4. uploads the batch directory as a 90-day Actions artifact;
5. saves the batch cache;
6. stages available files to Zenodo;
7. verifies the Zenodo round trip;
8. updates `data/reference/fulltext_batch_registry.csv`;
9. uploads final batch state as another 90-day artifact.

The downloader writes and updates `download_manifest.csv` as it progresses. The manifest contains:

- batch;
- batch position;
- DOI;
- OpenAlex ID;
- format;
- OpenAlex content URL;
- status;
- byte size;
- SHA-256;
- local filename.

## Zenodo storage

The durable storage design packages each 100-file batch into a ZIP and stages the ZIP in private, unpublished Zenodo draft storage.

The intended four Zenodo parts are:

- Part 01: batches 01–10
- Part 02: batches 11–20
- Part 03: batches 21–30
- Part 04: batches 31–40

The Zenodo batch ZIP name is linked to the GitHub Actions run, for example:

`LivingEvidenceMap_fulltext_batch_006_run-32954157932.zip`

The current partial depositor is:

`scripts/zenodo_partial_batch.py`

It can deposit successfully downloaded files from a partial batch, validates them first, creates the run-linked ZIP filename, uploads to the appropriate Zenodo draft part, and writes `zenodo_receipt.json`.

The receipt records batch, successful/failed counts, Zenodo deposition ID/URL, ZIP filename, byte size, SHA-256, GitHub run ID and run URL.

## Zenodo verification

After staging, the workflow runs:

`scripts/verify_zenodo_batch.py`

and records the verification state in the batch directory. The workflow then updates the master provenance registry.

## Master provenance registry

`data/reference/fulltext_batch_registry.csv` is the central acquisition provenance table.

Its fields include:

- `doi`
- `openalex_id`
- `workflow_name`
- `workflow_run_id`
- `workflow_run_url`
- `run_number`
- `zenodo_record_id`
- `zenodo_record_url`
- `zenodo_version_doi`
- `zenodo_concept_doi`
- `zenodo_archive_filename`
- `status`
- `notes`

The notes also preserve the GROBID source filename, e.g. `W4205942496.tei.xml`.

The registry is committed back to GitHub after successful Zenodo staging. It is therefore the bridge between the OpenAlex DOI/Work ID and the later Zenodo/coding stages.

## Current confirmed example

The first scheduled provenance currently recorded in the repository is OpenAlex batch 6, GitHub Actions run `32954157932`, Zenodo record `22109515`, with archive filename:

`LivingEvidenceMap_fulltext_batch_006_run-32954157932.zip`

The registry contains DOI/OpenAlex ID pairs for the individual files in that batch and identifies their corresponding TEI filenames.

## Failure recovery / data-loss protection

There are several layers:

1. **Per-file atomic download and validation.** Failed downloads do not replace valid files.
2. **Manifest flushed during the batch.** Partial progress survives in the runner workspace.
3. **Batch-specific GitHub cache.** A rerun can restore successful files and skip them.
4. **90-day GitHub Actions artifacts.** Batch state is retained for recovery.
5. **Zenodo durable ZIP.** Successfully staged batches are stored outside the Actions runner.
6. **Zenodo round-trip verification.** The workflow checks that the staged data can be retrieved/verified.
7. **Provenance registry commit.** DOI/OpenAlex/Zenodo relationships are persisted in Git.

A failed OpenAlex download does not result in a Zenodo upload of an incomplete batch through the normal full-batch path. The partial-batch path can preserve successful files and explicitly flag failures for later recovery.

## What must not be inferred

Do not claim that the exact historical Actions run IDs, timestamps, artifact IDs, or Zenodo receipt details for manual batches 1–5 are established merely from their reconstructed DOI membership. Those execution details require the corresponding historical Actions records/artifacts.

Do not assume that a Zenodo record contains one DOI or one article. A Zenodo record/part contains batch ZIP archives, and each ZIP contains multiple OpenAlex works. Use the batch registry and source filenames to resolve individual papers.

## When resuming this project

1. Read this file.
2. Read `docs/fulltext_download_workflow_handover.json`.
3. Inspect the current `openalex_fulltext_download.yml` rather than relying on the historical description above.
4. Inspect `data/reference/fulltext_batch_registry.csv` to determine what is actually deposited.
5. Inspect the OpenAlex candidate tables to confirm the current download plan.
6. Check GitHub Actions runs/artifacts for any batches whose registry status is incomplete or failed.
7. Check Zenodo draft records/receipts for durable storage.
8. Only then decide whether acquisition should continue, be repaired, or be handed to the downstream AI coding workflow.

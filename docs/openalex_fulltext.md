# OpenAlex full-text download pathway

## Purpose

This pathway downloads the machine-readable full text available in the OpenAlex content archive for the Living Evidence Map corpus and durably stores each completed batch in **private Zenodo draft storage**.

The workflow is deliberately **manual**. It is not scheduled and does not run on push, pull request, or any other automatic trigger. This is intentional because OpenAlex content downloads are metered.

## Audit basis

The OpenAlex metadata audit in the `OpenAlex full text` commit found:

| Measure | Count |
|---|---:|
| DOI records checked | 11,291 |
| Exact OpenAlex DOI matches | 11,265 |
| OpenAlex OA records | 6,199 |
| PDF available | 3,935 |
| GROBID XML available | 3,705 |
| PDF and GROBID XML | 3,705 |
| PDF only | 230 |
| GROBID only | 0 |

Therefore the download corpus is **3,935 full-text files, one file per work**:

1. **3,705 GROBID TEI XML files** for works where OpenAlex has a GROBID parse.
2. **230 PDFs** for the remaining works where a PDF is available but GROBID XML is not.

We do **not** download both formats for the same work. GROBID is preferred because the project's downstream requirement is machine-readable structured text.

## What OpenAlex provides

OpenAlex's content archive provides cached full text as PDF and machine-readable TEI XML parsed by GROBID. The API exposes `has_content.pdf`, `has_content.grobid_xml`, and `content_urls` for works where content is available.

The content API uses the OpenAlex Work ID. The workflow downloads only content URLs identified by the audit; it does not attempt to discover or bypass paywalls.

## Cost and batching

OpenAlex currently charges **$0.01 per PDF/XML content file**. A free API key includes **$1/day**, which is approximately 100 content files/day. Therefore:

```text
3,935 files × $0.01 = $39.35 maximum content cost
```

The downloader never requests more than 100 OpenAlex content files in one workflow run.

The current 3,935-file plan therefore consists of **40 batches**:

- Batches 1–37: 100 GROBID XML each = 3,700 files.
- Batch 38: the final 5 GROBID XML files + the first 95 PDF-only files = 100 files.
- Batch 39: remaining 100 PDF-only files.
- Batch 40: remaining 35 PDF-only files.

The plan is deterministic and GROBID-first.

## Permanent storage: private Zenodo drafts

The downloaded files are **not committed to GitHub** and are not published by the workflow.

Each completed batch is packaged into one ZIP archive and uploaded to a private, unpublished Zenodo deposition. The four depositions are:

```text
Part 01: batches 01–10
Part 02: batches 11–20
Part 03: batches 21–30
Part 04: batches 31–40
```

This structure deliberately keeps the number of Zenodo files low (10 ZIPs per deposition) and well below the 100-file per-record limit. Zenodo currently recommends packaging collections of 20+ files as ZIP archives, and supports up to 50 GB and 100 files per record. citeturn4search0

The Zenodo depositions remain **drafts**. They are not published and therefore are not exposed as public research records. The workflow never calls the Zenodo publish action. Zenodo's current model also supports restricted/closed file visibility; published records always expose metadata, so keeping these depositions unpublished is the stronger privacy choice for this working corpus. citeturn2search0turn2search4

### Zenodo authentication

Create a Zenodo personal access token with the `deposit:write` scope and add it to the repository as:

```text
ZENODO_ACCESS_TOKEN
```

The workflow does not need `deposit:actions` because it never publishes the depositions. Zenodo recommends using the token in an HTTPS `Authorization: Bearer` header. citeturn1search0

The existing OpenAlex API key remains required as:

```text
OPENALEX_API_KEY
```

Neither token is written to the repository, manifests, artifacts, or Zenodo metadata.

## GitHub Actions workflow

Workflow:

```text
.github/workflows/openalex_fulltext_download.yml
```

Script:

```text
scripts/download_openalex_fulltext.py
```

Candidate inputs:

```text
data/openalex_grobid_candidates.csv
data/openalex_pdf_candidates.csv
```

The downloader derives the PDF-only set as:

```text
has_pdf == TRUE AND has_grobid_xml != TRUE
```

This prevents duplicate downloads for the 3,705 works that have both formats.

## How to run a batch

1. Add the GitHub Actions secret `OPENALEX_API_KEY`.
2. Add the GitHub Actions secret `ZENODO_ACCESS_TOKEN`.
3. Open **Actions → OpenAlex full-text download**.
4. Choose **Run workflow**.
5. Enter a batch number from **1 to 40**.
6. Run one batch per free OpenAlex daily allowance unless prepaid OpenAlex usage is deliberately intended.

The workflow has a **single global concurrency lock**. If another batch is already running, GitHub queues the next run rather than allowing two runs to edit the same Zenodo draft simultaneously.

## Failure recovery and no-data-loss design

There are three layers of recovery:

### 1. File-level checkpointing on the runner

Each successfully downloaded OpenAlex file is written atomically and validated. A manifest is flushed after every file. A `.part` file is removed if a download fails.

### 2. GitHub Actions cache and artifact

The entire batch directory is saved to a batch-specific GitHub Actions cache and uploaded as a 90-day artifact. This protects work if the workflow fails after some files have been downloaded but before Zenodo upload completes.

### 3. Zenodo durable batch archive

Only after **all files in the batch have downloaded and validated** does the script create the batch ZIP and upload it to Zenodo.

The script first asks Zenodo whether that batch ZIP already exists. If it does and the size matches, the upload is skipped. Consequently:

```text
OpenAlex download succeeds
        |
        v
local validated files
        |
        v
batch ZIP + SHA-256
        |
        v
Zenodo upload succeeds
        |
        v
workflow may fail here safely
        |
        v
next run sees ZIP already in Zenodo
        |
        v
NO REDOWNLOAD / NO DUPLICATE STORAGE
```

If the OpenAlex download fails part way through, the incomplete batch is **not** uploaded to Zenodo. A rerun restores the successful files from the GitHub cache and downloads only the missing files.

If the Zenodo upload fails after the OpenAlex downloads succeed, the cached files and 90-day artifact remain available, and the rerun recreates the same ZIP and checks Zenodo before attempting another upload.

A `zenodo_receipt.json` is written into each batch artifact containing the Zenodo deposition ID, batch ZIP name, size, SHA-256, upload status, and timestamp.

## Output structure

GitHub Actions retains a temporary/recovery copy:

```text
openalex_fulltext/
  batch_001/
    W1234567890.tei.xml
    ...
    download_manifest.csv
    openalex_fulltext_batch_001.zip
    zenodo_receipt.json
```

Zenodo stores the durable copy as:

```text
LivingEvidenceMap OpenAlex Full Text — Part 01
  openalex_fulltext_batch_001.zip
  ...
  openalex_fulltext_batch_010.zip

LivingEvidenceMap OpenAlex Full Text — Part 02
  openalex_fulltext_batch_011.zip
  ...
```

and so on through Part 04.

Each ZIP contains the individual GROBID XML/PDF files plus the batch manifest.

## Integrity and provenance

The batch manifest records:

- batch number
- batch position
- DOI
- OpenAlex Work ID
- format
- OpenAlex content URL
- download status
- byte size
- SHA-256 checksum
- local filename

The ZIP itself also receives a SHA-256 checksum, recorded in `zenodo_receipt.json`.

Zenodo calculates and records its own file checksum. The local SHA-256 receipt provides an independent end-to-end integrity check for the exact archive produced by the workflow.

## Why the full texts are not committed to Git

The full-text files are binary/XML research content and can be large. Committing thousands of PDFs/XML files directly to the repository would make the Git history unnecessarily large and difficult to manage.

The repository therefore contains the reproducible **selection/audit metadata, downloader, workflow, manifests/checksum logic, and documentation**, while Zenodo holds the durable private corpus.

## Reproducibility

The pathway is:

```text
main database
    |
    v
OpenAlex DOI metadata audit
    |
    +--> openalex_grobid_candidates.csv
    |
    +--> openalex_pdf_candidates.csv
    |
    v
GROBID-first deterministic download plan
    |
    +--> batches 01–37: GROBID XML
    |
    +--> batch 38: GROBID XML + PDF-only
    |
    +--> batches 39–40: PDF-only
    |
    v
validated local batch
    |
    +--> GitHub cache/artifact (recovery)
    |
    +--> Zenodo private draft ZIP (durable storage)
```

No paywalled article is targeted by this pathway. The downloader only uses content that OpenAlex has explicitly marked as downloadable in its content archive.

## Important distinction

OpenAlex's GROBID XML is a machine-readable parse of the PDF. It is not a separate publisher version of the article. GROBID parsing can contain errors, and scanned/image-only PDFs may not produce useful XML. The audit's `has_content.grobid_xml` flag is therefore used to select works for which OpenAlex has a GROBID parse.

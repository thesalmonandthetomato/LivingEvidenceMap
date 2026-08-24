# OpenAlex full-text download pathway

## Purpose

This pathway downloads the machine-readable full text available in the OpenAlex content archive for the Living Evidence Map corpus.

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

Therefore the download corpus is **3,935 files, one file per work**:

1. **3,705 GROBID TEI XML files** for works where OpenAlex has a GROBID parse.
2. **230 PDFs** for the remaining works where a PDF is available but GROBID XML is not.

We do **not** download both formats for the same work. GROBID is preferred because the project's downstream requirement is machine-readable structured text.

## What OpenAlex provides

OpenAlex's content archive provides cached full text as PDF and machine-readable TEI XML parsed by GROBID. The API exposes `has_content.pdf`, `has_content.grobid_xml`, and `content_urls` for works where content is available.

The content API uses the OpenAlex Work ID, for example:

```text
https://content.openalex.org/works/W1234567890.grobid-xml
https://content.openalex.org/works/W1234567890.pdf
```

The workflow authenticates these requests with the repository's `OPENALEX_API_KEY` secret.

## Cost and batching

OpenAlex currently charges **$0.01 per PDF/XML content file**. A free API key includes **$1/day**, which is approximately 100 content files per day. Therefore:

```text
3,935 files × $0.01 = $39.35 maximum content cost
```

The downloader never requests more than 100 content files in a batch.

The current 3,935-file plan therefore consists of **40 batches**:

- Batches 1–37: 100 GROBID XML each = 3,700 files.
- Batch 38: the final 5 GROBID XML files + the first 95 PDF-only files = 100 files.
- Batch 39: remaining 100 PDF-only files.
- Batch 40: remaining 35 PDF-only files.

The plan is deterministic and GROBID-first. The final batch contains 35 files.

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

1. Ensure the repository has an Actions secret named:

```text
OPENALEX_API_KEY
```

2. Open **Actions → OpenAlex full-text download**.

3. Choose **Run workflow**.

4. Enter a batch number from **1 to 40**.

5. Run **one batch per free daily allowance** unless you deliberately intend to use prepaid OpenAlex usage.

The workflow does not create a schedule. You choose when the next batch is run.

## Checkpointing and failure recovery

The workflow uses a separate GitHub Actions cache for each batch. The downloader writes each successfully downloaded file to the batch directory and flushes its manifest after every file.

If a batch fails part way through:

1. The partial batch is uploaded as an Actions artifact.
2. The partial batch is saved to the batch-specific Actions cache.
3. Re-running the same batch restores that cache.
4. Existing valid files are checked and skipped rather than downloaded again.
5. The downloader retries transient network errors with exponential backoff.

This is important because a retry should not unnecessarily purchase the same OpenAlex content file twice.

The cache is a recovery mechanism, not the long-term corpus store. GitHub Actions caches are subject to GitHub's retention/eviction rules. The workflow also uploads each batch as an artifact with 90-day retention so completed batches can be retrieved while the corpus is being assembled.

## Output structure

Each workflow run produces an artifact named:

```text
openalex-fulltext-batch-N
```

with:

```text
batch_NNN/
  W1234567890.tei.xml
  W1234567891.tei.xml
  ...
  download_manifest.csv
```

or, for PDF-only records:

```text
batch_NNN/
  W1234567892.pdf
  ...
  download_manifest.csv
```

The manifest records:

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

## Why the files are not committed to Git

The full-text files are binary/XML research content and can be large. Committing thousands of PDFs/XML files directly to the repository would make the Git history unnecessarily large and difficult to manage.

Instead, the repository contains the reproducible **selection/audit metadata, downloader, workflow, and documentation**, while GitHub Actions artifacts hold the downloaded batch outputs during collection.

The manifest and SHA-256 checksum provide an auditable record of exactly which OpenAlex Work ID was downloaded and what bytes were received.

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
    +--> batches 1–37: GROBID XML
    |
    +--> batch 38: GROBID XML + PDF-only
    |
    +--> batches 39–40: PDF-only
    |
    v
GitHub Actions artifact + batch manifest + SHA-256
```

No paywalled article is targeted by this pathway. The downloader only uses content that OpenAlex has explicitly marked as downloadable in its content archive.

## Important distinction

OpenAlex's GROBID XML is a machine-readable parse of the PDF. It is not a separate publisher version of the article. GROBID parsing can contain errors, and scanned/image-only PDFs may not produce useful XML. The audit's `has_content.grobid_xml` flag is therefore used to select works for which OpenAlex has a GROBID parse.

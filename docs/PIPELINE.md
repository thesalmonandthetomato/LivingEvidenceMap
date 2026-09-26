# Salmon scoping review pipeline

## Purpose

This document is the authoritative description of the processing sequence for the **salmon scoping review living evidence map**. It is specific to the salmon review and is not a generic evidence-map framework.

The repository is self-contained. The former `salmonscopingreview` repository is used only for historical implementation provenance and is not a runtime dependency.

## Required production sequence

The canonical workflow numbering is:

1. **Workflow 00 — search / ingestion** — acquire source records and preserve source-level provenance.
2. **Workflow 01 — deduplication / canonicalisation** — reconcile manifestations, resolve duplicate identity, and publish the canonical work set.
3. **Workflow 02 — bibliographic repair / enrichment** — enrich missing bibliographic fields without overwriting valid populated data.
4. **Workflow 03 — publication status** — identify and exclude retracted or withdrawn records according to the publication-status rules.
5. **Workflow 04 — relevance screening** — apply the validated title-and-abstract relevance-screening model and retain explicit uncertainty.
6. **Workflow 05 — deterministic species annotation** — detect and assign eligible salmon species using the validated dictionary and deterministic matching rules. Absence of an eligible species term is `NONE`, not an adjudication case. This workflow is deterministic and does not perform geography coding.
7. **Workflow 06 — geography coding** — assign substantive study geography from titles and abstracts using the locked semantic geography classifier. Deterministic gazetteer output is retained as a QC/audit layer rather than the definitive classifier.
8. **Workflow 07 — topic coding** — assign substantive topic codes according to the validated salmon topic ontology and model-voting procedure.
9. **Workflow 08 — human adjudication** — resolve genuinely unresolved content/annotation cases carried forward from Workflows 04, 05, 06 and 07. Uncertainty must not be silently forced into a final class upstream.
10. **Workflow 09 — documentation / output summary** — produce reproducible workflow summaries, provenance reports, database-contribution results, methods outputs and other documentation from the accepted upstream states.
11. **Workflow 10 — dashboard construction** — build the user-facing Living Evidence Map dashboard from the accepted final analytical outputs.

Dataset construction and publication occur from validated accepted workflow states. The authoritative registered Zenodo checkpoint remains the durable source of truth between major stages.


## Current Lens refresh

The current update is a reproduction of the established Lens update workflow in this repository. The update-specific inputs and outputs are stored under `data/updates/2026-08-13_lens/`.

The current refresh does **not** unnecessarily rerun expensive full-corpus LLM work where the established decisions/methods already provide the validated basis. Small API integration tests are nevertheless required for each LLM-dependent stage, including screening, species/geography adjudication, and topics. The topic stage therefore remains in the pipeline and is explicitly tested even though the full topic corpus is not reprocessed during this refresh.

## Deduplication versus screening reference data

The existing evidence-map corpus is the reference for determining whether an incoming record is already represented in the map. Screening include/exclude decisions are a separate resource used by the established relevance-screening workflow. They must not be treated as the deduplication corpus.

## LLM and human-adjudication policy

The pipeline contains two distinct human-adjudication gates.

**Workflow 01 deduplication adjudication** resolves uncertain publication identity before canonicalisation. It is blocking: Workflow 01 must not publish a new canonical state while any required duplicate decision remains unresolved. These cases are not forwarded to Workflow 08.

**Workflow 08 downstream adjudication** consolidates unresolved content and annotation cases produced after canonicalisation, specifically from Workflow 04 relevance screening, Workflow 05 deterministic species annotation, Workflow 06 geography coding and Workflow 07 topic coding. Those upstream workflows should expose uncertainty explicitly in machine-readable queues/layers rather than silently forcing a final decision.

LLM adjudication remains downstream of deterministic rules or annotation where applicable. Decisions and supporting evidence must remain auditable, and unresolved cases must remain explicit until the appropriate adjudication gate resolves them.

## Target isolation

Every stage must receive an explicit target configuration. A stage must fail if required target inputs are absent or if an input contains records outside the requested target without an explicit, documented reason.

## Porting policy

The legacy repository provides implementation provenance. Methods are ported selectively and should remain scientifically equivalent unless a deliberate change is documented and tested. No production stage should read from or otherwise depend on the legacy repository.


## Validated-state handoff

Between validated workflow stages, the durable registered Zenodo state is authoritative. A downstream workflow may preferentially consume a live GitHub Actions handoff artefact when that artefact is tied to the registered upstream run and passes the expected identity/count/checksum validation. Validated handoff caches are normally retained for seven days.

If the handoff cache has expired, is missing or cannot be verified, the downstream workflow restores the same accepted state from the registered Zenodo pointer. The analytical stage receives the same local input regardless of delivery route.

This seven-day handoff policy does not supersede the repository checkpoint policy for costly API/model work. Recovery checkpoints containing expensive generated state are retained for at least 90 days.

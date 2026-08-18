# Scientific methods

## Overview

The Living Evidence Map is maintained as a reproducible, staged pipeline for identifying, screening and annotating literature relevant to farmed salmon. The pipeline combines deterministic reference-data methods, constrained large language model (LLM) processing, automated validation and regular human quality assurance. Deterministic annotation is kept separate from LLM adjudication so that model-assisted decisions can be distinguished from rule-based assignments.

## Species annotation

Species annotation is performed using a curated salmonid species dictionary and predefined matching and assignment rules. Taxonomic mentions are detected in titles and abstracts and normalised to the permitted farmed salmonid categories. Rules distinguish eligible farmed salmonids from non-target species and incidental mentions. Where the available text does not support a sufficiently specific species-level assignment, the record is retained at the appropriate broader category or flagged for adjudication according to the configured rules.

## Geographic annotation

Geographic annotation uses a curated gazetteer to identify place names and map them to standardised country and regional identifiers. Matching follows the configured longest-match and precedence rules. Candidate primary study countries are derived from the geographic evidence and assigned using a predefined evidence hierarchy that prioritises evidence most directly identifying the study location and substantive study entities. Cases in which the evidence is insufficient or competing assignments remain are flagged rather than resolved by unsupported inference.

## LLM adjudication

Species and geographic annotations that meet predefined uncertainty criteria are passed to a separate LLM adjudication stage. The model receives the record title and abstract together with the deterministic annotation and its supporting evidence. It is instructed to consider only the annotation dimension explicitly flagged for review and to select one of three predefined decisions: **ACCEPT**, retaining the deterministic assignment; **CHANGE**, replacing it with an alternative assignment supported by the record; or **UNRESOLVED**, where the available evidence is insufficient for a defensible decision. A concise rationale is also recorded.

Adjudication responses are constrained using structured output so that the model can return only permitted fields and annotation values. Technical or API failures are recorded separately from substantive uncertainty. An API failure therefore does not constitute evidence that an annotation is unresolved. Records remaining unresolved after automated adjudication enter a manual-review queue.

## Topic classification

Research topics are assigned using the versioned salmon topic ontology. The ontology contains three hierarchical levels, with terminal topics accompanied by definitions, relevance criteria and semantic cue terms. The title and abstract are evaluated against the complete set of permitted ontology paths. Multiple topics may be assigned when multiple paths correspond to substantive study objectives, exposures, outcomes, interpretations or applications. Background mentions or isolated lexical occurrences are not sufficient for assignment.

Topic classification uses **GPT-5 mini (OpenAI)** accessed through the **OpenAI Responses API**. The model is instructed to select only from the predefined ontology and returns structured output constrained to permissible topic paths. The classification process is checkpointed at the record level to permit reproducible resumption following interruption. Failed classifications and records explicitly flagged for review are retained outside the validated annotation set until resolved.

## Relevance screening

Relevance screening uses the established salmon screening workflow and associated validated model resources. Screening is performed before species and geographic annotation, thereby limiting downstream annotation to the relevant target corpus. Existing validated screening decisions are retained where appropriate rather than regenerated unnecessarily during incremental updates.

## Human validation and quality assurance

Human validation was an integral component of both the development and ongoing maintenance of the evidence map, rather than being restricted to records that remained unresolved by automated methods. Regular manual data checking was undertaken at both the individual-record and dataset levels to identify erroneous, inconsistent, unexpected or missing screening and annotation assignments, and to assess the plausibility and consistency of outputs across records and successive updates. In addition to reviewing records flagged by deterministic rules, automated validation or LLM processing, manual checking was used to identify systematic patterns of error that might not be captured by record-level uncertainty flags. Findings from these checks informed refinement of the species dictionary, geographic gazetteer, assignment rules, topic ontology and model-assisted workflows where necessary. Human review therefore served two complementary functions: case-level adjudication of uncertain records and broader dataset- and pipeline-level quality assurance. This iterative process of automated processing, regular manual checking and methodological refinement provided an additional safeguard against unsupported model inference and helped maintain consistency and accuracy as the evidence map evolved.

## Incremental updating

The 13 August 2026 Lens update was processed incrementally. Incoming records were cleaned and deduplicated within the new corpus and against the existing evidence-map corpus, filtered for publication status, screened for relevance, annotated for species and geography, adjudicated where required, reviewed manually where unresolved, and topic-classified before construction of a candidate updated master dataset. Existing validated annotations and methods were retained where full-corpus regeneration was unnecessary. Update-specific inputs, outputs, review queues and validation artefacts are retained for provenance.

## Weekly living-map workflow

The production map is designed for weekly incremental updating. Each run retrieves the new Lens increment using a seven-day overlap with the preceding harvest to reduce the probability of missed records caused by indexing or retrieval delays. New records pass through the same processing sequence: import and cleaning; within-corpus and cross-corpus deduplication; publication-status filtering; relevance screening; species and geography annotation; species/geography adjudication; validation and human review; and topic classification.

Automated structural and annotation validation is performed before promotion. If unresolved screening, species, geography, topic or technical review items remain, the candidate dataset is held and the relevant exceptions are resolved before promotion. Following successful validation, the candidate dataset is incorporated into the master evidence map and update-specific provenance and audit outputs are archived. The preceding master version is retained so that changes between updates can be reconstructed.

## Reproducibility and model provenance

For each production update, the repository should retain sufficient provenance to identify the source corpus, update date, reference-data and ontology versions, LLM provider and model identifier for each model-assisted stage, relevant structured-output schema or prompt version, review status, validation status and promoted master version. This information allows model-assisted processing to be distinguished from deterministic annotation and supports reconstruction of update-specific decisions.

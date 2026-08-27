# Updater Pipeline — Workflow 02: deduplication

**Status:** DRAFT IMPLEMENTATION SPECIFICATION
**Scope:** Deduplication of canonical JSONL records against the existing evidence corpus

## Boundary

Workflow 02 receives canonical JSONL from Workflow 01 and returns canonical JSONL with explicit deduplication status/provenance. It does not screen relevance, annotate species/geography, adjudicate those annotations, model topics, construct the master CSV, or update the dashboard.

## Identity versus duplication

`lens_id` is the authoritative identity of a Lens evidence record. A repeated `lens_id` is recorded as an **identity match**. It is not itself treated as evidence that two records are bibliographic duplicates.

DOI is a secondary bibliographic signal only. It must never, on its own, cause a record to be declared a duplicate because some DOI values may be incorrect. DOI agreement must be assessed alongside other bibliographic evidence, and DOI disagreement must not by itself establish non-duplication.

## Deterministic matching order

1. `lens_id` exact identity match.
2. DOI used only as a supporting signal alongside other bibliographic metadata.
3. Strong deterministic bibliographic duplicate rules.
4. Weaker bibliographic candidate generation.
5. LLM adjudication of residual candidates.
6. `uncertain` adjudication results or technical failures requiring human review must stop promotion downstream.

## Existing implementation to preserve conceptually

The current R implementation follows staged Bramer-style bibliographic comparison, with normalisation of title, author, journal, year, volume, issue and pages; two stronger duplicate rules; and five weaker candidate rules before LLM adjudication. The new Workflow 02 should preserve the evidence-based intent of this logic but operate on canonical JSONL rather than RIS/CSV.

## Output principles

Deduplication must not destructively delete records from the canonical evidence history. Each input record remains represented in the output or in a retained audit artefact, with a deduplication decision and provenance.

Suggested statuses include:

- `unique`
- `identity_match`
- `duplicate`
- `duplicate_candidate`
- `not_duplicate`
- `uncertain`

The exact status vocabulary will be finalised during testing.

## Provenance requirements

Record-level provenance should include, where applicable:

- deduplication run ID;
- algorithm/ruleset version;
- decision source (`lens_id`, deterministic rule, LLM, human);
- matched canonical `lens_id` when applicable;
- bibliographic basis/rule;
- supporting DOI signal, if used;
- LLM model/version and rationale when applicable;
- timestamp.

## Legacy corpus

The current 13,389-record master CSV is the authoritative current-state source during migration, but it is not assumed to contain a complete historical JSON/provenance chain. Workflow 02 must support a legacy adapter while canonical historical records are reconstructed. Missing historical decisions must remain unknown rather than inferred.

## Failure handling

The workflow must retain intermediate/audit artefacts and checkpoints. An incomplete run must never silently promote records downstream. LLM/API technical failures are distinct from substantive `uncertain` decisions and must be represented explicitly.

## Current test implementation

The implementation branch initially tests only deterministic semantics using synthetic JSONL records. Before locking Workflow 02, tests must additionally cover:

- real Workflow 01 Lens JSON structure;
- repeated `lens_id` identity matches;
- records with the same DOI but different bibliographic metadata;
- records with different DOIs but strong bibliographic agreement;
- missing DOI;
- incorrect DOI scenarios;
- strong deterministic duplicate rules;
- residual-candidate generation;
- LLM adjudication and uncertainty handling;
- artefact retention and restart behaviour.

## Downstream contract

Workflow 03 may assume that every retained canonical record has:

1. complete Lens source payload;
2. authoritative `lens_id`;
3. explicit deduplication status;
4. decision provenance;
5. no unresolved deduplication uncertainty unless Workflow 03 explicitly consumes a human-approved resolution artefact.

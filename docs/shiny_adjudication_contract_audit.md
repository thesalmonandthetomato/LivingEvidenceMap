# Shiny adjudication contract audit: W01, W02 and W08

Branch: `shiny-adjudication-interface`

Status: read-only audit of existing adjudication contracts. No existing workflow or production file was modified.

## Workflow 01

### Current adjudication case output

W01 builds duplicate-review cases with:

- `scripts/updater/workflow_01_build_duplicate_adjudication_cases.R`
- output: `outputs/adjudication/cases.jsonl`
- schema: `living-evidence-map-workflow01-duplicate-adjudication-case-v1`

Each case contains:

- `review_case_id` (stable SHA-derived ID)
- `pair_key`
- `record_i`
- `record_j`
- `deterministic_evidence`

Each record contains source ID, title, abstract, keywords, journal, year, authors, volume, issue, pages and DOI.

Deterministic evidence can include title similarity, containment, exact-title/abstract flags, ordered coverage, shingle containment, classifier decision/rule, identifier conflict and preprint status.

The case builder also creates a manifest containing hashes of the source review pairs, metadata and generated cases.

### Existing human decision return contract

W01 resumes through `.github/workflows/workflow_01_resume_after_human_review.yml`.

The workflow accepts:

- a pre-adjudication checkpoint pointer
- `decisions_path`: completed human duplicate decisions JSONL
- optional `repairs_path`: data-quality repair actions JSONL

The submitted state is normalised by:

- `workflow_01_migrate_human_review_state.R`

and integrity-gated by:

- `workflow_01_validate_human_review_state.R`

### W01 decision vocabulary

Valid human duplicate decisions are exactly:

- `duplicate`
- `not_duplicate`
- `uncertain`

A complete resume is rejected if any case is missing or remains `uncertain`.

Each decision must contain:

- `review_case_id`
- `decision`
- `rationale`
- `reviewer`
- `resolved_at_utc`
- queue SHA-256 after normalisation

### W01 repair vocabulary

Optional repair actions are:

- `strip_abstract`
- `replace_abstract`
- `set_doi`
- `set_title`
- `set_canonical_preference`

Repairs are constrained to one of the two source records in the adjudication pair and must carry reason, reviewer identity and timestamp.

### Shiny implication

W01 can be supported without changing W01 itself. The Shiny adapter only needs to:

1. expose the locked W01 human-review queue;
2. write decisions in the existing JSONL schema;
3. optionally write repair actions in the existing repair JSONL schema;
4. recreate the exact completed files expected by the existing resume workflow.

The W01 side-by-side duplicate UI maps naturally onto the existing case format.

---

## Workflow 02

### Current adjudication case output

W02 production builds a blocking review package with:

- `scripts/updater/workflow_02_build_human_review.R`

It writes:

- `workflow02_human_review.csv`
- `workflow02_human_review.jsonl`
- `workflow02_human_review_manifest.json`
- `status.json`

The production workflow stops when blocking quarantined conflicts exist.

Each CSV review row contains:

- `record_id`
- `doi`
- `canonical_title`
- `provider`
- `field`
- `reason`
- `provider_title`
- `title_similarity`
- `returned_doi`
- `eid`
- empty `human_decision`
- empty `human_note`

The JSONL adds fuller canonical context, conflict details and provider response.

The manifest hashes both the source canonical input and enrichment audit as well as the review outputs.

### Additional quarantine review rendering

A separate review renderer exists:

- `workflow_02_render_quarantine_review.R`

For the known title-mismatch quarantine it calculates and exposes:

- normalised title similarity
- token Jaccard
- token containment
- title containment
- proposed class
- provider abstract

This is useful evidence for a Shiny comparison view.

### Important gap found

Unlike W01 and W08, the current audited W02 production architecture does **not** contain an explicit generic human-decision ingestion/resume contract.

The production workflow creates the human-review package and intentionally stops. The updater scripts contain builders/renderers and generic patch application, but no W02 equivalent of the W01 human decision validator or W08 decision expander was found.

Therefore we must not invent an existing return contract.

### Shiny implication

The outbound side can be implemented without touching W02.

For the inbound side, the safest minimal design is a **new sidecar W02 reviewed-decision adapter** that:

1. reads Shiny/Google-Sheets decisions;
2. validates them against the locked W02 review manifest and source hashes;
3. converts approved decisions into the same canonical patch/audit structures that W02 already knows how to apply;
4. invokes existing generic W02 patch machinery without altering `workflow_02_production.yml`.

The exact W02 decision vocabulary should be defined only after tracing the enrichment quarantine types and determining how each accepted/rejected candidate should map onto existing W02 patch actions.

No existing W02 workflow file needs to be modified merely to build the UI.

---

## Workflow 08

### Current adjudication case output

W08 already has the strongest frozen-batch design.

`workflow_08_build_review_queue.R` produces:

- `workflow08_review_queue.jsonl`
- `workflow08_review_queue_manifest.json`
- issue index/count QA files
- SHA-256 locked queue identity

Each queue record contains:

- `record_id`
- `record_sequence`
- full `title`
- full `abstract`
- one or more `issues`

Each issue contains:

- `source_workflow`
- `issue_type`
- `automated_value`
- `allowed_human_outcomes`

The current issue types are:

- `species_none`
- `geography_unresolved`
- `geography_evidence_unvalidated`
- `topic_extreme_disagreement`
- `zero_topic_eligibility_uncertain`

### Current W08 allowed outcomes

#### species_none

- `assign_named_species`
- `assign_unspecified_species`
- `exclude_record`

#### geography_unresolved

- `assign_country_set`
- `assign_none`

#### geography_evidence_unvalidated

- `accept_model`
- `override_country_set`
- `assign_none`

#### topic_extreme_disagreement

- `accept_retained_topics`
- `replace_topic_set`
- `exclude_record`

#### zero_topic_eligibility_uncertain

- `include_uncoded`
- `exclude_record`

### Existing W08 decision schema

Each decision uses:

- `review_key = <record_id>::<issue_type>`
- `record_id`
- `issue_type`
- `decision`
- `final_value`
- `rationale`
- `reviewer`
- `resolved_at_utc`
- `queue_sha256`

The queue SHA is checked before finalisation.

The finalisation path expands/validates decisions and requires complete decision coverage before assembling the canonical dataset.

### Shiny implication

W08 is already almost Shiny-ready. The Shiny app can render the locked JSONL directly through an adapter and recreate the existing `human_decisions.jsonl` contract exactly.

No W08 workflow change is required for the core human-decision format.

---

## Minimum generic Shiny case model

The audit suggests using a thin wrapper rather than replacing workflow-native schemas.

A generic Shiny batch should carry:

- `batch_id`
- `workflow`
- `case_type`
- `case_id`
- `source_hash`
- `payload` (the immutable workflow-native case)
- `allowed_decisions`
- `display_config`

The workflow-native payload should remain intact so round-trip conversion is lossless.

Suggested first case renderers:

1. `duplicate_pair` for W01
2. `metadata_conflict` for W02
3. `record_issue_set` for W08

Google Sheets should store only the decision/audit layer, not flattened scientific records.

## Recommended next implementation step

Build the **generic Shiny-side schema and local prototype using W01 first**, because W01 already has:

- a rich side-by-side case format;
- stable case IDs;
- a locked queue hash;
- a complete decision vocabulary;
- a validated return contract.

The prototype should initially read a small frozen W01 JSONL sample and save decisions to a local mock decision store. This lets the UI and round-trip adapter be validated before Google Sheets credentials or shinyapps.io deployment are introduced.

After W01 round-trip validation passes, add the Google Sheets storage adapter, then W08, then design the new W02 sidecar return adapter.

No existing workflow files should be modified during this stage.

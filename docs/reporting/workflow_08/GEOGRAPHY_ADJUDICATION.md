# Workflow 08 geography adjudication

Human geography decisions are stored here because Workflow 06 is an automated coding and QC stage. Workflow 08 applies human decisions on top of W06 without rewriting the W06 automated result.

The current geography decision layer is:

`data/workflow08/geography_adjudication_decisions.jsonl`

Each decision records:

- `record_id`;
- source workflow;
- issue type;
- automated W06 status and country set;
- human decision (`accept_model` or `override`);
- final adjudicated status and country set;
- rationale; and
- decision date.

The current batch includes six explicitly reviewed records from the Workflow 06 validation exercise on 27 September 2026. These decisions should be applied during Workflow 08 and then incorporated into the final post-W08 JSONL layer assembly.

Deterministic/semantic disagreement alone is not a mandatory W08 review trigger. The routine W08 geography escalation set is limited to W06 records that remain unresolved, structurally invalid, failed after retry, or ungrounded after automatic validation. Additional disagreement cases may be reviewed opportunistically as validation samples.


## Workflow 05 species NONE review queue

Workflow 05 is deterministic and does not itself perform semantic adjudication. However, a record retained by Workflow 04 should not ordinarily remain with a terminal species state of `NONE`.

The validated W05 baseline contains **169 records** with `farmed_species_codes = NONE`. These records are therefore added to Workflow 08 for human review.

The exact baseline record IDs are stored in:

`data/workflow08/species_none_review_queue_ids.txt`

Queue provenance:

- source workflow: Workflow 05;
- source run: `36268840588`;
- source commit: `636428716c0a2e66431720dbffaf392e688b5b56`;
- W05 Zenodo record: `22982751`;
- W05 species-layer SHA-256: `85f4003d3835535f6ab1c50691c79159640448642bb7b20974d58856dab44cdf`;
- queue size: **169 records**.

For adjudication, each queued record should be joined to its title and abstract from the authoritative canonical record and reviewed for one of three outcomes:

1. assign one or more eligible named species;
2. assign `Unspecified species` where salmon/trout aquaculture relevance is clear but species cannot be resolved more specifically from the available text; or
3. flag a relevance problem for human exclusion review where the record does not actually satisfy the map eligibility criteria.

The W05 automated layer remains unchanged. Any human species decision is stored as a Workflow 08 layer and applied during final post-W08 assembly.

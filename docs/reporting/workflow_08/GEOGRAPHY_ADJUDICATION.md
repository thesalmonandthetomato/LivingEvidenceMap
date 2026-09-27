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

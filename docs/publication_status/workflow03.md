# Workflow 03: publication-status surveillance

## Purpose

Workflow 03 converts the authoritative post-Workflow-02 canonical corpus into a lean work-level representation and maintains publication-status evidence for each stable canonical `record_id`.

The initialisation checkpoint contains 32,292 canonical works and replaces 90,137 embedded manifestation objects with exact lightweight `manifestation_refs`. Full manifestation metadata remains preserved in immutable Workflow 01 state.

Publication status is stored as a sparse layer rather than rewriting the canonical corpus.

## Authoritative initial input

- Post-Workflow-02 canonical SHA-256: `4229257bca67c1ff1ebec4b3642ff9df4ac83d9eae99b584b15cbc9c49845902`
- Lean canonical SHA-256: `1d3977537c1498a728c9fe04ff958874f4a7727ad344a02ba3ef00adb2f755c7`
- Canonical records: 32,292
- Manifestation references: 90,137
- Lean checkpoint Zenodo record: `10.5281/zenodo.22964354`
- Validated compaction run: `36166883249`

The historical checkpoint receipt retains its original Workflow 02 label because it was published before compaction was formally assigned to Workflow 03. This is preserved as provenance rather than rewritten.

## Detection evidence

Workflow 03 uses two independent evidence channels:

1. OpenAlex publication-status metadata, including `is_retracted` and work type.
2. Conservative title-prefix detection for explicit notices.

Generic prefixes such as “notice”, “warning”, “update”, “comment on”, “response to” and “reply to” are not treated as publication-status evidence.

## Definitive analytical vocabulary

The allowed publication-status codes are:

- `normal`
- `retracted`
- `withdrawn`
- `corrected`
- `expression_of_concern`
- `warning`

Deterministic precedence is:

`retracted > withdrawn > expression_of_concern > warning > corrected > normal`

Multiple positive signals are retained in the evidence object. They are not considered unresolved conflicts when precedence produces a definitive code. For example, OpenAlex `is_retracted=true` plus a title beginning “Withdrawn” resolves automatically to `retracted`.

## Workflow 04 eligibility

`exclude_from_workflow04=true` only for:

- `retracted`
- `withdrawn`

All other publication-status codes remain eligible.

Workflow 04 consumes this field directly and must not rerun publication-status inference.

## Initial full production sweep

Authoritative corrected production run:

- GitHub Actions run: `36172718538`
- Records checked: 32,292
- Records excluded from Workflow 04: 9
- Unresolved evidence conflicts: 0

The sparse `publication_status.jsonl` layer from this run is archived separately to restricted Zenodo and registered under `docs/publication_status/zenodo/`.

## Scheduled operation

### Fortnightly updater

New canonical additions pass through Workflow 03 before Workflow 04. Existing unchanged publication-status state is carried forward.

### Quarterly full sweep

The quarterly process begins at Workflow 03 and rechecks publication status for all canonical works.

- If there are no status changes, stop.
- If changes are non-exclusionary (`corrected`, `warning`, `expression_of_concern`, or return to `normal`), update/archive/register the Workflow 03 layer and trigger Workflow 08 so the canonical output, flattened CSV and dashboard are rebuilt.
- If any work becomes `retracted` or `withdrawn`, update/archive/register the Workflow 03 layer, exclude the affected `record_id` values, and trigger Workflow 04 and subsequent workflows. Workflow 08 rebuild occurs automatically at the end of that downstream chain.

## Provenance rule

Actions artifacts are temporary execution artefacts. An authoritative Workflow 03 state is only complete after:

1. full validation passes;
2. the sparse state is archived to restricted Zenodo;
3. SHA-256 and source GitHub run are recorded;
4. the Zenodo receipt is committed to `docs/publication_status/zenodo/`;
5. the registry is updated.

Historical archives and receipts are immutable.


## Validated-state handoff

Workflow 03 follows the repository-wide validated-state handoff policy.

The lean canonical input is preferentially restored from the seven-day post-Workflow-02 handoff artefact when its SHA-256 matches the registered lean-checkpoint pointer. If the artefact is unavailable or fails verification, the same lean canonical state is restored from the restricted Zenodo checkpoint.

After a validated full publication-status run, Workflow 03 exposes the lean canonical JSONL, publication-status layer and validation report as a seven-day handoff artefact for Workflow 04. Workflow 04 uses that artefact only when both the lean-canonical SHA-256 and publication-status-layer SHA-256 match the registered authoritative pointers; otherwise it restores both inputs from Zenodo.

The durable Zenodo state remains authoritative. The Actions artefact is a temporary cache only.

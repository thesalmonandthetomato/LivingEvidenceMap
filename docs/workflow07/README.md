# Workflow 07 — topic coding

Workflow 07 assigns substantive topic pathways using three independent GPT-5.6 Luna passes and the frozen v3.6 ontology.

## Production classifier

Frozen scientific resources:

- `data/reference/topic_ontology_v3_6.csv`
- `data/reference/topic_system_prompt_v3_6.txt`
- `R/run_topic_three_luna_production.R`

They are copied from the validated historical three-Luna production state and must retain these SHA-256 values:

- ontology: `5d78959f86d40f200f7dc7c3184a2d5ab61fd89d1450be7fbff39c2578246a43`
- prompt: `f038a0c04a4a897ee806b36912bb3bf22a7d80040100489cf5a8a3659e56bec0`

Each record receives three independent Luna classifications. Every returned pathway is retained with:

- 1/3 votes = ★
- 2/3 votes = ★★
- 3/3 votes = ★★★

The individual pass roles and reasons are retained.

## Input modes

`.github/workflows/workflow_07_topic_coding.yml` supports two input modes.

### `recall_uncoded`

Bootstrap/current production mode. It restores the validated topic-recall audit and codes only records with no reusable historical three-Luna result.

Current validated recall audit:

- included corpus: 19,407 records
- recalled historical three-Luna records: 12,297
- fresh coding queue: 7,110

After fresh coding, recalled and fresh pathway scores are merged and validated into one 19,407-record Workflow 07 handoff.

### `workflow06_all`

Normal full-handoff mode. Given an accepted Workflow 06 run ID, Workflow 07 restores the Workflow 06 geography production artefact, takes its canonical `record_id`, title and abstract fields, and submits the full Workflow 06 population for three-Luna topic coding.

This mode is intended for future full reruns or when reuse is deliberately bypassed.

## Recovery

Topic calls use the OpenAI Batch API in 500-record chunks. Batch submission state and validated chunk output are stored as 90-day GitHub Actions artefacts. Re-running a failed matrix job first attempts to restore the same-run batch ID/output so completed or submitted model work is not duplicated.

## Handoff

The final artefact is named:

`workflow07-topic-handoff-<run_id>`

It contains the fresh three-pass production files plus:

- `workflow07_topic_pathway_scores.csv`
- `workflow07_topic_record_summary.csv`
- `workflow07_zero_code_records.csv`
- `workflow07_star_counts.csv`
- `workflow07_final_summary.json`
- `WORKFLOW07_HANDOFF_PASS.ok`

Workflow 08 should consume the validated Workflow 07 handoff rather than transient per-chunk artefacts.

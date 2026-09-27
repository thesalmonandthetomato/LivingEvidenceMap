# Workflow 07 - topic coding

Workflow 07 assigns substantive topic pathways using three independent GPT-5.6 Luna passes and the frozen v3.6 ontology, then performs topic-specific quality control before handoff to Workflow 08.

The full methodological report is:

`docs/reporting/workflow_07/workflow_07_functionality_map.md`

Baseline-establishment and diagnostic actions are recorded separately in:

`docs/reporting/workflow_07/AD_HOC_ACTIONS.md`

## Frozen production resources

- `data/reference/topic_ontology_v3_6.csv`
- ontology SHA-256: `5d78959f86d40f200f7dc7c3184a2d5ab61fd89d1450be7fbff39c2578246a43`
- `data/reference/topic_system_prompt_v3_6.txt`
- prompt SHA-256: `f038a0c04a4a897ee806b36912bb3bf22a7d80040100489cf5a8a3659e56bec0`

Each record receives three independent Luna classifications. Raw pathway assignments are preserved with 1/3, 2/3 or 3/3 support.

## Final QC

Before Workflow 08 handoff, Workflow 07:

1. applies documented ontology fallback/general-code pruning only to the analytical layer;
2. applies the complete-star-tier soft maximum of ten topics;
3. re-screens zero-topic records specifically for salmon/rainbow-trout farming eligibility;
4. retains consensus-eligible zero-topic records as included but uncoded;
5. records consensus-ineligible zero-topic records as late automatic exclusions;
6. sends unresolved zero-topic eligibility to Workflow 08;
7. sends records with mean pairwise three-pass Jaccard <0.20 to Workflow 08.

For the current baseline, the zero-topic rescreen returned 217 include, 123 exclude and 18 uncertain from 358 zero-topic records. A further 103 records meet the extreme-disagreement rule, giving 121 W07 human-review records.

Workflow 08 consumes the validated final W07 handoff. Raw W07 model outputs and the historical W04 screening decision remain preserved.

# W11 pilot: W07 topic alignment against full text

## Purpose
Test whether topic classification supported by the study's **objectives, methods and results** agrees with W07's existing **title-and-abstract** topic coding. Do not treat either set as a gold standard and do not overwrite W07 or existing full-text v3 coding.

## Frozen ontology
Use W07 production `topic_ontology_v3_6.csv`, SHA-256 `5d78959f86d40f200f7dc7c3184a2d5ab61fd89d1450be7fbff39c2578246a43`; do not silently reuse the old full-text pilot's `topic_ontology_v3.csv`. Obtain the actual frozen v3.6 file from the established W07 production artefact or verified repository source, never reconstruct ontology rows or vocabulary. W07's three-pass scores must be retained as-is.

## Small pilot sample (10 included records)
Choose 10 records with uniquely verified canonical identity and archived GROBID XML. Stratify by W07 abstract topic support: three high-consensus (3/3), three mixed-consensus (2/3 or 1/3), two multi-topic, and two W07 zero-topic records where suitable. Prefer variation in study methods and topic hierarchy; avoid selecting from ambiguous DOI joins. Freeze the record IDs, XML SHA256, W07 topic support and sampling rationale before issuing model calls.

## LLM task
For this experiment, make one **separate topic-only** OpenAI call per full text. Include the actual study's objectives (where stated), methods and results as the primary evidence. The Introduction and Discussion may help interpretation but must not justify a code without substantive supporting objectives/methods/results. Use only the **frozen W07 v3.6 leaf pathway codes**. Exclude literature reviews' cited studies; consider their own synthesis objectives/findings where appropriate. A topic mentioned merely in background or interpretation is insufficient. Do not show the model the existing W07 assignments, support scores, or comparison results.

Return a machine-readable JSON object:
```json
{
  "canonical_record_id": "record ID from input",
  "ontology_version": "v3.6",
  "topic_assignments": [
    {"path_id": "V3_000", "objective_evidence": "...", "methods_evidence": "...", "results_evidence": "...", "basis": "substantive study focus"}
  ],
  "unable_to_assess": false,
  "limitations": []
}
```
`V3_000` above is only a schema example, **not** a permitted ontology assignment. Validate codes against the frozen CSV. Capture precise source passages/sections and preserve the complete raw model response for audit.

## Paired comparison
Compare both **raw W07 multi-pass support** and the **W07 final retained-for-analysis codes** with full-text codes on the same canonical record ID.

Calculate per study:
- intersection, abstract-only, fulltext-only, exact-set equality;
- Jaccard intersection/union for nonempty union, and a separately reported both-empty case;
- recall of W07 consensus (3/3) codes in the full-text set;
- counts of full-text-only codes, particularly W07 zero-topic articles newly classified;
- agreement by level-1 and level-2 ontology branches (derived strictly from v3.6 paths);
- retained-vs-pruned (fallback) code differences, to avoid interpreting deterministic pruning as model disagreement.

Write a human-review comparison table. Review disagreements against article evidence and classify as abstract omission, full-text overcoding, ontology ambiguity, different study component, or unresolved. **Do not tune the prompt from 10 papers without adjudicating the disagreements.**

## Isolation and cost
Use a dedicated pilot folder and manual workflow only on `W11-full-text-retrieval`. No edits to W07 production resources, canonical records, W08 decisions or W11 acquisition state. Download the 10 source documents for pilot processing only. Preserve each raw response and a recoverable checkpoint before analysis. Do not write experimental coding to the production Google Sheet. The pilot's pass/fail relates to identity verification, schema validity and outputs being comparable, not forcing high agreement.

# LivingEvidenceMap — Full-text coding decision log

This is a concise record of decisions made during the prompt/schema/full-text coding review. It is not intended to reproduce the raw conversation. The current authoritative prompt and schema override historical discussion if any conflict arises.

## 2026-08-27 — Life stage vs production stage

- `harvest` is **not** a fish life stage.
- `Adult grow-out` is an appropriate production stage.
- `production_stage` and `fish_life_stage` remain separate concepts.

## 2026-08-27 — Exposure/intervention

- Use the single combined `exposure_intervention` field.
- Do not resurrect separate legacy exposure/intervention fields.

## 2026-08-27 — Research question/objectives retrieval

- Research question and objectives must not be missed.
- They may be found anywhere in the document; they do not have to come from the abstract or Introduction.
- Abstract/Introduction are useful retrieval locations, but explicit aims/objectives/questions elsewhere are acceptable.

## 2026-08-27 — NOT FOUND and arrays

- `fish_life_stage` can be `NOT FOUND` where the stage does not exist or cannot be supported.
- Do not leave substantive array fields blank.
- For an applicable array field with no evidence after active searching, use `["NOT FOUND"]`.
- Do not over-focus on semantic distinctions between `NOT FOUND` and `NULL`; post-hoc consolidation can handle those where appropriate.

## 2026-08-27 — Life-stage inference from age/mass

- Age and/or mass can support inference only for **Juvenile** or **Adult** when the values match the species-specific farmed growth trajectory.
- Other life stages should be explicit rather than inferred from age/mass.
- Do not infer Egg, Fry, Parr, Pre-smolt, Smolt, Broodstock or Product from age/mass.

## 2026-08-27 — Eligible-species isolation

- When eligible and ineligible species/components occur in the same paper, focus substantive coding on the eligible species/component.
- Ineligible-species settings or facilities must not contaminate the coding of the eligible component.
- `other_farmed_species` may record other species but must not be allowed to contaminate focal fields.

## 2026-08-27 — Comparator

- Do not assume the research is comparing survivors versus mortalities.
- Do not force incidental or non-focal groupings into `comparator`.
- Code the genuine focal comparator only.

## 2026-08-27 — Evidence

- Model-derived interpretation in coding/evidence is not automatically a problem; it is functioning as intended when the prompt requires an inference from source evidence.
- Escalate only demonstrable systematic errors, not ordinary model interpretation that is supported by the article.

## 2026-08-27 — Study design

The current prompt must contain explanations for every permitted study-design label. The controlled labels are:

- `BA`
- `CI`
- `BACI`
- `RCT`
- `Time-series`
- `Modelling`
- `Qualitative`
- `not_stated`
- `not_applicable`

Do not introduce legacy labels.

## 2026-08-27 — Completeness validation

- Array fields must remain arrays.
- Missing substantive array values should be represented as `["NOT FOUND"]`, not blank.
- Completeness validation is currently warning-only/non-fatal in the workflow.
- A validation warning should not be treated as a run failure unless the workflow explicitly fails for another reason.

## 2026-08-27 — Historical 20-study run

- The 20-study run was produced before the final completeness/NOT FOUND prompt tightening.
- Its completeness warnings are therefore expected and should not drive another prompt revision.
- The substantive extraction was broadly usable.

## 2026-08-27 — Ontology reporting

- Ontology codes must be resolved against `data/reference/topic_ontology_v3.csv`.
- Reporting uses the exact hierarchy terminology joined with ` > ` separators.
- Never fabricate ontology mappings.

## 2026-08-27 — Full-text acquisition architecture

- OpenAlex full-text acquisition runs independently and stages GROBID TEI/XML to Zenodo.
- The intended acquisition scale is one batch of up to 100 files per day, with batches 6–40 planned.
- `fulltext_batch_registry.csv` is the provenance bridge between OpenAlex/DOI and Zenodo.

## 2026-08-27 — Zenodo coding architecture

- Process **one Zenodo record at a time**.
- Do not build a giant intermediate full-text corpus solely for coding.
- The existing manual/test AI-coding workflow is wrapped with Zenodo ingestion and provenance.
- The AI-coding workflow is **manual-dispatch only**. Do not add a schedule unless explicitly requested.
- User can start the workflow and stop/cancel it when desired.

## 2026-08-27 — Checkpointing

- Checkpoint after **every individual paper**.
- Persist cumulative coding and provenance before advancing to the next paper.
- GitHub Actions artifacts are retained for 90 days as an additional recovery layer.
- The repository's cumulative JSON files are the durable project record.

## 2026-08-27 — Provenance architecture

Every coded record should be traceable through:

`Zenodo record ID → Zenodo archive filename → Zenodo source filename → OpenAlex ID → DOI → master CSV match → coding run ID`

The cumulative coding file stores the actual annotations; `coding_architecture.json` stores the lightweight provenance/index.

## 2026-08-27 — Resume strategy

When returning after the acquisition period:

1. Read the handover files.
2. Inspect the current prompt/schema/ontology in the repository.
3. Inspect `fulltext_batch_registry.csv` and the cumulative coding architecture.
4. Manually dispatch the Zenodo coding workflow.
5. Pilot across multiple Zenodo records.
6. If stable, allow it to continue through deposited records while monitoring checkpoints.
7. Review coded records against full text after the bulk run.

# Human validation evidence by Workflow 09 flow box

This register assembles the repository evidence for human validation, manual adjudication and human quality assurance that can be represented on the Workflow 09 flow diagram. It is deliberately conservative: a number is classed as **human** only where the repository evidence identifies human/manual decisions or a preserved human-labelled validation set. Automated validation, manual workflow triggering and LLM adjudication are not counted as human validation.

## Recommended diagram counts

| Flow box | Recommended human-validation marker | Basis |
|---|---:|---|
| Deduplicated records | **H 132** | 132 human final pair decisions in the authoritative Workflow 01 state. The same state contains 3,027 adjudicated cases in total, but 2,895 were LLM-final decisions and must not be labelled human. |
| Records screened at title and abstract | **H 17,656; V 800** | 17,656 historical human screening decisions form the preserved validation frame. By the fourth non-overlapping 200-record sample, 800 unique records had been used in blinded validation. The 800 are a subset of the 17,656. |
| Species annotation | **H 169** | 169 production species-none cases received human adjudication in final Workflow 08 QA; 166 were excluded and 3 were assigned named species. |
| Geography annotation | **H 527** | 527 human geography resolutions are recorded by the final manifest: 521 Workflow 08 review records plus 6 pre-baseline human decisions. 518 human-sourced geography decisions remain among final included records after later exclusions. |
| Records entering topic annotation | **H 103 (+20 benchmark)** | 103 production extreme-disagreement topic records were human-adjudicated. Separately, 20 ranked-Luna development benchmark conflicts were manually adjudicated; these should not be added to 103 without proving no overlap. |
| Living Evidence Map | **do not add a separate marker** | Final QA covered 811 issues across 797 unique records, but this overlaps the species, geography and topic counts above and would visually double-count human validation. |

## Screening derivation

The exact historical human-screening frame is **17,656 records**, not merely “about 20,000”. This can be reconstructed from the preserved Workflow 04 validation manifests:

- run 35027233994: sample n = 200, sampling frame = 17,456, prior validation records excluded = 200;
- run 35075669317: sample n = 200, sampling frame = 17,256, prior validation records excluded = 400;
- run 35093862530: sample n = 200, sampling frame = 17,056, prior validation records excluded = 600.

Each gives the same original human-labelled frame: sampling frame + prior excluded = **17,656**. The sequence therefore establishes four non-overlapping 200-record validation samples, or **800 unique validation records** in total by the final run.

## Important distinctions

**Human review is not the same as model adjudication.** The authoritative Workflow 01 deduplication summary contains 3,027 adjudicated pair cases, but only **132** have human final decisions; **2,895** have LLM final decisions.

**Human review is not the same as changing a value.** For species, 169 records were reviewed even though only 3 received named-species assignments. For geography, many human decisions confirmed no geography or accepted the model. For topics, 103 records were reviewed because of extreme model disagreement even when the retained topic set was ultimately accepted.

**Development benchmarks should be kept separate from production QA.** Topic coding has 20 manually adjudicated ranked-Luna benchmark conflicts in addition to the 103 production Workflow 08 topic adjudications. The development set is useful evidence of validation, but it should not be merged into the production count unless record-level overlap is checked.

## Boxes without a defensible human-validation count

No separate record-level human-validation sample is currently documented for the five database retrieval boxes, Combined search results, or the retraction/withdrawal sweep. The Record repair and enrichment stage contains **32 approved data-quality repairs** in Workflow 01, but the stored summary does not explicitly identify the approving actor as human; there is also no systematic human sample validating the **2,190** Workflow 02 enriched records. I therefore recommend **not** assigning a human-validation symbol to enrichment on the present evidence.

Records retained after title and abstract screening is an output of the screening task and should inherit the screening marker rather than receive a second one.

## Primary provenance

- Workflow 01 authoritative pointer: `docs/deduplication/zenodo/run-36128255337.json`; preserved run 36128255337 `delta/target_summary.json`.
- Workflow 04 validation run 35027233994: commit `e3013777ea8692dcda3ad36771200bf2fe9aa08b`.
- Workflow 04 validation run 35075669317: commit `f25ddf2c0ced066bb707fcdd6854740ffafd7d40`.
- Workflow 04 validation run 35093862530: commit `8acb34f260580bf93c237188d62d00ac171684bd`.
- Topic ranked-Luna manual adjudication completion: commit `f41e4cbbd7b0c38de8b21f44e653ea07afa31b2b`.
- Workflow 08 final QA: run `36329841121`, final manifest and adjudication ledger published with the final canonical state.

# Workflow 08 geography adjudication

Workflow 06 is the automated geography-coding and QC stage. Workflow 08 applies human decisions only to the residual cases that cannot be accepted deterministically, while preserving the original W06 result and provenance.

## Current routing

Current production W08 can receive three geography issue types:

- `geography_unresolved`;
- `geography_evidence_unvalidated`; and
- `geography_model_failure`.

A non-failure W06 record with no candidate country may be deterministically assigned geography `NONE` without human review. Invalid model/API outputs, including unrecognised ISO3 codes, are not auto-accepted: they are represented as model failures and routed to W08 human review.

For unresolved or evidence-unvalidated cases, allowed decisions are `accept_model`, `override_country_set`, `assign_none`, or `exclude_record`. For model failures, allowed decisions are `assign_country_set`, `assign_none`, or `exclude_record`.

Human decisions are stored as an overlay and are applied during final W08 assembly; the archived W06 automated layer is not rewritten.

## ISO3 validation

ISO3 is the controlled machine identifier. Future W06 model-returned codes are checked against `config/global_country_gazetteer_v3.csv` before acceptance. An unrecognised code fails the model result and is sent to W08 as `geography_model_failure`.

For valid W06 ISO3 codes, the country display name is derived deterministically from the controlled gazetteer. Raw model-returned names remain in provenance. W08 finalisation validates the final ISO3 vocabulary but does not treat harmless display-name variants such as “The Gambia” versus “Gambia” as code errors.

The October 2026 audit corrected five values in the authoritative release without changing inclusion decisions:

- `INN → IND` for India;
- `NIQ → NIC` for Nicaragua;
- `FIJ → FIN` for Finland;
- `IRE → IRL` for Ireland; and
- removal of `UNK` where it represented the European Community rather than a country.

`XKX` remains intentionally permitted for Kosovo under the current controlled gazetteer policy.

The correction provenance is stored in:

`data/workflow08/geography_code_corrections_2026-10-04.csv`

The corrected authoritative W08 release is GitHub run **37234697766**, Zenodo record **23145712**, DOI `10.5281/zenodo.23145712`.

## Historical note

Earlier development used `data/workflow08/geography_adjudication_decisions.jsonl` for a small validation set and routed Workflow 05 species-`NONE` cases to human review. Those behaviours are historical only. Current production deterministically excludes Workflow 05 species-`NONE` records before W08 human review, and current geography decisions are managed through the checksum-locked W08 decision ledger/Shiny handoff described in `workflow_08_functionality_map.md`.

# Master data: authoritative locations and lifecycle

## Production master

**Authoritative master:**

`data/master/current/living_evidence_map_master.csv`

This is the only file that represents the current LivingEvidenceMap master database. The dashboard and weekly update pipeline must read this file.

## Updates

Incoming and intermediate material is stored under:

- `data/updates/YYYY-MM-DD_lens/` — weekly Lens update inputs and processing outputs
- `data/assignments/` — active assignment/review material
- `data/manual_input/` — deliberate human-supplied inputs

These are not master data.

## Archive

Previous masters are stored under:

`data/master/archive/`

Other historical working material is under `data/archive/`.

Archive files are retained for provenance and recovery and must never silently become dashboard or pipeline inputs.

## Promotion rule

A candidate master is created under `data/master/candidates/`. Only after validation succeeds is the previous production master copied to `data/master/archive/` and the candidate promoted to `data/master/current/living_evidence_map_master.csv`.

Each promotion must include a dated manifest.

## Legacy location

`data/reference/salmon_evidence_map.csv` was the former master location. It is being retired specifically to prevent ambiguity. It must not be recreated as a second master.

The ontology remains a reference/configuration input at:

`data/reference/topic_ontology_v3.csv`

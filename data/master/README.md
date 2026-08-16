# LivingEvidenceMap master data

This directory is the **authoritative production master** for the LivingEvidenceMap.

## Current master

`current/living_evidence_map_master.csv`

There is exactly one production master. Dashboard builds, validation and weekly updates must read this file. Do not use files in `data/reference/` as the master.

## Archive

`archive/` contains dated snapshots of previous promoted masters and historical working files retained for provenance. Archive files are never inputs to the production dashboard or weekly update unless a workflow explicitly requests a historical snapshot.

## Update rule

Every successful master promotion must:

1. validate the candidate master;
2. archive the previous production master with an ISO date/time or update date;
3. promote the new master to `current/living_evidence_map_master.csv`;
4. write a manifest recording source files, row count and validation results;
5. commit the current master and archive together.

## Do not upload working files here

Incoming RIS files, LLM queues, topic-recovery outputs, manual-review files and intermediate candidates belong under `data/updates/`, `data/assignments/`, `data/manual_input/` or `data/archive/` as appropriate. They are not authoritative master data.

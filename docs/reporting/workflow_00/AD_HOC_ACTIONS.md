# Workflow 00: ad hoc actions and baseline-establishment log

## Purpose

This document records non-routine actions used while validating and consolidating Workflow 00. These actions are not part of the production search methodology. The production workflow is described in `workflow_00_functionality_map.md`.

## Validation and recovery actions

Workflow 00 was developed and validated source-by-source before consolidation. Exact validated recovery points were preserved on frozen branches for Lens, Scopus, OpenAlex, AGRICOLA and Web of Science, together with a validated orchestrator state.

Earlier combined full-search attempts contained source-specific failures. Completed source harvests were preserved and failed source jobs were recovered without repeating successful source work.

The final validated five-source behaviour was recorded on 22 September 2026. Key validation runs were:

- five-source fortnightly integration: `35764618096`;
- OpenAlex fortnightly current-year plus next-year optimisation: `35769376886`;
- all-five-source expansion integration: `35774020363`.

The final validated orchestration head was `a9dbf4df826c6b3552a066377049c03afc525861`.

## Source-specific implementation recovery points

The validated source implementations were preserved on frozen source branches so the production pipeline could be reconstructed exactly if required. These frozen branches and commit points are recovery aids, not workflow stages.

## Reporting rule

For Workflow 09 and manuscript methods, describe only the search orchestration, source-specific query execution, provenance capture, run modes and durable archival defined in `workflow_00_functionality_map.md`.

Do not describe failed combined runs, branch recovery, source-specific development branches or one-off consolidation work as normal Workflow 00 behaviour.

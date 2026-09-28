# Workflow 00 state

`current.json` is the authoritative logical Workflow 00 state consumed by Workflow 01.

A state identifies exactly one accepted source state for each of the five bibliographic sources: Lens, Scopus, OpenAlex, AGRICOLA and Web of Science. Source harvests remain immutable in restricted Zenodo archives. The state file references those archives and their source-specific SHA-256 checksums rather than duplicating archived data.

The initial state, `baseline-v1.json`, reconstructs the accepted five-source baseline from three existing Zenodo records:

- Lens, OpenAlex and Web of Science: Workflow 00 run 35730574878, Zenodo 22921060
- Scopus: Workflow 00 run 35731899007, Zenodo 22925311
- AGRICOLA: Workflow 00 run 35735412308, Zenodo 22920797

`scripts/updater/workflow_00_validate_state.R` must pass before a state is consumed. It requires exactly the five expected sources, valid archive metadata and checksums, and non-empty duplicate-free native-ID registries.

Automatic promotion of future fortnightly or expansion harvests into `current.json` is intentionally not enabled until source-native ID reconciliation is consistently applied to update harvests. This prevents a delta archive from being incorrectly represented as a complete source state.

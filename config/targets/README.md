# Target configuration

Each target gets its own YAML file in this directory.

A target configuration should define, at minimum:

- `target_id`
- corpus input path
- reference/dictionary inputs
- output namespace
- target-specific metadata needed for reproducibility

Example target IDs include `MASTER` and `UPDATE_2026-08-12`.

Scripts must resolve all target-dependent paths through this configuration rather than hard-coding filenames.

# User input

This directory contains user-editable inputs that define the topic-specific behaviour of the Living Evidence Map pipeline.

## Workflow 00 search strategy

`workflow00_search_strategy.json` is the authoritative conceptual search definition for Workflow 00. Workflow code must generate source-specific queries from this file rather than maintaining independent topic-specific search strings in workflow or script files.

The current configuration retains the validated salmon-farming search concepts. Future topic adaptations should replace the user input while leaving the Workflow 00 orchestration and source handlers unchanged.

Other genuinely user-editable pipeline inputs, such as prompts used by downstream workflows, may be moved here later after their interfaces are reviewed.

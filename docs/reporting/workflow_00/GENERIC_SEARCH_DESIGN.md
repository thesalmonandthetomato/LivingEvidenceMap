# W00 generic search strategy: draft contract

**Status:** architecture implemented in the inert reconstruction branch; unvalidated and not ready for live queries.

The authoritative file remains `user_input/workflow00_search_strategy.json`. A generic example is available in `user_input/workflow00_search_strategy.example.json`. The existing salmon-specific input remains unchanged until the new translation can be compared against accepted search strings.

## Supported input forms

- **Named concepts:** `concepts` is a map of identifiers to term arrays, combined with an explicit `expression` using AND, OR, NOT and parentheses. Concept names are not tied to scientific topics.
- **Advanced Boolean:** `advanced_boolean` preserves a fully authored expression. Because cross-provider equivalence cannot be assumed, each database requires an explicit override.
- **Database override:** `database_overrides.<source>` supplies an explicit, provider-specific complete query. For OpenAlex OQL this is required unless a verified translator is implemented.
- **Expansion:** the operator supplies `--expansion-target` (exactly one named concept) and `--additional-search-term` (one new term or substring) in expansion mode. The translation returns records satisfying the amended complete expression but not the original complete expression. Multiple targets per run are not supported.
- **Fortnightly:** currently requires explicit `fortnightly_overrides` for the generic path; automatic cross-provider date semantics must be verified before this requirement can be relaxed.

## Separation of responsibilities

1. Store the original search definition under `user_input/`.
2. Validate Boolean syntax offline with `workflow_00_validate_search_strategy.R`; no topic terms are required.
3. Translate offline with `workflow_00_translate_generic.R`, refusing unsupported provider syntax or unsafe equivalence.
4. Write a per-run search archive with `workflow_00_archive_queries.R`.
5. Dispatch translated queries through existing source adapters. The Lens adapter now constructs request JSON from the translated query and does not require a salmonid clause or a sentinel record.

**Not yet implemented:** complete concept grammar validation, syntax-aware proximity translations, archive-to-harvester checksum enforcement, immutable durable archive publication, and complete source-specific modes. Do not reactivate the workflow definitions before those are addressed and validation is authorised.

## Implementation update: archived-query handoff

The reconstruction now builds the per-run archive **after source selection**, writes it into the W00 plan artefact at `outputs/updater/workflow00_plan/search_archive/run-<run-id>/`, then uses `workflow_00_read_archived_queries.R` to reload the exact selected database query strings and verify file SHA-256 checksums before exporting the source dispatch matrix. This removes a competing plan-based dispatch path.

For legacy inputs, the existing W00 translator is still used to preserve the established search meaning. The generic translator is selected for concept-mode and advanced-mode input, and translates **only selected databases**. Unsupported translation, including OpenAlex when no explicit override is given, fails with an actionable error rather than silently substituting semantics.

**Outstanding:** persist the short-lived archive in a durable location beyond the Actions artefact's current retention; finalise source-specific fortnightly query semantics; strengthen the full Boolean parser and assess each provider's syntax; confirm that archive manifests and retrieval reports remain linked across run completion; and validate before any workflow activation. None of these actions has been run or tested on production.

## Durable publication preflight

The existing W00 Zenodo archiver already deposits the complete `plan/` directory as part of its search-documentation tarball. The archive now contains `plan/search_archive/run-<run-id>/` alongside the source-selection and search-plan files. Before any Zenodo deposition is created, `workflow_00_archive_to_zenodo.R` requires the per-run query manifest and checks the original strategy SHA-256, selected source coverage and each selected query checksum. The durable archive manifest records the query-manifest hash, strategy hash and translation identifier.

For generic concept-mode search translation, source selection is supplied first and only selected providers are translated. Unverified OpenAlex translations require a source-specific override. If a source uses a fixed override during expansion, a distinct `expansion_overrides.<source>` is required. Fortnightly generic queries still require verified `fortnightly_overrides` for the selected providers; native provider date semantics remain to be reviewed.

**Important caveat:** This implements the archive-provenance code path only; no validation, repository Actions execution or Zenodo deposition has been performed. Translation correctness and retrieval-to-archive integrity remain unverified, and some legacy input formats continue to use the historical translator.

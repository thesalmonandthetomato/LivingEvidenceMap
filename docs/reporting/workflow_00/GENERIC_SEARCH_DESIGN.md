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

# Salmon farming baseline equivalence audit

Status: **STATIC REVIEW ONLY — not validated by an R execution or API request.**
Branch: `production-minimal`; baseline `workflow01-final-architecture` search structure inspected via the retained legacy W00 orchestrator. No production branch modified.

## Canonical input

`user_input/workflow00_search_strategy.json` (search version `v1`) has two blocks:

- **species:** `salmon`, `salmonid*`, `Salmo`, `Oncorhynchus`, `"rainbow trout"`
- **farming:** `farm*`, `cage*`, `pens`, `penned`, `pen`, `aquacultur*`, `commercial*`
- **logical intention:** species AND farming, with OR within each block.

The refactored named-concept example must map these *exact* terms into `species` and `farming`, with `expression: "species AND farming"`; no substitutions, stemming or term additions are acceptable in an equivalence baseline.

## Database comparison (full searches)

| Provider | Legacy W00 output form | New generic W00 output form | Verdict |
|---|---|---|---|
| Lens | `(title:(S) OR abstract:(S) OR keyword:(S)) AND (title:(F) OR abstract:(F) OR keyword:(F))` | Exactly the same per-concept fielded expressions with additional parentheses | **Structurally equivalent**, contingent on field/operator semantics |
| Scopus | `TITLE-ABS-KEY((S) AND (F))` | `TITLE-ABS-KEY(S) AND TITLE-ABS-KEY(F)` | **Not established as equivalent**: distribution of a combined field-search scope across AND may alter scope, tokenisation or matching |
| OpenAlex | `works where title/abstract has ((S-oql) and (F-oql))`, terms quoted, lowercase Boolean | The generic translator rejects OpenAlex automatic translation; an explicit OQL override is mandatory | **Blocked pending explicit override**, ideally an exact baseline OQL string |
| AGRICOLA via Europe PMC | `SRC:AGR AND TITLE_ABS:((S) AND (F))` | `SRC:AGR AND ((TITLE_ABS:(S)) AND (TITLE_ABS:(F)))` | **Not established as equivalent**: different field scoping and grouping |
| MED, ETH, CBA, PPR via Europe PMC | Same as AGR with source code switched | Same as AGR with source code switched | **Not established as equivalent**: different field scoping and grouping |
| Web of Science | `TI=((S) AND (F)) OR AB=((S) AND (F)) OR AK=((S) AND (F))` | `(TI=(S) OR AB=(S) OR AK=(S)) AND (TI=(F) OR AB=(F) OR AK=(F))` | **Not equivalent**: generic search permits species in one field and farming in another, whereas legacy requires both within the same field |
| EBSCO source databases | `(TI (S) OR AB (S) [OR KW (S)]) AND (TI (F) OR AB (F) [OR KW (F)])`, depending on source config | Same source-config field tags applied independently to S and F | **Structurally equivalent**, contingent on EBSCOhost parser behaviour |

`S` is the legacy OR-joined species terms; `F` the legacy OR-joined farm terms. These placeholders are **not executable queries**.

## Consequences

- **Do not switch the authoritative salmon input to the generic translator and assume identical retrieval.**
- For Web of Science, cross-field records are a real logical difference; choosing broader retrieval may be defensible but is a **methodological change**, not faithful migration.
- Scopus and Europe PMC have distinct syntactic scopes in the old and new query strings. A controlled equivalence test and documentation-backed inspection are needed before certifying equivalence.
- OpenAlex needs a literal provider-specific OQL override, carefully preserving the legacy title/abstract scope.
- Field scope can differ intentionally across providers; identical terms and top-level AND/OR are insufficient to prove retrieval equivalence.
- The original **full** search is the baseline. Fortnightly searches use different provider-specific date filters and must be assessed separately; full-query equivalence must not be claimed for them by default.
- The original salmon strategy should remain under `user_input/`; a **separate** generic-format candidate is appropriate during validation.
- Matching structural expressions are **not** evidence of matching API result sets. API tests have not been authorised/executed.

## Acceptance criteria before migration

1. Reproduce the legacy full query exactly (or an explicitly justified algebraically equivalent form) for each selected database, including field scope, syntax and phrase/wildcard handling.
2. Capture original and candidate strings per database in a static comparison artefact.
3. Check the candidate search with offline R parsing and explicit assertions; run controlled API comparisons only with separate approval.
4. Record deliberate retrieval-behaviour changes as search-strategy revisions, never as silent refactoring.
5. Validate full, fortnightly and rare expansion modes independently.

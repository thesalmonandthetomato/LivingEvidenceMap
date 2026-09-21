# Workflow 02 deduplication rules v2

## Status

Validation design for branch `workflow02-multisource-reconciliation`.

This specification deliberately starts from the bibliographic/source records without applying historic human duplicate or not-duplicate decisions. Human adjudications are a later validation/override layer and must not influence the initial deterministic result.

The method builds on the staged field-combination approach of Bramer et al. and the blocking plus field-specific comparison approach used by ASySD, while adding abstract-sequence evidence because the analytical unit in this Living Evidence Map is the abstract.

## Core principles

1. Candidate generation and duplicate classification are separate operations.
2. A candidate block only determines which pairs are compared. Membership of a block is not, by itself, evidence sufficient for merging unless an explicit automatic rule below says so.
3. Source records and raw provider fields are never destructively modified by Workflow 02.
4. Exact means identical after the relevant explicitly documented normalisation.
5. Human decisions are not loaded during initial deterministic reconciliation.
6. Automatic rules are intentionally high-specificity. Borderline evidence is either routed to one of the narrowly defined review categories or left separate.
7. Transitive clustering is performed only over edges classified `duplicate`.

## Normalisation

### Titles

`title_norm` is comparison-only and is generated using Unicode-aware normalisation:

1. strip HTML/XML markup while retaining enclosed text;
2. decode entities;
3. Unicode NFKC normalisation;
4. Unicode case folding/lowercasing;
5. remove punctuation and whitespace;
6. retain native-script letters and numbers.

No ASCII transliteration is used for the principal title key. Korean, Cyrillic, Chinese, Japanese and accented Latin text must remain comparable in the original script.

A transliterated title may be generated only as an optional candidate-discovery aid. It is never sufficient by itself for an automatic merge.

### DOI

Two distinct derived DOI values are maintained.

`doi_norm` is used for exact DOI rules. It removes presentation/transport artefacts only:

- `doi:` and DOI URL wrappers;
- URL query strings and fragments;
- recognised terminal HTML/full-text/file artefacts;
- ordinary trailing citation punctuation;
- case differences.

It must not truncate a DOI to publisher or journal level and must not remove legitimate DOI suffix content.

`doi_family` is a separate comparison-only key used for recognised repository version forms such as terminal `/v2` or `.v1`. DOI-family equality is never substituted for exact `doi_norm` equality in the short-field DOI + title rules.

Raw DOI values are retained unchanged.

### Abstracts

`abstract_norm`:

1. strips markup while retaining text;
2. decodes entities;
3. applies Unicode NFKC;
4. case-folds;
5. maps punctuation/separators to spaces;
6. normalises common Unicode-equivalent characters;
7. collapses whitespace;
8. preserves token order.

An exact abstract hash may be stored as an implementation optimisation. Hash equality means only exact equality of `abstract_norm`; hashing is not a fuzzy matching rule.

## Bramer candidate passes

The following field combinations are generated over the complete metadata set.

- A: Author + Year + Title + Journal
- B: Author + Year + Title + Pages
- C: Title + Volume + Pages
- D: Author + Volume + Pages
- E: Year + Volume + Issue + Pages
- F: Title
- G: Author + Year

Bramer A and B are sufficiently specific to act as automatic duplicate rules when every component is populated and exactly equal after normalisation.

Bramer C-G are candidate-generation routes only in this implementation. They do not automatically merge records; candidate pairs must satisfy one of the automatic decision rules below.

## Additional candidate-generation blocks

Candidate pairs are the union of pairs nominated by any of:

- Bramer A-G;
- exact `doi_norm`;
- exact `doi_family`;
- exact `title_norm`;
- exact `abstract_norm` hash;
- abstract shingle signatures designed to nominate high-containment abstract pairs for full comparison.

The union is only a shortlist. No record is merged simply because a pair entered the candidate set.

For the 2,000-record validation, 2,000 deterministic pseudo-random anchor manifestations are selected from the complete multisource set. Candidate generation still searches the complete corpus, so a duplicate of an anchor remains discoverable even when the duplicate manifestation itself was not selected as an anchor.

## Abstract sequence metrics

Ordinary whole-string similarity is retained only as diagnostic/supporting information. It is not the principal abstract criterion.

For candidate pairs with usable abstracts, calculate:

### Exact abstract equality

`abstract_norm_A == abstract_norm_B`.

### Ordered-token coverage

Longest common token subsequence divided by the token count of the shorter abstract:

`LCS(tokens_A, tokens_B) / min(n_A, n_B)`.

This tolerates inserted or appended material while requiring the matched content to remain in sequence.

### Five-word-shingle containment

Generate consecutive five-token shingles and calculate:

`|shingles_A ∩ shingles_B| / min(|shingles_A|, |shingles_B|)`.

This measures how much of the shorter abstract survives as verbatim local sequence in the longer record.

### Strong abstract match

Calibrated against the supplied known-duplicate examples:

- if at least 80 tokens are matched: ordered-token coverage >= 0.90 AND five-word-shingle containment >= 0.60;
- if 60-79 tokens are matched: ordered-token coverage >= 0.95 AND five-word-shingle containment >= 0.75;
- below 60 matched tokens: fuzzy abstract evidence cannot, by itself, support automatic deduplication.

These thresholds captured 20/21 non-exact comparable abstract links in the supplied labelled duplicate examples. The remaining short 19-token pair is expected to be identified from bibliographic evidence rather than by weakening the abstract threshold.

## Title containment

`title_containment` is true when the complete shorter `title_norm` occurs contiguously inside the longer `title_norm`, with a minimum shorter-title length of 30 normalised characters.

This handles translated, bilingual, explanatory or subtitle-extended manifestations without lowering the generic fuzzy-title threshold.

## Automatic duplicate rules

Rules are evaluated in order. A pair is automatically merged when the first applicable rule classifies it as `duplicate`.

1. **Bramer A**: exact Author + Year + Title + Journal.
2. **Bramer B**: exact Author + Year + Title + Pages.
3. **Exact DOI + exact title**: exact `doi_norm` and exact `title_norm`.
4. **Exact title + exact abstract**.
5. **Exact DOI + title containment**.
6. **Exact DOI + title similarity >= 0.985**.
7. **Exact DOI + exact abstract**.
8. **Exact title + strong abstract match**.
9. **Title containment + strong abstract match**.
10. **Title similarity >= 0.97 + strong abstract match**.
11. **Title similarity >= 0.95 + exact normalised author field + exact year**.

Exact DOI in rules 3, 5, 6 and 7 always means `doi_norm`, not `doi_family`.

## Manual-review rules

Only the following categories are retained for manual review after automatic rules have been applied:

1. **Exact abstract without sufficient independent metadata support.**
2. **DOI-family match + title similarity >= 0.97**, where exact `doi_norm` does not match and no automatic rule has fired.
3. **Exact title + publication-year difference <= 1**, where no stronger automatic rule has fired.
4. **Strong abstract/content match accompanied by a material bibliographic conflict**, especially two populated genuinely different `doi_norm` values.

Other weak candidate pairs remain separate rather than being sent to manual review.

## DOI conflicts

Different populated exact `doi_norm` values are not automatically treated as proof of non-duplication.

However, fuzzy abstract evidence must not override two genuinely different populated DOI values automatically. Such cases are manual-review candidates under rule 4 above.

Exact abstract + strong independent bibliographic identity may still nominate the pair for review, because the project analytical unit is the abstract and source metadata can be contaminated.

## Clustering

Only `duplicate` edges enter union-find clustering.

Review edges do not connect clusters.

Candidate-only or unresolved edges do not connect clusters.

This prevents an uncertain bridge from transitively combining otherwise distinct works.

## Representative selection

Representative selection is conceptually separate from duplicate identification.

Prefer, in order:

1. usable abstract;
2. exact DOI present;
3. complete/non-truncated title;
4. richer journal/volume/issue/pages metadata;
5. richer author metadata;
6. source preference only as a final deterministic tie-breaker.

No source manifestation is deleted from the reconciliation artefact.

## Validation plan

Before production replacement:

1. run the rules with no historic human adjudications;
2. select 2,000 deterministic pseudo-random anchor records from the complete all-source Workflow 01 corpus;
3. search the complete corpus for candidates of those anchors;
4. report all automatic merges and all manual-review candidates by rule;
5. manually audit a stratified sample from every automatic rule, oversampling the weakest rules;
6. check residual duplicates among the resulting representatives;
7. compare algorithmic output against historic human decisions only after the independent run;
8. only then run the v2 rules over the full corpus.

The validation sample seed/key must be fixed and recorded so the same 2,000 anchors can be reproduced exactly.

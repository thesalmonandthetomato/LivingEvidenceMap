# Citation-gap sensitivity search

## Status

The successful Lens citation harvest is the canonical implementation pattern for citation-gap sensitivity searching in the Living Evidence Map. The current Lens run is a validated baseline, not a once-only dataset. Citation chasing must be rerun after material expansion of the canonical included corpus, including after the planned EBSCO databases are ingested and adjudicated.

The citation-gap search is separate from W00 database searching and from W04 screening. It is a sensitivity search for literature connected by citations to records already included in the map.

## Common eligibility filter

Citation neighbours are retained as candidates when the available title, abstract and keyword text:

1. contains at least one salmon term:
   - salmon
   - Salmo
   - Oncorhynchus
   - "rainbow trout"
2. contains none of the production farming terms:
   - farm*
   - cage*
   - pens
   - penned
   - pen
   - aquacultur*
   - commercial*

The filter is applied locally after citation-neighbour retrieval. It is intentionally the same across providers where equivalent fields are available. `salmonid*` is deliberately not an eligible positive term: records mentioning only a generic salmonid concept cannot pass the later W05 species gate, which requires an identifiable salmon species.

## Lens canonical pattern

The validated Lens implementation establishes the canonical architecture:

1. derive provider seed IDs from the authoritative included canonical corpus;
2. checkpoint seed retrieval in bounded batches;
3. preserve forward and backward citation relations separately;
4. preserve manifestation-level seed-to-neighbour edges;
5. globally deduplicate neighbour IDs before metadata retrieval;
6. retrieve metadata in bounded checkpointed chunks;
7. apply the common citation-gap text filter locally;
8. remove records already present in the authoritative included corpus;
9. produce a final deduplicated candidate set while retaining provenance and direction;
10. perform no W04/OpenAI screening unless explicitly authorised.

The completed Lens baseline produced 30,112 unique filtered candidates from the pre-EBSCO canonical corpus. When the canonical corpus changes materially, the procedure should be rerun from the new authoritative corpus rather than treating that candidate set as permanently complete.

## OpenAlex complementary chase

OpenAlex is used only where it adds citation coverage that Lens could not provide.

### Seed rule

Select included canonical records that:

- have one or more OpenAlex manifestation IDs; and
- have no Lens manifestation ID.

At the time this method was designed, this subset contained 2,290 canonical records. That number is descriptive, not a hard-coded guard, because the canonical corpus will change after EBSCO ingestion and future updates.

Records represented in both Lens and OpenAlex are not chased through OpenAlex. This avoids duplicating citation work already performed through Lens.

### Citation directions

For every selected OpenAlex manifestation:

- backward: the seed's `referenced_works` are candidate neighbours;
- forward: works returned by the OpenAlex `cites` relation are candidate neighbours.

For forward searches covering multiple seeds, the returned citing work's `referenced_works` are intersected with the seed set so that every edge retains the exact included seed it connects to.

### Checkpoint architecture

The implementation in `scripts/temporary/openalex_citation_gap_checkpointed.R` mirrors the validated Lens pattern:

1. `seed-index`
   - reads the authoritative W08 canonical JSONL;
   - dynamically identifies OpenAlex-only canonical records;
   - preserves canonical-to-OpenAlex manifestation mapping;
   - supports a small seed limit for functional testing or `all` for an explicitly authorised full run.

2. `chase`
   - retrieves seed records in bounded groups;
   - extracts backward references;
   - retrieves forward citing works;
   - writes citation edges with canonical seed ID, OpenAlex seed ID, candidate OpenAlex ID and direction.

3. `prepare`
   - combines all chase checkpoints;
   - globally deduplicates neighbour OpenAlex IDs;
   - creates bounded metadata chunks.

4. `metadata`
   - retrieves candidate metadata;
   - reconstructs OpenAlex abstracts from `abstract_inverted_index`;
   - applies the common salmon-positive / farming-negative filter locally;
   - checkpoints all retrieved metadata as well as filtered candidates.

5. `finalise`
   - removes candidate IDs already represented in the authoritative included corpus;
   - deduplicates OpenAlex candidates against the existing Lens candidate set;
   - preserves cross-source provenance and citation edges;
   - creates a combined deduplicated candidate record set.

## Cross-source deduplication

OpenAlex candidates are compared with Lens candidates using high-specificity deterministic matches in this order:

1. shared DOI, PMID or PMCID;
2. exact normalised title.

A matched candidate is one logical candidate with both provider provenances, not two candidates. Provider-specific IDs and raw metadata remain preserved.

The primary later connectivity ranking must count unique included canonical records connected to each candidate, not provider observations. A citation edge seen in both providers therefore corroborates provenance rather than being counted twice.

## Current functional-test workflow

`.github/workflows/tmp_openalex_citation_gap_test.yml` is manual-dispatch only. Its default seed limit is 20. It:

- derives the OpenAlex-only subset dynamically;
- chases citations only for the selected test seeds;
- applies the common text filter;
- deduplicates test candidates against the successful Lens candidate artifact;
- verifies that no OpenAI API screening was performed.

The full OpenAlex-only chase must not be run until explicitly authorised. The intended production rerun should be performed after the EBSCO-expanded canonical corpus is stable.

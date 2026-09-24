# Workflow 01 abstract-repair rule

When duplicate adjudication identifies an identical/near-identical abstract that is semantically inconsistent with one record's title, the pair must not be finalised as duplicate or not_duplicate from the contaminated metadata.

Required sequence:

1. Block duplicate promotion with `promotion_reason=abstract_title_inconsistency_guard`.
2. Create an abstract-repair item keyed by immutable `source` + `source_record_id`.
3. Strip the suspect abstract from that source record.
4. Seek a verified replacement abstract for that exact record.
5. Accept a replacement only when independently supported by the record's DOI, or by a strong title + author + year match to a trusted source.
6. Never use the paired record's abstract itself as the sole verification source.
7. If no verified replacement exists, leave the abstract missing.
8. Re-run candidate scoring / duplicate adjudication on the repaired metadata before clustering.
9. Reclustering remains blocked until every repair item has a validated terminal action.

This prevents metadata contamination from being converted into false duplicate merges while also preventing contaminated records from being retained with incorrect abstracts.

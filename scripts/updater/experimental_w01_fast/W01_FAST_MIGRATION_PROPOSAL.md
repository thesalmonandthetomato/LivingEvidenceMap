# W01-Fast migration and rollback proposal (Task 12)

**Status: proposal only. No production migration authorised or performed.**

## Immutable deployment boundary

- Production branch: `workflow01-final-architecture`, frozen commit `8febc7b99ce1f7752c7553ed6023976a643f8621`.
- Experimental branch: `w01-fast-development`.
- Do not alter production W01 scripts, production Actions workflow, existing decisions, Shiny queues, Zenodo records, W02 dispatch or dashboard during validation.
- Rollback means retaining the original workflow and reference state intact, **not** rewriting historical decisions or restoring by positional row number.

## Demonstrated evidence

1. Exact October candidate discovery parity on 1,719 pairs, including stable-identity pair and block checks: Actions `39492401178`.
2. October cluster membership and exact work-ID reconstruction, 136,057 manifestations, **given reference-derived approved duplicate links**: Actions `39491210411`.
3. October incremental production decision reference: 1,719 pairs, mapped to immutable source identities: Actions `39496185477`. This is not independent scorer parity.
4. Synthetic canonical-builder filtered/full parity and unchanged-record recombination: `test_canonical_builder_filtered_parity.R`. This is not real October canonical parity.
5. Isolated snapshot/transition/replay/pointer regression suite: `.github/workflows/w01_fast_development_guardrails.yml`. It is not a completed real incremental-state recovery rehearsal.
6. Never report the candidate-stage speedup (historical benchmark roughly 8.2x) as a full W01 pipeline speedup.

## Explicit blockers to migration authorisation

- Independent W01-Fast automatic decision/scoring parity on the 1,719 October pair identities, classifications, rules and routes. The strict comparator exists, but the experimental independent scoring path does **not**.
- Real-data, affected-only canonical record comparison including unchanged-work byte identity, repair/strip handling and lineage. Current equivalence is synthetic.
- End-to-end integration and interrupted transaction recovery, including checkpoints, repeat batch idempotence, pointer rollback and authoritative delta replay. Current primitives are not a proven integrated successor to W01.
- Full-run benchmark and cost/memory assessment at representative scale.
- Production cutover plan must be reviewed and authorised independently by repository owner.

## Proposed controlled cutover, only after blockers pass

1. Pin a frozen production W01 reference and record full provenance, source digests, decision ledger hashes, snapshot IDs and current production pointer.
2. Run W01-Fast on a *separate* isolated state store with read-only frozen W00 inputs. Compare exact stable pair identities, decisions, clusters, canonical JSONL and emitted W02 interface files. No Shiny or Zenodo writes.
3. Re-run an identical batch: verify that no second new decision is appended, work IDs are unchanged, and state pointer and canonical content remain consistent. Simulate interruption before and after checkpoint publication.
4. Run an experimental scheduled-update shadow, without downstream dispatch. Require a bounded runtime/memory/artifact report.
5. Present an explicit owner approval request summarising passed checks, remaining risks and a reversible deployment diff. **Do not automatically promote this branch.**

## Rollback requirements

- Production W01 and its existing baseline remain available and unchanged until owner approves cutover.
- Record old workflow ref, frozen commit, previous authoritative state pointer and hash, and all changed workflow/script files.
- If mismatch or failure occurs before W01-Fast publication: stop experimental run and retain production pointer untouched.
- If an owner-authorised cutover later fails: disable the new entry point, restore the original workflow ref and prior trusted pointer *under an explicit owner-approved procedure*, verify snapshot integrity and historical adjudication linkage, and only then resume downstream work.
- Never silently replay ambiguous transactions, infer identity from numeric offsets, discard undecided human cases, or send unverified output to W02.

## Scope closure

The original 12 tasks remain the scope. No new feature or additional workflow is authorised by this proposal. The remaining work is acceptance of Tasks 5–11, not repeated production reruns. A migration proposal can be completed even though production migration remains blocked.

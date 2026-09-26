# Workflow Checkpoint Policy

## HARD RULE — durable checkpoint before validation

**Any workflow that downloads, generates, transforms, or creates paid or otherwise costly content MUST checkpoint each successful unit of work to durable storage before validation, aggregation, merging, or any downstream processing.**

A validation failure, parser failure, aggregation failure, upload failure, or workflow cancellation MUST NOT require the costly operation to be repeated when a successful checkpoint already exists.

For model/API calls specifically:

1. Make the model/API call.
2. Immediately write the raw response to the per-record checkpoint.
3. Immediately write the parsed/generated record to the per-record checkpoint.
4. Record status as `generated`.
5. Only then validate or aggregate.
6. If validation fails, retain the generated record and mark it `validation_failed`; do not call the model again.
7. On workflow restart, discover existing checkpoints and skip already completed records.
8. Retain checkpoints for **at least 90 days**.

This is a hard operational requirement, not an optimisation or optional best practice.


## Validated inter-workflow handoff policy

This is distinct from the 90-day costly-work checkpoint rule above.

Once a workflow has completed validation and published its accepted state to durable storage, it SHOULD also expose a short-lived **handoff artefact** for the next workflow.

Rules:

1. Zenodo (or another registered durable archive) remains the authoritative checkpoint.
2. The handoff artefact is only a temporary cache/materialisation of that accepted state.
3. Handoff artefacts should normally be retained for **7 days**.
4. The next workflow should preferentially use the handoff artefact when it is still available **and** it can be verified against the registered authoritative state.
5. If the handoff artefact is missing, expired, incomplete, or cannot be verified, the next workflow must restore from the registered durable checkpoint instead.
6. Both routes must materialise the same standard local input and must pass the same identity/count/checksum validation before processing.
7. An Actions artefact must never become an independent source of authority.
8. Legacy pointers that do not contain enough checksum/provenance information to verify a cached artefact must fall back to durable restoration.
9. Costly per-record/API/model checkpoints remain subject to the **at least 90 days** retention rule. They are not reduced to 7 days merely because a downstream handoff artefact exists.
10. Human-review pauses may outlive the 7-day handoff cache. Resume workflows must therefore be able to restore the exact accepted upstream state from durable storage.

Conceptually:

```text
validated Workflow N state
        |
        +--> registered durable checkpoint (authoritative)
        |
        '--> 7-day handoff artefact (cache)
                    |
              Workflow N+1
             /           \
       cache valid      cache absent/
          |             unverifiable
          v                 |
      verify state          v
          |          restore durable state
          +---------+-------+
                    |
                    v
          identical local input
                    |
                    v
              Workflow N+1
```

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

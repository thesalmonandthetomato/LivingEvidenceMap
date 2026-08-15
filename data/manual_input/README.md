# Manual RIS input

For an exceptional/manual update, upload an RIS file to this directory (for example `incoming.ris`), commit it to `main`, then run **Manual RIS ingestion** from GitHub Actions.

Set `ris_path` to the uploaded file path. The workflow normalizes the RIS into the same update-artifact concept used by the Lens harvester.

A zero-record RIS is treated as a successful empty input and must not modify the master. A non-empty RIS produces normalized JSON/CSV plus a manifest for downstream processing.

Delete or replace the uploaded RIS after it has been processed if it should not remain in the repository.
# Workflow 04 consistency checking

This directory is the durable calibration and consistency record for Workflow 04 relevance screening.

Each validation set must:

1. draw a reproducible random sample of 200 previously screened records;
2. blind the existing decision from the model;
3. run the versioned Workflow 04 prompt and model;
4. record observed agreement and Cohen's kappa against the existing decisions;
5. retain the complete conflict set;
6. manually adjudicate every conflict;
7. record adjudication decisions and rationale without overwriting the original validation result;
8. record post-adjudication agreement and Cohen's kappa;
9. record the exact prompt version and SHA-256 so prompt revisions can be evaluated across successive validation sets.

## First calibration set

Validation run: `35010609269`

Prompt: `workflow04-v1-legacy-python-prompt`  
Prompt SHA-256: `3b7bb27fa107b56f5b265a6ef5b8833e20eae43ccd02b20b0491db0372de3d19`  
Model: `gpt-5.6-luna`  
Sample: 200 records, seed `650870934`

### Before conflict adjudication

- observed agreement: **96.5%**
- Cohen's kappa: **0.9086**
- conflicts: **7**
- false exclusions: **0**
- false retentions against the historical labels: **7**

### After conflict adjudication

Six historical excludes were adjudicated to **retain** and one remained **exclude**.

- observed agreement against the adjudicated decisions: **99.5%**
- Cohen's kappa against the adjudicated decisions: **0.9864**
- remaining disagreement: **1/200**

The full seven-record adjudication trail is stored in `validation_35010609269.json`.

The original files under `data/adjudication/workflow04_validation_runs/35010609269/` remain the immutable raw validation record.


## Validation run 35075669317

Prompt: `workflow04-v2-targeted-clarifications`  
Prompt SHA-256: `3eb903948e355546af85bfb0869a22652af2b711ac5aa4b28994c0964b847b55`  
Model: `gpt-5.6-luna`  
Sample: 200 previously unsampled records, seed `715930982`  
Canonical commit: `e8ba9f3f8577e88130e77f214f5565260e33673f`

### Before conflict adjudication

- observed agreement: **92.0%**
- Cohen's kappa: **0.7944**
- conflicts: **16**
- false exclusions against historical labels: **4**
- false retentions against historical labels: **9**
- uncertain decisions: **3**
- sensitivity: **96.58%**
- specificity: **79.63%**

Adjudication status: **pending**. The complete conflict set is stored under `data/adjudication/workflow04_validation_runs/35075669317/conflicts.csv`, and the adjudication record is `validation_35075669317.json`.

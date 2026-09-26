# Workflow 01: ad hoc actions and baseline-establishment log

## Purpose

This document records non-routine actions used while establishing and validating the current Workflow 01 baseline. They are not part of the generic production methodology described in `workflow_01_functionality_map.md`.

## Baseline establishment

The accepted full baseline was produced in GitHub Actions run `36103542054` and archived as restricted Zenodo record `22953437` (DOI `10.5281/zenodo.22953437`).

The baseline contained:

- 90,137 source manifestations;
- 32,292 canonical works;
- 22,956 duplicate clusters;
- 9,336 singleton clusters;
- zero unresolved pair decisions.

## Metadata-repair validation

A finite approved repair set was applied while establishing the authoritative canonical baseline. Full-corpus validation run `36128255337` confirmed that all approved repairs mapped and applied correctly, with no change to source-manifestation or canonical-work cardinality.

The repair-only delta changed only the affected canonical records and replayed exactly to the target canonical JSONL. This repair episode is baseline provenance, not an additional permanent Workflow 01 processing stage beyond the generic repair capability already documented in the formal workflow report.

## Stable-ID validation

Stable identifier behaviour was tested separately in run `36109881761`, covering preservation, deterministic merge aliases and rejection of prohibited historical splits.

## Development fixtures and recovery

Fast delta/replay fixtures and other development-only validation runs were used to test implementation changes without repeatedly executing the full corpus. These runs are not part of Workflow 01 methodology.

## Reporting rule

For Workflow 09 and manuscript methods, use `workflow_01_functionality_map.md` to describe Workflow 01. Use this file only when documenting how the current baseline was established or repaired.

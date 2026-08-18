# AI provenance and model-assisted processing

## Scope

Large language models are used as controlled components of the salmon Living Evidence Map pipeline. They are not treated as unrestricted substitutes for the predefined annotation rules or human quality control.

## Model-assisted stages

The pipeline contains three distinct forms of model-assisted processing:

1. **Relevance screening**, using the established salmon screening workflow and its validated model resources.
2. **Species/geography adjudication**, in which an LLM reviews explicitly flagged deterministic annotations and returns a constrained ACCEPT, CHANGE or UNRESOLVED decision with supporting rationale.
3. **Topic classification**, in which GPT-5 mini, accessed through the OpenAI Responses API, assigns one or more topics from the predefined salmon topic ontology using structured output constrained to permissible ontology paths.

The model-assisted stages should be treated as separate methods because their inputs, outputs and scientific roles differ.

## Structured outputs and safeguards

Model responses are constrained by predefined schemas and permitted annotation values. For species/geography adjudication, the model is restricted to the dimension(s) flagged for review and is provided with the title, abstract and deterministic annotation evidence. For topic classification, the permissible output space is the current version of the topic ontology. Technical/API failures are recorded separately from substantive uncertainty, and failed or unresolved records are not silently converted to validated assignments.

## Human oversight

Human validation is applied to unresolved or explicitly flagged records and to exceptions identified by automated validation. Review decisions are retained with the associated update outputs. The promotion workflow prevents unresolved required review items from being incorporated into the master dataset.

## Update-level provenance

For reproducibility, each production update should identify, where applicable:

- source corpus and harvest date;
- LLM provider;
- exact model identifier;
- prompt or structured-output schema version;
- species dictionary, geographic gazetteer and topic-ontology versions;
- number and identity of records sent to model-assisted stages;
- model failures and review flags;
- human-review outcomes; and
- final promoted master-data version.

Model identifiers should be recorded from the actual production configuration rather than inferred from the general repository implementation. This is particularly important for species/geography adjudication, where the adjudication interface is deliberately separated from the model configuration.

## Reproducibility note

Because hosted LLMs can change over time, reproducing a historical update requires the recorded model identifier and the relevant prompt/schema and reference-data versions. Where an exact hosted model version cannot be recovered, the repository should distinguish reproduction of the pipeline from exact reproduction of the original model response.

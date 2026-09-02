#!/usr/bin/env python3
"""Validation runner for Workflow 04 with human-approved prompt amendments.

This imports the production screening implementation and changes only the system
prompt. It remains separate from production until validation is complete.
"""
from pathlib import Path
import importlib.util

BASE = Path(__file__).with_name("relevance_screen_jsonl.py")
spec = importlib.util.spec_from_file_location("workflow04_base", BASE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.SYSTEM_PROMPT += r'''

13. REVISED ELIGIBILITY CLARIFICATIONS — HUMAN-APPROVED VALIDATION RULES

These clarifications take precedence over any looser interpretation of the high-sensitivity rule above. High sensitivity means retaining genuinely plausible eligible records; it does NOT mean combining unrelated words or inferring missing eligibility evidence.

ELIGIBLE SPECIES PLUS COMMERCIAL AQUACULTURE
An explicit mention of an eligible species together with an explicit commercial aquaculture/farming indicator that is connected to that species or salmon-farming context is sufficient for RETAIN at this screening stage, even where the eligible species is not the organism directly measured or the principal analytical subject. The connection may be the source, receptor, exposure, risk, impact, treatment, affected industry, production system, environmental context, implication, application, disease concern, management relevance, or another explicit connection. Do NOT require the study to be substantively focused on salmon aquaculture.

STRICT DEFINITION OF SALMONID
"Salmonid" and "salmonids" are broad taxonomic terms referring to members of the family Salmonidae. Salmonidae contains many species that are NOT eligible for this evidence map. Therefore:
- "salmonid" or "salmonids" MUST NEVER be treated as equivalent to salmon, Atlantic salmon, Salmo salar, Oncorhynchus spp., or rainbow trout;
- the term "salmonid(s)" alone can NEVER satisfy the eligible-species criterion;
- do NOT infer an eligible species from "salmonid(s)" because aquaculture is also mentioned;
- do NOT infer an eligible species from a pathogen name such as Aeromonas salmonicida or Renibacterium salmoninarum;
- do NOT infer an eligible species from geography, journal, affiliation, funding, disease, feed, or general subject matter.
A record containing only generic salmonid(s) plus generic or explicit aquaculture context fails the species gate and should be EXCLUDE unless separate supplied evidence explicitly establishes a qualifying salmon-farming/industry context under the rule below.

NAMED SALMON-INDUSTRY / EXPLICIT SALMON-FARMING CONTEXT
An explicit named salmon-industry or salmon-aquaculture organisation, association, regulatory programme, production system, salmon farm, salmon-farming operation, salmon net pen, salmon mariculture system, or equivalent may itself establish the relevant salmon context where the supplied record explicitly connects the study, data, exposure, impact, implication, or application to that salmon industry/farming context. This can apply even where fish are otherwise described generically as salmonids or the organism directly measured is not an eligible fish species. For example, explicit use of data from the Chilean Salmon Industry Association may establish the relevant salmon context. This rule does not make every passing reference to a salmon-industry organisation sufficient; the connection must be explicit rather than incidental/background.

INCIDENTAL, EXAMPLE, LIST, OR BACKGROUND SPECIES REFERENCES
An eligible species mention is NOT sufficient when it is merely incidental to the work. Treat a species mention as insufficient where it appears only as:
- a non-exhaustive example introduced by wording such as "such as", "including", "for example", or equivalent;
- one item in a broad list of species/products/industries with no study-specific analysis or explicit application to that eligible species;
- generic background, analogy, comparison, or contextual information;
- a feed/product name such as "salmon feed" or "salmon ration" used in a study of a non-eligible species.
Do not RETAIN merely because an eligible species word appears somewhere in an otherwise unrelated aquaculture record. The position of the reference within the abstract is not itself decisive: a reference at the beginning or end can be eligible if it explicitly connects the work to eligible salmon aquaculture, and a reference in the middle can be incidental.
If the eligible species is absent from the title and appears only once as a generic example/list item with no other explicit connection to that species, EXCLUDE.

LINK THE SPECIES EVIDENCE TO THE AQUACULTURE EVIDENCE
Do NOT construct eligibility by combining independent statements that are not linked. For example, a record that mentions Pacific salmon as one fisheries example in one passage and discusses aquaculture generically elsewhere is NOT eligible unless the supplied record explicitly connects the salmon reference to aquaculture/farming. Co-occurrence of a species term and an aquaculture term somewhere in the same record is not enough by itself.

ELIGIBLE SPECIES WITHOUT AQUACULTURE CONTEXT
If an eligible species is explicit but the supplied record contains no evidence establishing commercial aquaculture/farming context, farmed origin, or an explicit qualifying salmon-farming connection, classify EXCLUDE, not UNCERTAIN. Species evidence alone cannot establish eligibility. This includes laboratory biology, genomics, immunology, toxicology, food/product, fisheries, storage, or other studies where aquaculture is not established.

AQUACULTURE CONTEXT WITHOUT ELIGIBLE SPECIES
If commercial aquaculture is explicit but no eligible species is established, classify EXCLUDE, not UNCERTAIN. An aquaculture-specific affiliation, funding source, journal, disease, or production setting cannot create a missing eligible species identity. The separate explicit salmon-farming/industry rule above remains the only exception where the salmon context itself is explicitly established.

AFFILIATIONS AND FUNDING
An explicitly aquaculture-specific affiliation or funding source may establish the aquaculture-context gate when an eligible species is already explicit and clearly relevant to the study. It can NEVER establish the species gate by itself.
Generic or adjacent affiliations do NOT establish aquaculture context merely because they could involve farmed fish. Examples that are insufficient on their own include fisheries, seafood, aquatic products, aquatic-product processing or preservation, marine biology, food science, agriculture, environmental science, and generic government or university units.

COMMERCIAL DOES NOT MEAN AQUACULTURE
The word "commercial" does NOT by itself establish aquaculture. Commercial sale, seafood, fisheries, processing, food products, salmon oil, feed ingredients, laboratories, fishing, storage, or other commercial activity may involve wild-caught fish. Do not convert "commercial salmon", "commercial salmon oil", "commercial fish species", a supermarket product, or generic industrial processing into farmed origin without supporting evidence. Apply the existing products/processing rule where the supplied metadata genuinely establishes or reasonably makes clear an aquaculture production context; do not infer aquaculture from the word "commercial" alone.

HATCHERY, RESTOCKING, AND POPULATION ENHANCEMENT OVERRIDE
The broad eligible-species-plus-aquaculture rule does NOT override the population-enhancement exclusion. EXCLUDE sea ranching, hatchery release, stock enhancement, restocking, reintroduction, population supplementation, and stocking for recreational/sport fisheries where fish are produced or released for wild or managed population enhancement rather than commercial aquaculture production. This applies even when an eligible species is explicit and the facility is described as a hatchery, farm, fish farm, or aquaculture facility. Historical provenance from a farm does not make a later restocking/recreational-population study eligible. Also distinguish ordinary terrestrial/arable/livestock uses of the word "farm/farming" from fish farming.

DECISION LOGIC — STRICT GATES
Use the following order:
1. Establish eligible species evidence OR an explicit qualifying salmon-farming/industry context.
2. Establish commercial aquaculture/farming relevance explicitly linked to that eligible species/context.
3. Apply exclusions for incidental/list/background mentions and hatchery/restocking/population enhancement.
4. RETAIN only when both gates are satisfied or a specific explicit inclusion rule applies.
5. EXCLUDE when either gate clearly fails. In particular, eligible species + no aquaculture = EXCLUDE; aquaculture + no eligible species = EXCLUDE; generic salmonid(s) + aquaculture = EXCLUDE.
6. Use UNCERTAIN only for genuinely contradictory or incomplete evidence where the supplied record prevents determining whether a gate is met. Do NOT use UNCERTAIN as a substitute for a clearly failed eligibility gate.
'''

if __name__ == "__main__":
    mod.main()

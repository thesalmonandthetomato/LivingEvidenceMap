#!/usr/bin/env python3
"""Validation runner for Workflow 04 with the human-approved prompt amendments.

This imports the production screening implementation and changes only the system
prompt. It is intentionally separate while the revised prompt is being validated.
"""
from pathlib import Path
import importlib.util

BASE = Path(__file__).with_name("relevance_screen_jsonl.py")
spec = importlib.util.spec_from_file_location("workflow04_base", BASE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.SYSTEM_PROMPT += r'''

13. REVISED ELIGIBILITY CLARIFICATIONS — HUMAN-APPROVED VALIDATION RULES

ELIGIBLE SPECIES PLUS COMMERCIAL AQUACULTURE
An explicit mention of an eligible species together with an explicit commercial aquaculture/farming indicator is sufficient for RETAIN at this screening stage, even where the eligible species is not the organism directly measured or the principal analytical subject. The aquaculture connection may be the source, receptor, exposure, risk, impact, treatment, affected industry, production system, environmental context, implication, application, disease concern, management relevance, or another explicit connection. Do NOT require the study to be substantively focused on salmon aquaculture.

NAMED SALMON-INDUSTRY CONTEXT
An explicit named salmon-industry or salmon-aquaculture organisation, association, regulatory programme or production system may establish the relevant salmon context where the supplied record explicitly connects the work to that salmon industry context. This can apply even where fish are otherwise described generically as salmonids. For example, explicit use of data from the Chilean Salmon Industry Association can establish the relevant salmon context. This rule does not make every passing reference to a salmon-industry organisation sufficient for RETAIN; apply the incidental/background rule below where appropriate.

INCIDENTAL / BACKGROUND SALMON REFERENCES
A reference to salmon farming, salmon aquaculture or the salmon industry does not automatically establish eligibility when BOTH of the following apply:
1. the focal species/system is not an eligible salmon species or rainbow trout; AND
2. the salmon/aquaculture reference serves only as general background, context, comparison or analogy, with no other evidence in the supplied record connecting the study to eligible salmon aquaculture.
In this situation classify as UNCERTAIN for human review rather than RETAIN.
Do NOT require the study to be substantively focused on salmon aquaculture. An explicit connection to eligible salmon aquaculture anywhere in the supplied record may support RETAIN, including an implication, application, risk, disease concern, management relevance, exposure, impact or other stated connection. The location of the salmon/aquaculture reference within the abstract is not itself an eligibility criterion.

HATCHERY / POPULATION ENHANCEMENT OVERRIDE
The broad eligible-species-plus-aquaculture rule above does NOT override the population-enhancement exclusion. EXCLUDE sea ranching, hatchery release, stock enhancement, restocking, reintroduction and population supplementation where fish are produced or released for wild population enhancement rather than commercial aquaculture production. This applies even when an eligible salmon species is explicit and the facility is described as a hatchery, farm or fish farm. Hatchery or farm terminology alone does not establish eligible aquaculture context when the substantive purpose is release into the wild.

GENERIC SALMONIDS — QUALIFICATION
Generic "salmonid" or "salmonids" alone still does not satisfy the species criterion for a direct-species study. However, do not automatically EXCLUDE solely because the fish are called salmonids if other supplied evidence explicitly establishes a salmon-industry or salmon-farming context under the rules above.

DECISION SAFEGUARD
Use UNCERTAIN where a non-eligible focal species/system has only an apparently incidental or background salmon/aquaculture reference and the supplied evidence does not justify either a clear RETAIN or a clear EXCLUDE. Do not turn a background-only salmon reference into an automatic RETAIN.
'''

if __name__ == "__main__":
    mod.main()

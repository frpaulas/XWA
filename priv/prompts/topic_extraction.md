You are an analyst building a topic taxonomy for a knowledge graph of institutional claims.

Given a single claim, assign it exactly ONE topic — a short thematic label (2–4 words) that captures the claim's broad subject area.

Rules:
- Use the BROADEST label that still meaningfully categorises the claim. Err on the side of general over specific.
- Many different claims should share the same topic label.
- 2–4 words only. Never more than 4 words.
- Noun phrases only (e.g. "coal ash disposal", not "disposing of coal ash")
- No adjectives that narrow scope unnecessarily (e.g. "energy loan programs" not "DOE energy loan program oversight")

Claim:
{{claim_content}}

Respond with JSON only:
```json
{"topic": "<topic label>"}
```

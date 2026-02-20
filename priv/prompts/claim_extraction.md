You are extracting claims from institutional documents for a knowledge graph.

A claim is a discrete assertion that expresses a belief, decision, value,
constraint, or position held by the institution. Claims should be:
- Self-contained (understandable without the surrounding text)
- Atomic (one assertion per claim, not compound statements)
- Normalized (rewritten in third person present tense, e.g. "The organization
  prioritizes cost over speed")

Do not extract procedural, liturgical, or purely narrative content unless it
encodes an institutional position. Prefer fewer high-confidence claims over
many uncertain ones.

Document metadata:
- Corpus layer: {{corpus_layer}}  (self_description | internal_record | external_context)
- Source type: {{source_type}}    (aspirational | operational | external)
- Document date: {{document_date}}

Use the corpus layer and source type to calibrate extraction:
- self_description / aspirational documents are dense with claims by design —
  be appropriately selective; not every stated goal is a meaningful claim
- internal_record / operational documents contain procedural noise — extract
  only assertions that encode an actual institutional position or decision
- external_context documents may contain claims about the institution made by
  outsiders — extract these too, noting they are external observations

For each claim extract:
- content: the normalized claim (third person present tense)
- summary: a 5-10 word label suitable for graph node display
- type: a short descriptor of the claim category. Common types include:
    value, priority, constraint, decision, belief, commitment, capability,
    position, aspiration, observation — but coin new types when none fit.
    Use consistent vocabulary across claims in the same document.
- quote: the verbatim source passage the claim was drawn from (keep it tight —
    the sentence or two that most directly supports the claim)
- asserted_at: if the text contains a date more specific than the document date
    for this particular claim (e.g. "as of Q3 2023"), include it in ISO 8601
    format. Otherwise omit this field — the document date will be used.
- confidence: your confidence this is a genuine institutional claim (0.0–1.0).
    Consider: is this a concrete assertion or vague rhetoric? Is it specific
    enough to be falsifiable or contested? Does it encode institutional intent?
- tags: 2–4 short tags for navigation facets (e.g. ["theology", "kingdom",
    "advent"] or ["cost", "engineering", "decision-2019"]). Use lowercase.
- reasoning: one sentence explaining why this is a claim worth capturing

Extract only claims with confidence ≥ 0.6.

Return your response as a JSON object with a single key "claims" containing
the array. Example structure:

{
  "claims": [
    {
      "content": "The organization holds that Kingdom of God has both present and future dimensions.",
      "summary": "Kingdom has present and future dimensions",
      "type": "belief",
      "quote": "we live in an age of expectation... the same situation the people of Jesus' time thought",
      "confidence": 0.82,
      "tags": ["theology", "kingdom", "eschatology"],
      "reasoning": "This is an explicit theological position that recurs across the corpus and shapes other claims."
    }
  ]
}

Document:
<document>
{{document_text}}
</document>

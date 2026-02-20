You are proposing relationships between a newly extracted claim and a set of
existing nodes in a knowledge graph representing institutional knowledge.

This prompt is called once per new claim, after claim extraction. The existing
nodes provided are the most semantically relevant nodes already in the graph —
not the full graph. Evaluate each candidate relationship on its merits.

A relationship is worth proposing when:
- One claim directly supports or reinforces the other
- The claims contradict or create tension with each other
- One qualifies, constrains, or narrows the other
- One provides evidence or context for the other
- One supersedes or evolves from the other (the institution changed its position)
- Both encode positions on the same specific decision or institutional concern

Do NOT propose a relationship merely because two claims share a topic or
subject area. Topical overlap is not a relationship. The connection must be
substantive — it must change how a reader would interpret one or both claims.

For each proposed relationship return:
- from_node_id: the existing node id
- to_node_id: the new claim id (use the placeholder "NEW")
- type: a short emergent descriptor of the relationship. Common types include:
    supports, contradicts, tensions, qualifies, constrains, evidences,
    supersedes, evolves_from, contextualizes — coin new types when none fit.
    Use consistent vocabulary.
- label: a human-readable description of the relationship (one sentence,
    e.g. "Earlier cost-priority claim directly contradicts this commitment")
- directed: true if the relationship runs primarily one way (A supports B but
    B does not necessarily support A). false if genuinely symmetric (A tensions
    B and B tensions A equally).
- importance: how significant is this relationship to understanding either
    claim in context (0.0–1.0). A relationship that materially changes
    interpretation scores high; one that merely adds nuance scores lower.
- certainty: your confidence the relationship is real:
    - solid: explicitly stated or strongly implied in the source documents
    - dashed: reasonably inferred but not explicit
    - dotted: speculative, worth human review but not yet grounded
- confidence: overall epistemic score for this edge (0.0–1.0). Related to
    certainty but distinct — certainty is about evidence quality, confidence
    is about how trustworthy the relationship is as a graph fact.
    As a starting point: solid ≈ 0.85, dashed ≈ 0.6, dotted ≈ 0.35.
    Adjust up or down based on how well the claims actually connect.
- reasoning: one sentence explaining why this relationship is worth capturing

Omit any proposed relationship where certainty is "dotted" AND importance
is below 0.4. Surface only relationships a human reviewer would find useful.

Return your response as a JSON object with a single key "edges" containing
the array. Example structure:

{
  "edges": [
    {
      "from_node_id": "a1b2c3d4-...",
      "to_node_id": "NEW",
      "type": "contradicts",
      "label": "Earlier cost-priority claim directly contradicts this quality commitment",
      "directed": true,
      "importance": 0.85,
      "certainty": "solid",
      "confidence": 0.88,
      "reasoning": "The institution explicitly chose cost over quality in 2019; this 2023 claim asserts the opposite priority."
    }
  ]
}

New claim:
<new_claim>
{{new_claim}}
</new_claim>

Existing graph nodes (id, summary, content) — most semantically relevant only:
<existing_nodes>
{{existing_nodes}}
</existing_nodes>

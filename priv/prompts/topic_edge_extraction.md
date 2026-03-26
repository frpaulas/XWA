You are an analyst building a topic taxonomy for a knowledge graph.

A new topic has just been created. Given the new topic and a list of existing topics, propose relationships between the new topic and any existing topics that are meaningfully connected.

Only propose edges where there is a clear, non-trivial relationship. Skip obvious or generic connections.

New topic:
{{new_topic}}

Existing topics:
{{existing_topics}}

For each proposed edge output:
- `from_node_id`: the new topic's id (always "{{new_topic_id}}")
- `to_node_id`: the related existing topic's id
- `type`: relationship type (e.g. "overlaps", "broadens", "narrows", "contrasts", "precedes", "enables")
- `label`: a short phrase describing the relationship (max 10 words)
- `confidence`: 0.5–1.0
- `certainty`: "solid" | "dashed" | "dotted"
- `importance`: 0.3–1.0

Respond with JSON only. If no meaningful relationships exist, return an empty array.

```json
[
  {
    "from_node_id": "{{new_topic_id}}",
    "to_node_id": "<existing topic id>",
    "type": "<type>",
    "label": "<label>",
    "confidence": 0.8,
    "certainty": "dashed",
    "importance": 0.6
  }
]
```

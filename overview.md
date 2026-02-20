# XWA — Institutional Knowledge Explorer
## Project Overview for Claude Code

---

## Vision

XWA is an AI-assisted knowledge graph application for capturing, sharing, and exploring **institutional culture and dogma**. Its core premise is that institutions articulate a great deal about themselves — in policy documents, strategy papers, meeting minutes, sermons, memos, and external analyses — and that this corpus contains buried value that gets lost over time. XWA makes that value explorable.

The initial test case is **sermon corpora** from a single religious institution, which provides a rich, well-structured domain for validating the architecture. The long-term goal is applicability across knowledge domains: engineering organisations, legal firms, newsrooms, research institutions, corporate strategy teams.

A guiding ethnographic instinct informs design decisions even if full ethnographic capability is a long-term goal.

---

## Core Problem

Institutions tend to **believe their own bullshit**. Official documents are aspirational — they describe what an institution wants to believe about itself, not necessarily what is actually happening. The gap between aspirational self-description and recorded reality is where the most valuable information lives. XWA is designed to surface that friction rather than smooth it over.

A representative query the system should be able to answer: *"Why did we decide to use aluminum instead of titanium?"* — a decision provenance question where the reasoning was live at the time of decision, encoded in documents, but has since been buried under subsequent decisions. The answer is likely diffuse across multiple documents and time periods.

---

## Conceptual Architecture

### The Unit of Capture: Claims, Not Documents

Documents are containers. The atomic unit in XWA is the **claim** — an assertion extracted from a document. Documents become provenance metadata for claims, not the primary data structure.

### Three Corpus Layers

XWA triangulates between three distinct knowledge types, and the friction between them is the primary source of insight:

1. **Institutional self-description** — aspirational documents, strategy papers, official communications. Politically shaped, often incomplete about pain points.
2. **Internal record** — meeting minutes, decision logs, post-mortems, the messier recorded reality.
3. **External context** — supply chain analyses, market reports, domain research, regulatory documents. Serves as reality check against institutional claims.

### Graph Structure

The knowledge graph has two primary entities: nodes (claims) and edges (relationships between claims).

**Nodes** encode:
- The claim itself
- Source document and document type
- Temporal position (when the claim was made)
- Confidence gradient (0.0–1.0 composite score)
- Epistemic status (AI-inferred vs. human-validated)
- Source-type metadata (internal/external, aspirational/operational)

**Node visual encoding:**
- **Size** → number of edges (connectivity as proxy for institutional importance)
- **Color** → perceived reliability / confidence

**Edges** encode the relationship between claims. See Edge Data Structure below.

**Edge visual encoding:**
- **Color** → importance of the relationship
- **Line style** → certainty of the relationship (solid / dashed / dotted)

### Ontology: Emergent and Domain-Specific

Claim types and edge types are **not fixed schemas**. They emerge from the domain and the content. This is a deliberate design choice: a fixed schema would impose the institution's own categories on the data, replicating the bullshit problem at the structural level. New relationship types appear as strings; the system accumulates vocabulary organically.

---

## Edge Data Structure (Starting Point)

```elixir
%Edge{
  # Identity
  id: uuid,
  from_node_id: uuid,
  to_node_id: uuid,

  # Relationship semantics
  type: string,          # emergent, domain-specific label
  label: string,         # human readable description
  directed: boolean,     # some relationships are bidirectional

  # Visual encoding
  importance: float,     # 0.0-1.0, drives color
  certainty: enum,       # :solid | :dashed | :dotted

  # Epistemic metadata
  confidence: float,     # 0.0-1.0, composite score
  ai_inferred: boolean,
  human_validated: boolean,
  contested: boolean,    # divergent user judgments flagged here

  # Provenance
  source_document_ids: [uuid],   # can span multiple documents
  established_at: datetime,       # when the relationship came into being
  extracted_at: datetime,         # when XWA captured it

  # Audit
  created_by: uuid,
  validated_by: [uuid],
  notes: text            # human annotation
}
```

Key design decisions embedded in this structure:

- `directed` is explicit because some relationships are asymmetric ("supports" runs one way; "tensions" may be bidirectional)
- `source_document_ids` is a list because a relationship evidenced across multiple documents carries stronger grounds for confidence than a single source
- `contested` is separate from `confidence` — not low confidence but active disagreement among users, which is signal worth surfacing not averaging away
- `type` as plain string rather than enum implements the emergent ontology choice

---

## Confidence and Epistemic Status

### Confidence Gradient (not binary)

AI-extracted claims and relationships are provisional by default. Confidence is a float, visually represented, that improves through human review over time. The graph becomes more trustworthy through use rather than requiring upfront review.

### Source Grading

Sources themselves carry reliability metadata, capturing:
- **Institutional credibility** — is this a reliable source type generally?
- **Contextual integrity** — was this produced under conditions that might distort it? (e.g., regulatory documents from politically captured agencies)
- **Internal consistency** — does it conflict with other sources from the same period?

### Self-Policing Mechanism

Users can adjust confidence on both nodes and sources. The graph becomes a collective epistemic judgment. Disagreement between users is flagged via the `contested` field and surfaces as a signal rather than being resolved by averaging.

---

## Ingestion Pipeline

### New Documents (User-Created)
User reviews and modifies AI analysis at low cost — they have context and ownership. High-confidence extraction is appropriate.

### Historical Documents
Nobody owns these; context-holders may be gone; organizational scale may mean thousands of documents. Strategy: **conservative extraction** (fewer claims at higher confidence rather than flooding the graph with plausible noise) with **provisional epistemic status** by default. Historical nodes are visually distinguished. Confidence improves opportunistically as users with relevant context validate in passing.

The system must be honest about partially-validated historical graph regions rather than presenting false confidence.

### Document Ingestion Flow (Proposed)
1. AI extracts candidate claims from document
2. AI proposes candidate edges to existing graph nodes
3. User reviews candidates, confirming/rejecting/reweighting proposed edges
4. Claims and edges enter graph with appropriate confidence and epistemic status
5. AI synthesis across graph available as a separate capability (growth phase)

---

## User Experience Model

### One Mode, Two Entry Points

There is no hard distinction between "search" and "explore." Targeted queries return a starting node or short list — an entry point into the graph. Serendipitous exploration starts from a different kind of entry point. The graph does the rest either way.

This means the answer to a targeted question like "why aluminum?" is not a retrieved answer but a **traversal starting point**. The full answer may be diffuse across the graph.

### Departmental Views / Lenses

Different parts of an institution (engineering vs. C-suite) have different relevance filters over the same underlying graph. The value is that they share a graph — cross-domain friction between an engineering constraint node and a strategic claim should be visible to both. Separate graphs would silo exactly the signal XWA is designed to surface.

Implementation: views or lenses over a single graph rather than separate graph instances.

---

## Technology Decisions

### Stack
- **Elixir / Phoenix LiveView** — core application
- **Graph database** — TBD; evaluating FalkorDB and Neo4j (AGE ruled out due to performance ceiling at ~100 nodes)

### Graph Database Evaluation Criteria
- Concurrent read performance (maps onto Elixir's process model)
- Deep traversal at scale
- Cypher or compatible query language
- Operational simplicity
- Licensing

Neo4j handles concurrent reads well and has a clustering story; FalkorDB is Redis-based and single-threaded per graph (Elixir concurrency hits serialization at the DB layer). **Memgraph** is also worth evaluating — Neo4j-compatible Cypher, good concurrent workload performance, cleaner open source licensing.

### Elixir Concurrency and Graph Traversal
Graph traversal maps well onto concurrent processes. When a user explores from a node, parallel tasks can traverse each edge direction simultaneously, with results streaming back to LiveView as they arrive. The graph feels alive during exploration rather than loading.

### Deployment
Fly.io under consideration.

---

## What This Is Not

- Not a document search system (documents are provenance, not the primary data)
- Not a single-mode query/answer tool (queries are entry points, not terminals)
- Not a system that imposes a fixed ontology on institutional knowledge
- Not a system that presents AI inference as validated fact

---

## Current Status

Clean slate. XWA supersedes SWA (Sermon Writing Assistant), which accumulated design debt from a less clearly defined problem. The data model — particularly the node and edge structures and their epistemic metadata — should be validated against concrete test cases (e.g., a hand-built graph of sermon claims answering a specific provenance question) before application code is written on top of it.

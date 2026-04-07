# Knowledge Index

Product Console's persistent, compounding PM knowledge graph.

Not RAG. Not a search tool bolted onto your existing mess.

The LLM compiles raw PM artifacts into a structured, interlinked wiki that gets richer
with every decision your team makes. Exposed via MCP so every AI tool in your stack
can query your product history through a single protocol.

## The Architecture

Three layers (per Karpathy's LLM Wiki pattern, implemented in Elixir):

```
Raw Sources (immutable)     →   Knowledge Index (compiled)   →   MCP Server (queryable)
PRDs, transcripts,              Entities, relationships,         Claude, Cursor, agents,
feedback, analytics,            wiki pages, contradictions,      inline editor context,
decisions, outcomes             synthesis, outcomes              Drift Agent, Discovery Agent
```

The wiki is a persistent, compounding artifact. Raw sources → compiled once →
kept current. Not re-derived on every query.

## Stack

- Elixir / OTP — concurrent ingestion, fault-tolerant supervision
- Phoenix — HTTP API + WebSocket for real-time wiki updates
- PostgreSQL — entities, relationships, wiki pages, log
- pgvector — semantic search over wiki pages
- MCP server — exposes Knowledge Index to any compatible AI client
- Oban — background job processing for ingest/lint pipelines

## Operations

- **Ingest** — new artifact enters, LLM compiles it into wiki pages, updates index
- **Query** — semantic + structural search, answers filed back as wiki pages
- **Lint** — periodic health check: contradictions, orphans, stale claims
- **Watch** — real-time: artifact changes trigger targeted wiki updates

## Running

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

MCP server starts on port 4001 alongside Phoenix.

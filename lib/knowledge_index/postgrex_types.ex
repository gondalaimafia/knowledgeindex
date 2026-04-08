Postgrex.Types.define(KnowledgeIndex.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  [])

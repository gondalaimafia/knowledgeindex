defmodule KnowledgeIndex.Pipeline.IndexRebuild do
  @moduledoc """
  Deferred index rebuild worker.

  Instead of rebuilding the index synchronously after every ingest,
  this worker runs on a separate low-priority queue with uniqueness
  constraints that debounce multiple ingests into a single rebuild.

  This means pages appear in the wiki immediately after DB insert,
  and the index catches up within seconds.
  """

  use Oban.Worker, queue: :index_rebuild, max_attempts: 3

  alias KnowledgeIndex.Index

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id}}) do
    Logger.info("[IndexRebuild] Rebuilding index for workspace #{workspace_id}")

    case Index.rebuild(workspace_id) do
      {:ok, count} ->
        Logger.info("[IndexRebuild] Rebuilt index with #{count} entries for workspace #{workspace_id}")
        :ok

      {:error, reason} ->
        Logger.error("[IndexRebuild] Failed to rebuild index for workspace #{workspace_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

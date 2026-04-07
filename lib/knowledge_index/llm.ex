defmodule KnowledgeIndex.LLM do
  @moduledoc """
  LLM client — Claude Sonnet for completion, text-embedding-3-small for embeddings.

  Two models, two jobs:
  - Completion: Claude claude-sonnet-4-5 for wiki compilation, query synthesis, lint analysis
  - Embedding: OpenAI text-embedding-3-small for semantic search (1536 dims)

  Alex's principle: the AI layer sits on top of the knowledge infrastructure.
  The LLM is the programmer. The wiki is the codebase. The infrastructure is sovereign.
  """

  @claude_model "claude-sonnet-4-5"
  # Using Claude for embeddings via voyage-3 (Anthropic's embedding API)
  @embedding_model "voyage-3"
  @embedding_dims 1024

  def complete(prompt, opts \\ []) do
    system = Keyword.get(opts, :system, "You are a helpful assistant.")
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body = %{
      model: @claude_model,
      max_tokens: max_tokens,
      system: system,
      messages: [%{role: "user", content: prompt}]
    }

    case Req.post("https://api.anthropic.com/v1/messages",
      json: body,
      headers: [
        {"x-api-key", api_key()},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]
    ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def embed(text) do
    body = %{
      input: text,
      model: @embedding_model
    }

    case Req.post("https://api.voyageai.com/v1/embeddings",
      json: body,
      headers: [
        {"authorization", "Bearer #{voyage_key()}"},
        {"content-type", "application/json"}
      ]
    ) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp api_key, do: Application.fetch_env!(:knowledge_index, :anthropic_api_key)
  defp voyage_key, do: Application.fetch_env!(:knowledge_index, :voyage_api_key)
end

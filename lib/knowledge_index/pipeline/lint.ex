defmodule KnowledgeIndex.Pipeline.Lint do
  use Oban.Worker, queue: :lint, max_attempts: 2

  alias KnowledgeIndex.{Repo, Wiki, LLM, Log}
  alias KnowledgeIndex.Schema.WikiPage

  import Ecto.Query

  require Logger

  @moduledoc """
  Periodic wiki health check.

  Per Karpathy: Look for contradictions, stale claims, orphan pages,
  important concepts lacking their own page, missing cross-references.

  In Product Console, lint also detects:
  - Outcome pages with predictions but no actual data (T+30 overdue)
  - Decision pages that were superseded by newer decisions
  - Feature pages with no linked outcome page (shipped but untracked)

  This is the maintenance loop that humans would never do themselves.
  The LLM doesn't get bored.
  """

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id}}) do
    with {:ok, pages} <- Wiki.all_pages(workspace_id),
         {:ok, report} <- run_lint(pages),
         {:ok, _} <- apply_lint_fixes(workspace_id, report),
         {:ok, _} <- Log.append(workspace_id, :lint, "Lint pass", %{
           contradictions_found: length(report.contradictions),
           orphan_pages: length(report.orphans),
           stale_pages: length(report.stale),
           missing_outcome_pages: length(report.missing_outcomes),
           suggestions: report.suggestions
         }) do
      :ok
    else
      {:error, reason} ->
        Logger.error("[Lint] Failed for workspace #{workspace_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_lint(pages) do
    orphans = find_orphans(pages)
    stale = find_stale(pages)
    missing_outcomes = find_missing_outcomes(pages)

    prompt = build_lint_prompt(pages, orphans, stale, missing_outcomes)

    case LLM.complete(prompt, system: lint_system_prompt()) do
      {:ok, response} -> parse_lint_report(response, orphans, stale, missing_outcomes)
      {:error, _} = err -> err
    end
  end

  defp find_orphans(pages) do
    all_slugs = MapSet.new(pages, & &1.slug)

    pages
    |> Enum.filter(fn page ->
      # No other page links to this one
      page.slug not in [:index, :log] and
        not Enum.any?(pages, fn other ->
          page.slug in other.outbound_links
        end)
    end)
    |> Enum.map(& &1.slug)
  end

  defp find_stale(pages) do
    cutoff = DateTime.add(DateTime.utc_now(), -30, :day)

    pages
    |> Enum.filter(fn page ->
      page.page_type in ["entity", "concept"] and
        DateTime.compare(page.updated_at, cutoff) == :lt and
        page.source_count > 0
    end)
    |> Enum.map(& &1.slug)
  end

  defp find_missing_outcomes(pages) do
    feature_slugs =
      pages
      |> Enum.filter(&(&1.page_type == "entity"))
      |> Enum.map(& &1.slug)

    outcome_linked_slugs =
      pages
      |> Enum.filter(&(&1.page_type == "outcome"))
      |> Enum.flat_map(& &1.outbound_links)
      |> MapSet.new()

    Enum.reject(feature_slugs, &MapSet.member?(outcome_linked_slugs, &1))
  end

  defp build_lint_prompt(pages, orphans, stale, missing_outcomes) do
    index_text =
      pages
      |> Enum.map(&"- [[#{&1.slug}]] (#{&1.page_type}) — #{&1.summary}")
      |> Enum.join("\n")

    """
    You are health-checking a PM knowledge wiki.

    ## Wiki index
    #{index_text}

    ## Pre-detected issues
    Orphan pages (no inbound links): #{Enum.join(orphans, ", ")}
    Potentially stale pages (not updated in 30+ days): #{Enum.join(stale, ", ")}
    Feature pages with no outcome page: #{Enum.join(missing_outcomes, ", ")}

    ## Your task
    Review the wiki and identify:
    1. Contradictions between pages (conflicting claims about the same topic)
    2. Important concepts mentioned across pages but lacking their own page
    3. Missing cross-references that would improve navigation
    4. Questions worth investigating (new sources to look for)

    Return JSON:
    {
      "contradictions": [
        {
          "page_a": "slug-a",
          "page_b": "slug-b",
          "description": "Page A says X, Page B says Y"
        }
      ],
      "missing_pages": [
        {
          "suggested_slug": "concept-feedback-loop",
          "suggested_title": "Feedback Loop",
          "reason": "Referenced in 6 pages but no dedicated concept page exists"
        }
      ],
      "missing_links": [
        {
          "from_slug": "feature-smart-notifications",
          "to_slug": "metric-dau-d7",
          "reason": "Feature is tracked by this metric but not linked"
        }
      ],
      "investigation_suggestions": [
        "What happened to DAU after Smart Notifications shipped? No outcome page exists."
      ]
    }
    """
  end

  defp lint_system_prompt do
    """
    You are auditing a PM knowledge wiki for a product team.
    Your job is to find gaps, contradictions, and missing connections.
    Be specific and actionable. Every item you flag should be fixable.
    Focus on product-relevant issues — not style or formatting.
    """
  end

  defp parse_lint_report(response, orphans, stale, missing_outcomes) do
    case Jason.decode(response) do
      {:ok, data} ->
        {:ok, %{
          contradictions: Map.get(data, "contradictions", []),
          orphans: orphans,
          stale: stale,
          missing_outcomes: missing_outcomes,
          missing_pages: Map.get(data, "missing_pages", []),
          missing_links: Map.get(data, "missing_links", []),
          suggestions: Map.get(data, "investigation_suggestions", [])
        }}
      {:error, _} ->
        {:ok, %{contradictions: [], orphans: orphans, stale: stale,
                missing_outcomes: missing_outcomes, missing_pages: [],
                missing_links: [], suggestions: []}}
    end
  end

  defp apply_lint_fixes(workspace_id, report) do
    Repo.transaction(fn ->
      # Mark stale pages
      Enum.each(report.stale, fn slug ->
        case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug) do
          nil -> :ok
          page ->
            page |> WikiPage.changeset(%{stale: true}) |> Repo.update!()
        end
      end)

      # Flag contradictions
      Enum.each(report.contradictions, fn %{"page_a" => slug_a, "description" => desc} ->
        case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug_a) do
          nil -> :ok
          page ->
            updated = [desc | page.contradictions] |> Enum.uniq() |> Enum.take(20)
            page |> WikiPage.changeset(%{contradictions: updated}) |> Repo.update!()
        end
      end)

      # Add missing cross-references
      Enum.each(report.missing_links, fn %{"from_slug" => from, "to_slug" => to} ->
        case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: from) do
          nil -> :ok
          page ->
            unless to in page.outbound_links do
              updated = [to | page.outbound_links]
              page |> WikiPage.changeset(%{outbound_links: updated}) |> Repo.update!()
            end
        end
      end)

      report
    end)
  end
end

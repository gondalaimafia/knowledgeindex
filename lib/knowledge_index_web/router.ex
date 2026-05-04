defmodule KnowledgeIndexWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", KnowledgeIndexWeb do
    pipe_through :api

    post "/query", KIController, :query
    post "/ingest", KIController, :ingest
    get "/search", KIController, :search
    get "/index", KIController, :index
    get "/sources", KIController, :sources
    get "/sources/:id", KIController, :source_detail
    post "/lint", KIController, :lint
    get "/health", KIController, :health
  end
end

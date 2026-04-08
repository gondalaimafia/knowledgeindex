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
    post "/lint", KIController, :lint
    get "/health", KIController, :health
  end
end

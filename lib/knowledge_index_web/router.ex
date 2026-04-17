defmodule KnowledgeIndexWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", KnowledgeIndexWeb do
    pipe_through :browser

    get "/", DashboardController, :index
  end

  scope "/api", KnowledgeIndexWeb do
    pipe_through :api

    post "/query", KIController, :query
    post "/ingest", KIController, :ingest
    get "/search", KIController, :search
    get "/index", KIController, :index
    post "/lint", KIController, :lint
    get "/health", KIController, :health
    get "/stats", KIController, :stats
    get "/logs", KIController, :logs
    post "/requeue", KIController, :requeue
    post "/cancel-jobs", KIController, :cancel_jobs
    post "/reset-workspace", KIController, :reset_workspace
  end
end

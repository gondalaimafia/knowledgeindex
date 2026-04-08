defmodule KnowledgeIndexWeb.DashboardController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    dashboard_path = Application.app_dir(:knowledge_index, "priv/static/dashboard.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, dashboard_path)
  end
end

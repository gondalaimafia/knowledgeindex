defmodule KnowledgeIndexWeb.DashboardController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    # In a release, priv files are at Application.app_dir
    # In dev, they're at priv/static relative to project root
    dashboard_path =
      case :code.priv_dir(:knowledge_index) do
        {:error, _} -> Path.join(["priv", "static", "dashboard.html"])
        priv_dir -> Path.join([to_string(priv_dir), "static", "dashboard.html"])
      end

    if File.exists?(dashboard_path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, dashboard_path)
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, fallback_dashboard_html())
    end
  end

  defp fallback_dashboard_html do
    ~s"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Knowledge Index</title>
      <style>
        body { font-family: 'Space Grotesk', system-ui, sans-serif; background: #111111; color: #fff; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
        .msg { text-align: center; }
        .msg h1 { color: #01969E; font-size: 24px; }
        .msg p { color: #8A8A8A; font-size: 14px; }
        .msg a { color: #01696F; }
      </style>
    </head>
    <body>
      <div class="msg">
        <h1>Knowledge Index</h1>
        <p>Dashboard file not found. API is running at <a href="/api/health">/api/health</a></p>
      </div>
    </body>
    </html>
    """
  end
end

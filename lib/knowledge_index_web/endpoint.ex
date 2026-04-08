defmodule KnowledgeIndexWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :knowledge_index

  plug Plug.Static,
    at: "/",
    from: {:knowledge_index, "priv/static"},
    gzip: false,
    only: ~w(dashboard.html assets favicon.png)

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug KnowledgeIndexWeb.Router
end

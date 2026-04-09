defmodule KnowledgeIndexWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :knowledge_index

  plug Plug.Static,
    at: "/static",
    from: {:knowledge_index, "priv/static"},
    gzip: false

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json", "text/html"],
    json_decoder: Jason

  plug KnowledgeIndexWeb.Router
end

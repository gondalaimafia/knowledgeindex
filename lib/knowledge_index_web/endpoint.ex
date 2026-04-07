defmodule KnowledgeIndexWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :knowledge_index

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug KnowledgeIndexWeb.Router
end

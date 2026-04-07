defmodule KnowledgeIndex.MCP.Protocol do
  @moduledoc """
  MCP JSON-RPC 2.0 response builders.
  """

  @protocol_version "2024-11-05"
  @server_name "knowledge-index"
  @server_version "0.1.0"

  def initialize_response(id) do
    result(%{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{
        "tools" => %{"listChanged" => false},
        "resources" => %{"subscribe" => false, "listChanged" => false}
      },
      "serverInfo" => %{
        "name" => @server_name,
        "version" => @server_version
      }
    }, id)
  end

  def tools_list_response(id, tools) do
    result(%{"tools" => tools}, id)
  end

  def tool_result_response(id, tool_result) do
    result(tool_result, id)
  end

  def resources_list_response(id, resources) do
    result(%{"resources" => resources}, id)
  end

  def resource_result_response(id, resource_result) do
    result(resource_result, id)
  end

  def error_response(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => error_code(code),
        "message" => message
      }
    }
  end

  defp result(data, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => data
    }
  end

  defp error_code(:method_not_found), do: -32601
  defp error_code(:invalid_params), do: -32602
  defp error_code(:internal_error), do: -32603
  defp error_code(_), do: -32000
end

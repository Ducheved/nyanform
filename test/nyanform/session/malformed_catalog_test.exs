defmodule Nyanform.Session.MalformedCatalogTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nyanform.Protocol.Message
  alias Nyanform.Session.Thread

  test "isolates malformed entries and keeps the session alive" do
    session_id = start_session("entries")
    on_exit(fn -> Thread.stop(session_id) end)

    assert {:reply, response} = list_tools(session_id, "list-1")
    assert [%{"name" => "healthy"}] = response.result["tools"]

    assert {:reply, repeated} = list_tools(session_id, "list-2")
    assert [%{"name" => "healthy"}] = repeated.result["tools"]
  end

  test "returns a controlled error for a non-list tools value" do
    session_id = start_session("non-list")
    on_exit(fn -> Thread.stop(session_id) end)

    assert {:reply, response} = list_tools(session_id, "list-1")
    assert response.error.code == -32_603
    assert :ok = Thread.touch(session_id)
  end

  defp start_session(mode) do
    session_id = "malformed-catalog-#{mode}-#{System.unique_integer([:positive])}"

    upstream_config = %{
      transport: :stdio,
      command: ["node", "test/fixtures/malformed_catalog_server.js", mode],
      endpoint: nil,
      env: %{},
      env_allowlist: [],
      timeout_ms: 5_000,
      max_message_size: 1_048_576
    }

    assert {:ok, _pid} =
             Thread.initialize(session_id, upstream_config, "canonical", :compatible)

    session_id
  end

  defp list_tools(session_id, id) do
    Thread.handle_downstream(session_id, Message.request(id, "tools/list", %{}))
  end
end

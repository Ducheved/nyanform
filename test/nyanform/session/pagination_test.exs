defmodule Nyanform.Session.PaginationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nyanform.Protocol.Message
  alias Nyanform.Session.Thread

  test "forwards the cursor and keeps aliases from earlier pages callable" do
    session_id = "pagination-#{System.unique_integer([:positive])}"

    upstream_config = %{
      transport: :stdio,
      command: ["node", "test/fixtures/paginated_server.js"],
      endpoint: nil,
      env: %{},
      env_allowlist: [],
      timeout_ms: 5_000,
      max_message_size: 1_048_576
    }

    assert {:ok, _pid} =
             Thread.initialize(session_id, upstream_config, "canonical", :compatible)

    on_exit(fn -> Thread.stop(session_id) end)

    assert {:reply, first_page} =
             Thread.handle_downstream(
               session_id,
               Message.request("list-1", "tools/list", %{})
             )

    assert first_page.result["nextCursor"] == "page-2"
    assert [%{"name" => first_alias}] = first_page.result["tools"]

    assert {:reply, second_page} =
             Thread.handle_downstream(
               session_id,
               Message.request("list-2", "tools/list", %{"cursor" => "page-2"})
             )

    assert [%{"name" => second_alias}] = second_page.result["tools"]
    assert second_alias != first_alias

    assert {:reply, repeated_page} =
             Thread.handle_downstream(
               session_id,
               Message.request("list-3", "tools/list", %{"cursor" => "page-2"})
             )

    assert [%{"name" => ^second_alias}] = repeated_page.result["tools"]

    assert {:reply, call_response} =
             Thread.handle_downstream(
               session_id,
               Message.request("call-1", "tools/call", %{
                 "name" => first_alias,
                 "arguments" => %{}
               })
             )

    assert [%{"text" => "called collision name", "type" => "text"}] =
             call_response.result["content"]

    assert {:reply, second_call_response} =
             Thread.handle_downstream(
               session_id,
               Message.request("call-2", "tools/call", %{
                 "name" => second_alias,
                 "arguments" => %{}
               })
             )

    assert [%{"text" => "called collision_name", "type" => "text"}] =
             second_call_response.result["content"]
  end

  test "bounds the accumulated live catalog" do
    session_id = "pagination-limit-#{System.unique_integer([:positive])}"

    upstream_config = %{
      transport: :stdio,
      command: ["node", "test/fixtures/paginated_server.js"],
      endpoint: nil,
      env: %{},
      env_allowlist: [],
      timeout_ms: 5_000,
      max_message_size: 1_048_576
    }

    assert {:ok, _pid} =
             Thread.initialize(
               session_id,
               upstream_config,
               "canonical",
               :compatible,
               %{include: nil, exclude: nil},
               max_tool_count: 1
             )

    on_exit(fn -> Thread.stop(session_id) end)

    assert {:reply, first} =
             Thread.handle_downstream(session_id, Message.request("list-1", "tools/list", %{}))

    assert first.result["nextCursor"] == "page-2"

    assert {:reply, limited} =
             Thread.handle_downstream(
               session_id,
               Message.request("list-2", "tools/list", %{"cursor" => "page-2"})
             )

    assert limited.error.code == -32_603
    assert :ok = Thread.touch(session_id)
  end
end

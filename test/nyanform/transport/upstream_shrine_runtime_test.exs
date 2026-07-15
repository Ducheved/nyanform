defmodule Nyanform.Transport.UpstreamShrineRuntimeTest do
  use ExUnit.Case, async: false

  alias Nyanform.Transport.UpstreamShrine

  @fixture ["node", "test/fixtures/env_server.js"]
  @parent_env ~w(NYANFORM_ARBITRARY API_KEY DATABASE_URL)

  setup do
    original = Map.take(System.get_env(), @parent_env)

    on_exit(fn ->
      Enum.each(@parent_env, &System.delete_env/1)
      Enum.each(original, fn {key, value} -> System.put_env(key, value) end)
    end)

    :ok
  end

  test "unsets non-allowlisted inherited variables" do
    System.put_env("NYANFORM_ARBITRARY", "parent-arbitrary")
    System.put_env("API_KEY", "parent-api")
    System.put_env("DATABASE_URL", "parent-database")

    environment = initialize_environment(nil, [])

    assert environment["arbitrary"] == nil
    assert environment["apiKey"] == nil
    assert environment["databaseUrl"] == nil
  end

  test "inherits only allowlisted variables and explicit values win" do
    System.put_env("NYANFORM_ARBITRARY", "parent-arbitrary")
    System.put_env("API_KEY", "parent-api")
    System.put_env("DATABASE_URL", "parent-database")

    inherited = initialize_environment(nil, ["API_KEY"])
    assert inherited["apiKey"] == "parent-api"
    assert inherited["arbitrary"] == nil
    assert inherited["databaseUrl"] == nil

    configured = initialize_environment(%{"API_KEY" => "configured-api"}, ["API_KEY"])
    assert configured["apiKey"] == "configured-api"
    assert configured["arbitrary"] == nil
    assert configured["databaseUrl"] == nil
  end

  test "uses configured timeout for stdio initialization" do
    config = stdio_config(%{"MCP_DELAY_MS" => "200"}, [], 25)
    {:ok, pid} = UpstreamShrine.start_link(config)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = UpstreamShrine.initialize(pid)
    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 500

    UpstreamShrine.stop(pid)
  end

  test "retains configured timeout for HTTP requests" do
    config = %{
      transport: :http,
      command: nil,
      endpoint: "http://127.0.0.1:9",
      env: nil,
      env_allowlist: [],
      timeout_ms: 321
    }

    {:ok, pid} = UpstreamShrine.start_link(config)
    assert :sys.get_state(pid).config.timeout_ms == 321
    UpstreamShrine.stop(pid)
  end

  defp initialize_environment(env, allowlist) do
    {:ok, pid} = UpstreamShrine.start_link(stdio_config(env, allowlist, 5_000))
    assert {:ok, message} = UpstreamShrine.initialize(pid)
    UpstreamShrine.stop(pid)
    message.result["serverInfo"]["environment"]
  end

  defp stdio_config(env, allowlist, timeout_ms) do
    %{
      transport: :stdio,
      command: @fixture,
      endpoint: nil,
      env: env,
      env_allowlist: allowlist,
      timeout_ms: timeout_ms
    }
  end
end

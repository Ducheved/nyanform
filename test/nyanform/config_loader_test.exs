defmodule Nyanform.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias Nyanform.Config.Loader

  @base %{
    "upstream" => %{"transport" => "stdio", "command" => ["node", "server.js"]}
  }

  test "loads validated defaults and propagates upstream runtime options" do
    config =
      Map.merge(@base, %{
        "downstream" => %{
          "transport" => "http",
          "allowedOrigins" => ["https://client.example"]
        },
        "envAllowlist" => ["API_KEY"],
        "timeoutMs" => 123,
        "maxMessageSize" => 456,
        "maxHttpBodySize" => 789,
        "logging" => "verbose",
        "toolInclude" => ["one"]
      })

    assert {:ok, loaded} = Loader.load_map(config)
    assert loaded.env_allowlist == ["API_KEY"]
    assert loaded.downstream.allowed_origins == ["https://client.example"]
    assert loaded.timeout_ms == 123
    assert loaded.max_message_size == 456
    assert loaded.max_http_body_size == 789
    assert loaded.logging == :verbose
    assert loaded.tool_include == ["one"]

    upstream = Loader.to_upstream_config(loaded)
    assert upstream.timeout_ms == 123
    assert upstream.env_allowlist == ["API_KEY"]
    assert upstream.max_message_size == 456
  end

  test "returns errors for malformed top-level scalar values" do
    for value <- [nil, [], 42, "config"] do
      assert {:error, {:invalid_config, ^value}} = Loader.load_map(value)
    end
  end

  test "returns errors for malformed bounded and structured fields" do
    invalid = [
      {"envAllowlist", "API_KEY"},
      {"envAllowlist", ["API_KEY", 42]},
      {"timeoutMs", 0},
      {"timeoutMs", "100"},
      {"maxMessageSize", -1},
      {"maxHttpBodySize", nil},
      {"logging", "trace"},
      {"toolInclude", "one"},
      {"toolExclude", ["one", 2]}
    ]

    for {key, value} <- invalid do
      assert {:error, _reason} = Loader.load_map(Map.put(@base, key, value))
    end
  end

  test "returns errors for malformed downstream values" do
    invalid = [
      nil,
      [],
      %{},
      %{"transport" => "http", "port" => 0},
      %{"transport" => "http", "port" => 65_536},
      %{"transport" => "http", "host" => ""},
      %{"transport" => "http", "host" => 42},
      %{"transport" => "http", "allowedOrigins" => "https://example.com"},
      %{"transport" => "http", "allowedOrigins" => ["https://example.com", 42]}
    ]

    for downstream <- invalid do
      config =
        if downstream == nil,
          do: Map.put(@base, "downstream", []),
          else: Map.put(@base, "downstream", downstream)

      assert {:error, _reason} = Loader.load_map(config)
    end
  end

  test "returns errors for malformed upstream command and environment" do
    invalid = [
      %{"transport" => "stdio"},
      %{"transport" => "stdio", "command" => []},
      %{"transport" => "stdio", "command" => [""]},
      %{"transport" => "stdio", "command" => ["node", 42]},
      %{"transport" => "stdio", "command" => ["node"], "env" => []},
      %{"transport" => "stdio", "command" => ["node"], "env" => %{"API_KEY" => 42}},
      %{"transport" => "stdio", "command" => ["node"], "endpoint" => "https://example.com"},
      %{"transport" => "http"},
      %{"transport" => "http", "endpoint" => ""},
      %{"transport" => "http", "endpoint" => 42},
      %{"transport" => "http", "endpoint" => "https://example.com", "command" => ["node"]}
    ]

    for upstream <- invalid do
      assert {:error, _reason} = Loader.load_map(%{"upstream" => upstream})
    end
  end

  test "load_file handles decoded non-object JSON without raising" do
    path =
      Path.join(System.tmp_dir!(), "nyanform-config-#{System.unique_integer([:positive])}.json")

    File.write!(path, "[]")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_config, []}} = Loader.load_file(path)
  end
end

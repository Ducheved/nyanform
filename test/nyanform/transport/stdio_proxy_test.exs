defmodule Nyanform.Transport.StdioProxyTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @fixture_server ["node", "test/fixtures/mcp_server.js"]
  @push_server ["node", "test/fixtures/push_server.js"]

  describe "stdio to stdio proxy" do
    test "proxies initialize and tools/list" do
      input = """
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      {"jsonrpc":"2.0","method":"notifications/initialized"}
      {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
      """

      {output, 0} = run_proxy(input, @fixture_server, "canonical")

      lines = String.split(output, "\n", trim: true)
      assert length(lines) >= 2

      init_response = find_response(lines, "1")
      assert init_response["result"]["protocolVersion"] == "2025-11-25"
      assert init_response["result"]["serverInfo"]["name"] == "nyanform"

      tools_response = find_response(lines, "2")
      tools = tools_response["result"]["tools"]
      assert length(tools) == 10
    end

    test "proxies tools/call through alias mapping" do
      input = """
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      {"jsonrpc":"2.0","method":"notifications/initialized"}
      {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
      {"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"portable_tool","arguments":{"message":"hello proxy"}}}
      """

      {output, 0} = run_proxy(input, @fixture_server, "canonical")

      lines = String.split(output, "\n", trim: true)
      call_response = find_response(lines, "3")
      assert call_response["result"]["content"] != nil
      [content | _] = call_response["result"]["content"]
      assert String.contains?(content["text"], "hello proxy")
    end

    test "repairs nested JSON string arguments" do
      input = """
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      {"jsonrpc":"2.0","method":"notifications/initialized"}
      {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
      {"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"nested_json_tool","arguments":{"config":"{\\"key\\":\\"k\\",\\"value\\":\\"v\\"}"}}}
      """

      {output, 0} = run_proxy(input, @fixture_server, "canonical")

      lines = String.split(output, "\n", trim: true)
      call_response = find_response(lines, "3")
      [content | _] = call_response["result"]["content"]
      assert String.contains?(content["text"], "k")
      assert String.contains?(content["text"], "v")
    end

    test "strict profile hides projection-incompatible tools and blocks direct calls" do
      input = """
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      {"jsonrpc":"2.0","method":"notifications/initialized"}
      {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
      {"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"union_tool","arguments":{}}}
      """

      {output, 0} = run_proxy(input, @fixture_server, "openai_strict")
      lines = String.split(output, "\n", trim: true)
      tools = find_response(lines, "2")["result"]["tools"]
      names = Enum.map(tools, & &1["name"])

      refute "union_tool" in names
      refute "invalid_array_tool" in names

      call_response = find_response(lines, "3")
      assert call_response["error"]["code"] == -32_601
    end
  end

  describe "stdout protocol purity" do
    test "stdout contains only JSON-RPC messages" do
      input = """
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      """

      {output, _exit} = run_proxy(input, @fixture_server, "canonical")

      lines = String.split(output, "\n", trim: true)

      for line <- lines do
        assert String.starts_with?(line, "{\"")
        assert Jason.decode!(line)
      end
    end
  end

  describe "malformed JSON-RPC handling" do
    test "one malformed line does not corrupt later frames" do
      input = """
      not valid json
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      """

      {output, _exit} = run_proxy(input, @fixture_server, "canonical")

      lines = String.split(output, "\n", trim: true)
      assert length(lines) >= 2

      error_response = find_response(lines, nil)
      assert error_response["error"] != nil

      init_response = find_response(lines, "1")
      assert init_response["result"]["protocolVersion"] == "2025-11-25"
    end
  end

  describe "graceful shutdown" do
    test "shuts down cleanly on EOF" do
      input = """
      {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
      """

      {output, exit_code} = run_proxy(input, @fixture_server, "canonical")
      assert exit_code == 0
      assert String.contains?(output, "protocolVersion")
    end
  end

  describe "server initiated messages" do
    test "drains upstream notifications before EOF shutdown" do
      input =
        """
        {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
        """

      {output, 0} = run_proxy(input, @push_server, "canonical")

      messages =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(messages, &(&1["method"] == "notifications/progress"))
    end
  end

  defp run_proxy(input, command, profile) do
    suffix = :erlang.unique_integer([:positive])
    tmp_input = Path.join(System.tmp_dir!(), "nyanform_test_#{suffix}.txt")
    tmp_runner = Path.join(System.tmp_dir!(), "nyanform_test_#{suffix}.exs")
    cli_args = proxy_args(command, profile)

    File.write!(tmp_input, input)
    File.write!(tmp_runner, runner_script(cli_args))

    try do
      run_with_redirected_input(tmp_input, tmp_runner)
    after
      File.rm(tmp_input)
      File.rm(tmp_runner)
    end
  end

  defp proxy_args(command, profile) do
    [
      "serve",
      "--stdio-command",
      Enum.at(command, 0),
      "--stdio-arg",
      Enum.at(command, 1),
      "--profile",
      profile
    ]
  end

  defp runner_script(cli_args) do
    "Application.ensure_all_started(:nyanform)\n" <>
      "System.halt(Nyanform.CLI.main(" <> inspect(cli_args) <> "))\n"
  end

  defp run_with_redirected_input(input_path, runner_path) do
    if windows?() do
      run_windows_redirect(input_path, runner_path)
    else
      command =
        "cat #{shell_quote(input_path)} | #{shell_quote(mix_executable())} run --no-compile #{shell_quote(runner_path)}"

      System.cmd("sh", ["-c", command], command_options())
    end
  end

  defp run_windows_redirect(input_path, runner_path) do
    command_path = input_path <> ".cmd"

    command =
      "@echo off\n" <>
        "type " <>
        windows_quote(input_path) <>
        " | call " <>
        windows_quote(mix_executable()) <>
        " run --no-compile " <> windows_quote(runner_path) <> "\nexit /b %errorlevel%\n"

    File.write!(command_path, command)

    try do
      System.cmd("cmd.exe", ["/d", "/s", "/c", command_path], command_options())
    after
      File.rm(command_path)
    end
  end

  defp command_options do
    [stderr_to_stdout: false, env: %{"MIX_ENV" => "test"}, cd: File.cwd!()]
  end

  defp mix_executable do
    name = if windows?(), do: "mix.bat", else: "mix"

    System.find_executable(name) ||
      Path.expand(Path.join(["..", "..", "bin", name]), List.to_string(:code.lib_dir(:mix)))
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp windows_quote(value) do
    value = String.replace(value, "/", "\\")
    ~s|"#{String.replace(value, "\"", "\"\"")}"|
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp find_response(lines, id) do
    lines
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, parsed} -> parsed
        {:error, _} -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
    |> Enum.find(fn msg ->
      case id do
        nil -> msg["error"] != nil
        _ -> msg["id"] == id
      end
    end)
  end
end

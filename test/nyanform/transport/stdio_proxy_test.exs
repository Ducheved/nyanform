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
    test "forwards upstream notifications while stdin remains idle" do
      input =
        ~s|{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n|

      {output, 0} =
        run_proxy(input, @push_server, "canonical", hold_open_seconds: 3)

      messages =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(messages, &(&1["method"] == "notifications/progress"))
    end
  end

  defp run_proxy(input, command, profile, opts \\ []) do
    suffix = :erlang.unique_integer([:positive])
    tmp_input = Path.join(System.tmp_dir!(), "nyanform_test_#{suffix}.txt")
    tmp_runner = Path.join(System.tmp_dir!(), "nyanform_test_#{suffix}.exs")
    cli_args = proxy_args(command, profile)

    File.write!(tmp_input, input)
    File.write!(tmp_runner, runner_script(cli_args))

    try do
      run_with_redirected_input(
        tmp_input,
        tmp_runner,
        Keyword.get(opts, :hold_open_seconds, 0)
      )
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

  defp run_with_redirected_input(input_path, runner_path, hold_open_seconds) do
    if windows?() do
      run_windows_redirect(input_path, runner_path, hold_open_seconds)
    else
      input_command = unix_input_command(input_path, hold_open_seconds)

      command =
        "#{input_command} | #{shell_quote(mix_executable())} run #{shell_quote(runner_path)}"

      System.cmd("sh", ["-c", command], command_options())
    end
  end

  defp run_windows_redirect(input_path, runner_path, hold_open_seconds) do
    command_path = input_path <> ".cmd"
    input_command = windows_input_command(input_path, hold_open_seconds)

    command =
      "@echo off\n" <>
        input_command <>
        " | call " <>
        windows_quote(mix_executable()) <>
        " run " <> windows_quote(runner_path) <> "\nexit /b %errorlevel%\n"

    File.write!(command_path, command)

    try do
      System.cmd("cmd.exe", ["/d", "/s", "/c", command_path], command_options())
    after
      File.rm(command_path)
    end
  end

  defp windows_input_command(input_path, 0), do: "type #{windows_quote(input_path)}"

  defp windows_input_command(input_path, seconds) do
    Enum.join(
      [
        windows_quote(node_executable()),
        windows_quote(Path.expand("test/fixtures/hold_stdin.js")),
        windows_quote(input_path),
        Integer.to_string(seconds)
      ],
      " "
    )
  end

  defp unix_input_command(input_path, 0), do: "cat #{shell_quote(input_path)}"

  defp unix_input_command(input_path, seconds) do
    Enum.join(
      [
        shell_quote(node_executable()),
        shell_quote(Path.expand("test/fixtures/hold_stdin.js")),
        shell_quote(input_path),
        Integer.to_string(seconds)
      ],
      " "
    )
  end

  defp node_executable, do: System.find_executable("node") || "node"

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

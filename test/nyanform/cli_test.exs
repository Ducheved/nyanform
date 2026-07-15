defmodule Nyanform.CLITest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @fixture_server ["node", "test/fixtures/mcp_server.js"]

  describe "doctor" do
    test "returns exit code 0" do
      assert 0 == run_cli(["doctor"])
    end

    test "rejects unexpected arguments" do
      {_output, exit_code} = run_cli_with_exit(["doctor", "unexpected"])
      assert exit_code == 2
    end
  end

  describe "help" do
    test "returns exit code 0 and prints help" do
      output = capture_cli(["--help"])
      assert String.contains?(output, "Nyanform")
      assert String.contains?(output, "serve")
      assert String.contains?(output, "inspect")
    end

    test "each command has focused help" do
      for command <- ~w(serve inspect matrix snapshot check doctor) do
        {output, exit_code} = run_cli_with_exit([command, "--help"])
        assert exit_code == 0
        assert String.contains?(output, "Usage: nyanform #{command}")
      end
    end
  end

  describe "inspect" do
    test "returns exit code 0 and prints a report" do
      output =
        capture_cli([
          "inspect",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1)
        ])

      assert String.contains?(output, "Nyanform Inspect Report")
      assert String.contains?(output, "nyanform-fixture-server")
      assert String.contains?(output, "Tools:          10")
    end

    test "supports JSON format" do
      output =
        capture_cli([
          "inspect",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--format",
          "json"
        ])

      parsed = Jason.decode!(output)
      assert parsed["server_info"]["name"] == "nyanform-fixture-server"
      assert parsed["tool_count"] == 10
    end

    test "applies the selected profile" do
      output =
        capture_cli([
          "inspect",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--profile",
          "gemini",
          "--format",
          "json"
        ])

      parsed = Jason.decode!(output)
      assert parsed["omens"] != []
      assert Enum.all?(parsed["omens"], &(&1["profile"] == "gemini"))
    end

    test "rejects unsupported report formats" do
      {_output, exit_code} = run_cli_with_exit(["inspect", "--format", "junit"])
      assert exit_code == 2
    end
  end

  describe "matrix" do
    test "returns exit code 1 when strict profile rejects tools" do
      exit_code =
        run_cli([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1)
        ])

      assert exit_code == 1
    end

    test "returns exit code 0 with permissive policy" do
      exit_code =
        run_cli([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--policy",
          "permissive",
          "--profile",
          "canonical",
          "--profile",
          "passthrough"
        ])

      assert exit_code == 0
    end

    test "terminal output contains profile rows" do
      output =
        capture_cli([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1)
        ])

      assert String.contains?(output, "canonical")
      assert String.contains?(output, "claude")
      assert String.contains?(output, "openai_strict")
    end

    test "JSON output is valid JSON" do
      output =
        capture_cli([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--format",
          "json"
        ])

      parsed = Jason.decode!(output)
      assert length(parsed["results"]) == 6
    end

    test "SARIF output is valid SARIF 2.1.0" do
      output =
        capture_cli([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--format",
          "sarif"
        ])

      parsed = Jason.decode!(output)
      assert parsed["version"] == "2.1.0"
      assert length(parsed["runs"]) == 1
    end

    test "JUnit output is valid XML" do
      output =
        capture_cli([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--format",
          "junit"
        ])

      assert String.starts_with?(output, "<?xml")
      assert String.contains?(output, "<testsuites")
    end

    test "fail-on-lossy is independent of rejected projections" do
      {_output, exit_code} =
        run_cli_with_exit([
          "matrix",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--profile",
          "gemini",
          "--no-fail-on-rejected",
          "--fail-on-lossy",
          "--format",
          "json"
        ])

      assert exit_code == 1
    end

    test "rejects an unknown profile without crashing" do
      {_output, exit_code} = run_cli_with_exit(["matrix", "--profile", "unknown"])
      assert exit_code == 2
    end
  end

  describe "snapshot" do
    test "creates a deterministic snapshot" do
      path1 = tmp_path("snapshot1.json")
      path2 = tmp_path("snapshot2.json")

      run_cli([
        "snapshot",
        "--stdio-command",
        Enum.at(@fixture_server, 0),
        "--stdio-arg",
        Enum.at(@fixture_server, 1),
        "--output",
        path1
      ])

      run_cli([
        "snapshot",
        "--stdio-command",
        Enum.at(@fixture_server, 0),
        "--stdio-arg",
        Enum.at(@fixture_server, 1),
        "--output",
        path2
      ])

      {:ok, content1} = File.read(path1)
      {:ok, content2} = File.read(path2)

      assert content1 == content2

      parsed = Jason.decode!(content1)
      assert parsed["server_info"]["name"] == "nyanform-fixture-server"
      assert length(parsed["tools"]) == 10

      File.rm(path1)
      File.rm(path2)
    end
  end

  describe "check" do
    test "detects no changes when comparing to identical snapshot" do
      snapshot_path = tmp_path("check_snapshot.json")

      {_output, _exit} =
        run_cli_with_exit([
          "snapshot",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--output",
          snapshot_path
        ])

      {_check_output, check_exit} =
        run_cli_with_exit([
          "check",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--snapshot",
          snapshot_path
        ])

      assert check_exit == 0

      File.rm(snapshot_path)
    end

    test "returns non-zero for missing snapshot" do
      exit_code =
        run_cli([
          "check",
          "--stdio-command",
          Enum.at(@fixture_server, 0),
          "--stdio-arg",
          Enum.at(@fixture_server, 1),
          "--snapshot",
          "nonexistent.json"
        ])

      assert exit_code == 1
    end
  end

  describe "invalid configuration" do
    test "returns exit code 1 for missing upstream" do
      {_output, exit_code} = run_cli_with_exit(["inspect"])
      assert exit_code == 1
    end

    test "returns exit code 2 for an unknown option" do
      {_output, exit_code} = run_cli_with_exit(["inspect", "--formt", "json"])
      assert exit_code == 2
    end
  end

  defp run_cli(args) do
    {output, exit_code} = run_cli_with_exit(args)

    cond do
      exit_code != 0 -> exit_code
      String.contains?(output, "error") or String.contains?(output, "FAIL") -> 1
      true -> 0
    end
  end

  defp capture_cli(args) do
    {output, _exit} = run_cli_with_exit(args)
    output
  end

  defp run_cli_with_exit(args) do
    {:ok, io_pid} = StringIO.open("")
    original_gl = Process.group_leader()
    Process.group_leader(self(), io_pid)

    exit_code =
      try do
        Application.ensure_all_started(:nyanform)
        Nyanform.CLI.main(args)
      rescue
        e ->
          IO.write(io_pid, "error: #{Exception.message(e)}")
          1
      catch
        :exit, reason ->
          IO.write(io_pid, "exit: #{inspect(reason)}")
          1
      after
        Process.group_leader(self(), original_gl)
      end

    {:ok, {_, output}} = StringIO.close(io_pid)
    {output, exit_code || 0}
  end

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "nyanform_#{name}")
  end
end

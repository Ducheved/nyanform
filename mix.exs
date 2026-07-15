defmodule Nyanform.MixProject do
  use Mix.Project

  @version "0.1.0"
  @mcp_protocol_revision "2025-11-25"

  def project do
    [
      app: :nyanform,
      version: @version,
      elixir: "~> 1.18",
      erlang: "~> 27",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      package: package(),
      releases: releases(),
      escript: escript(),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [
      preferred_envs: [
        quality: :test,
        "test.all": :test,
        ci: :test,
        dialyzer: :test,
        credo: :dev
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Nyanform.Application, []},
      env: env()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]

  defp env do
    [
      protocol_revision: @mcp_protocol_revision,
      max_message_size: 1_048_576,
      max_schema_depth: 64,
      max_reference_depth: 32,
      max_tool_count: 1024,
      max_concurrent_compilation: 8,
      max_http_body_size: 4_194_304,
      max_diagnostic_count: 4096,
      request_timeout_ms: 30_000
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.3"},
      {:stream_data, "~> 1.1", only: [:test, :dev], runtime: false},
      {:credo, "~> 1.7", only: [:test, :dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:test, :dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "nyanform.no_comments",
        "credo --strict",
        "test"
      ],
      "test.all": ["test --include property:true"],
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "nyanform.no_comments",
        "credo --strict",
        "test --include property:true",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      name: "nyanform",
      description:
        "Inspect and adapt MCP tool schemas across client boundaries with a local-first compatibility proxy.",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/Ducheved/nyanform"}
    ]
  end

  defp releases do
    [
      nyanform: [
        include_executables_for: [:unix, :windows],
        applications: [nyanform: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end

  defp escript do
    [
      main_module: Nyanform.Release,
      path: "nyanform"
    ]
  end

  defp dialyzer do
    [
      list_unused_filters: true,
      plt_add_apps: [:mix, :eex],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end

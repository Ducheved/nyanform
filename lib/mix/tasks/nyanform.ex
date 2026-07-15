defmodule Mix.Tasks.Nyanform do
  use Mix.Task

  @shortdoc "Run the Nyanform CLI"

  @impl true
  def run(args) do
    Application.ensure_all_started(:nyanform)
    exit_code = Nyanform.CLI.main(args)

    case exit_code do
      0 -> :ok
      code -> Mix.raise("nyanform exited with code #{code}")
    end
  end
end

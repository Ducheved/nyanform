defmodule Nyanform.Release do
  @spec main([String.t()]) :: no_return()
  def main(args) do
    Application.ensure_all_started(:nyanform)
    exit_code = Nyanform.CLI.main(args)
    System.halt(exit_code)
  end
end

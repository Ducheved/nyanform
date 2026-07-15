defmodule Nyanform.Diagnostic.CodesTest do
  use ExUnit.Case, async: true

  alias Nyanform.Diagnostic.Codes

  test "every diagnostic code referenced by runtime modules is registered" do
    referenced =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "diagnostic/codes.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/NYA-[A-Z]+-[0-9]{3}/, &1))
        |> List.flatten()
      end)
      |> MapSet.new()

    registered = Codes.all() |> Map.keys() |> MapSet.new()
    assert MapSet.subset?(referenced, registered)
  end
end

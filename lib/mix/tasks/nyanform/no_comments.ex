defmodule Mix.Tasks.Nyanform.NoComments do
  use Mix.Task

  @shortdoc "Check that first-party source contains no comments or documentation attributes"

  @impl true
  def run(_args) do
    Mix.Task.run("compile", [])

    violations = collect_violations()

    if violations == [] do
      Mix.shell().info("no-comments: no violations found")
      :ok
    else
      Mix.shell().error("no-comments: #{length(violations)} violation(s) found")

      Enum.each(violations, fn violation ->
        Mix.shell().error("  #{violation.file}:#{violation.line}: #{violation.message}")
      end)

      Mix.raise("no-comments check failed with #{length(violations)} violation(s)")
    end
  end

  def collect_violations do
    elixir_files = discover_elixir_files()
    non_elixir_files = discover_non_elixir_files()

    elixir_violations = Enum.flat_map(elixir_files, &check_elixir_file/1)
    non_elixir_violations = Enum.flat_map(non_elixir_files, &check_non_elixir_file/1)

    elixir_violations ++ non_elixir_violations
  end

  defp discover_elixir_files do
    base = File.cwd!()

    ~w(lib config test priv rel)
    |> Enum.flat_map(fn dir ->
      path = Path.join(base, dir)

      if File.dir?(path) do
        Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      else
        []
      end
    end)
    |> Enum.reject(&excluded?/1)
  end

  defp discover_non_elixir_files do
    base = File.cwd!()

    ~w(scripts Dockerfile docker-compose.yml .github)
    |> Enum.flat_map(fn path ->
      full = Path.join(base, path)

      cond do
        File.regular?(full) -> [full]
        File.dir?(full) -> Path.wildcard(Path.join(full, "**/*"))
        true -> []
      end
    end)
    |> Enum.filter(&non_elixir_checkable?/1)
  end

  defp excluded?(path) do
    String.contains?(path, "/deps/") or String.contains?(path, "/_build/") or
      String.contains?(path, "/.elixir_ls/") or String.contains?(path, "/priv/plts/")
  end

  defp non_elixir_checkable?(path) do
    ext = Path.extname(path)
    ext in [".yml", ".yaml", ".sh", ".dockerfile"] or String.ends_with?(path, "Dockerfile")
  end

  defp check_elixir_file(path) do
    case File.read(path) do
      {:ok, content} ->
        comment_violations = find_comment_violations(path, content)
        attr_violations = find_doc_attribute_violations(path, content)

        comment_violations ++ attr_violations

      {:error, _reason} ->
        []
    end
  end

  defp find_comment_violations(path, content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      cond do
        shebang_line?(line, line_num) ->
          []

        has_inline_comment?(line) ->
          [
            %{
              file: relative_path(path),
              line: line_num,
              message: "comment found: #{String.trim(line)}"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp shebang_line?(line, 1), do: String.starts_with?(String.trim(line), "#!")
  defp shebang_line?(_line, _line_num), do: false

  defp has_inline_comment?(line) do
    stripped = strip_strings_and_chars(line)
    index = find_hash_index(stripped, 0, false)
    index != nil
  end

  defp strip_strings_and_chars(line) do
    line
    |> String.replace(~r/\?(.)/, "?X")
    |> String.replace(~r/(?<!\\)"[^"]*(?<!\\)"/, "\"\"")
    |> String.replace(~r/(?<!\\)'[^']*(?<!\\)'/, "''")
  end

  defp find_hash_index(<<>>, _index, _in_string), do: nil

  defp find_hash_index(<<"\\\"", rest::binary>>, index, true),
    do: find_hash_index(rest, index + 2, true)

  defp find_hash_index(<<?", rest::binary>>, index, true),
    do: find_hash_index(rest, index + 1, false)

  defp find_hash_index(<<?", rest::binary>>, index, false),
    do: find_hash_index(rest, index + 1, true)

  defp find_hash_index(<<?#, _rest::binary>>, index, false), do: index

  defp find_hash_index(<<_char, rest::binary>>, index, in_string),
    do: find_hash_index(rest, index + 1, in_string)

  defp find_hash_index(_, _, _), do: nil

  defp find_doc_attribute_violations(path, content) do
    case Code.string_to_quoted(content, columns: true) do
      {:ok, ast} ->
        find_doc_attrs_in_ast(path, ast)

      {:error, _reason} ->
        []
    end
  end

  defp find_doc_attrs_in_ast(path, ast) do
    {_, violations} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{attr, _, _} | _]} = node, acc when attr in [:moduledoc, :doc, :typedoc] ->
          line = Keyword.get(meta, :line, 0)

          {node,
           [
             %{
               file: relative_path(path),
               line: line,
               message: "documentation attribute found: @#{attr}"
             }
             | acc
           ]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(violations)
  end

  defp check_non_elixir_file(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_num} ->
          cond do
            required_shebang?(path, line, line_num) ->
              []

            has_non_elixir_comment?(line, path) ->
              [
                %{
                  file: relative_path(path),
                  line: line_num,
                  message: "comment found: #{String.trim(line)}"
                }
              ]

            true ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp required_shebang?(path, line, 1) do
    ext = Path.extname(path)

    (ext == ".sh" or String.ends_with?(path, "scripts")) and
      String.starts_with?(String.trim(line), "#!")
  end

  defp required_shebang?(_path, _line, _line_num), do: false

  defp has_non_elixir_comment?(line, path) do
    trimmed = String.trim(line)
    ext = Path.extname(path)

    cond do
      ext in [".yml", ".yaml"] ->
        String.starts_with?(trimmed, "#") and not String.starts_with?(trimmed, "#!")

      ext == ".sh" ->
        String.starts_with?(trimmed, "#") and not String.starts_with?(trimmed, "#!")

      String.ends_with?(path, "Dockerfile") ->
        String.starts_with?(trimmed, "#")

      true ->
        false
    end
  end

  defp relative_path(path) do
    base = File.cwd!()
    String.replace_prefix(path, base <> "/", "")
  end
end

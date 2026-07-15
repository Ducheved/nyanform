defmodule Mix.Tasks.Nyanform.NoCommentsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Nyanform.NoComments

  describe "collect_violations with temporary files" do
    test "detects line comments in Elixir files" do
      with_tmp_file("test_file.ex", "defmodule Foo do\n  # this is a comment\nend\n", fn _path ->
        violations = NoComments.collect_violations()
        elixir_violations = Enum.filter(violations, &String.contains?(&1.file, "test_file.ex"))
        assert length(elixir_violations) >= 1
        assert Enum.any?(elixir_violations, &String.contains?(&1.message, "comment found"))
      end)
    end

    test "detects @moduledoc attributes" do
      with_tmp_file(
        "moduledoc_file.ex",
        "defmodule Bar do\n  @moduledoc false\nend\n",
        fn _path ->
          violations = NoComments.collect_violations()

          elixir_violations =
            Enum.filter(violations, &String.contains?(&1.file, "moduledoc_file.ex"))

          assert length(elixir_violations) >= 1

          assert Enum.any?(
                   elixir_violations,
                   &String.contains?(&1.message, "documentation attribute")
                 )
        end
      )
    end

    test "detects @doc attributes" do
      with_tmp_file(
        "doc_file.ex",
        "defmodule Baz do\n  @doc \"hello\"\n  def foo, do: :ok\nend\n",
        fn _path ->
          violations = NoComments.collect_violations()
          elixir_violations = Enum.filter(violations, &String.contains?(&1.file, "doc_file.ex"))
          assert length(elixir_violations) >= 1
        end
      )
    end

    test "does not flag clean files" do
      with_tmp_file("clean_file.ex", "defmodule Clean do\n  def foo, do: :ok\nend\n", fn _path ->
        violations = NoComments.collect_violations()
        clean_violations = Enum.filter(violations, &String.contains?(&1.file, "clean_file.ex"))
        assert clean_violations == []
      end)
    end

    test "permits required shebang in script files" do
      with_tmp_file("script_file.sh", "#!/usr/bin/env bash\necho hello\n", fn _path ->
        violations = NoComments.collect_violations()
        script_violations = Enum.filter(violations, &String.contains?(&1.file, "script_file.sh"))
        assert script_violations == []
      end)
    end

    test "detects comments in non-shebang scripts" do
      with_tmp_file_in_dir(
        "scripts",
        "bad_script.sh",
        "#!/usr/bin/env bash\n# a comment\necho hello\n",
        fn _path ->
          violations = NoComments.collect_violations()
          script_violations = Enum.filter(violations, &String.contains?(&1.file, "bad_script.sh"))
          assert length(script_violations) >= 1
        end
      )
    end

    test "does not flag # inside string literals" do
      with_tmp_file(
        "string_hash.ex",
        "defmodule Str do\n  def foo, do: \"has # inside\"\nend\n",
        fn _path ->
          violations = NoComments.collect_violations()

          string_violations =
            Enum.filter(violations, &String.contains?(&1.file, "string_hash.ex"))

          assert string_violations == []
        end
      )
    end
  end

  defp with_tmp_file(name, content, fun) do
    dir = Path.join(File.cwd!(), "test/tmp")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)

    try do
      fun.(path)
    after
      File.rm!(path)
      File.rmdir(dir)
    end
  end

  defp with_tmp_file_in_dir(dir_name, name, content, fun) do
    dir = Path.join(File.cwd!(), dir_name)
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)

    try do
      fun.(path)
    after
      File.rm!(path)

      try do
        File.rmdir(dir)
      rescue
        _ -> :ok
      end
    end
  end
end

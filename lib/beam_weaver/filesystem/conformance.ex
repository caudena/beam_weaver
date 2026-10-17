defmodule BeamWeaver.Filesystem.Conformance do
  @moduledoc """
  Checks to run from the tests of a filesystem backend you write.

  The file tools check permission rules against the path the model wrote and
  against the file it leads to, which the backend reports with
  `BeamWeaver.Filesystem.canonical_paths/3`. A backend whose storage has
  symlinks and doesn't report where they lead, or a wrapper that doesn't pass
  the call on to the backend it wraps, lets a link give a denied file an
  allowed name. `check_symlinks/3` catches that.
  """

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Permission

  @secret "beam-weaver-link-check-secret"
  @note "beam-weaver-link-check-note"

  @doc """
  Checks that permission rules see through `backend`'s symlinks.

  `backend` must be new and empty, and `make_link` a function that makes a
  symlink in its storage: `make_link.(link, target)` makes the backend path
  `link` lead to the backend path `target`.

  Under the `:dir` option (default `"/"`), the check writes `secrets/key.txt`
  and `notes/todo.md`, links `notes/key.txt` to `secrets/key.txt` and
  `notes/vault` to `secrets`, and gives the file tools a rule that denies
  `secrets/**`. Then reading, listing and searching the secret through the
  links must be denied, and so must writing and editing through them, while
  `notes/todo.md` and new files in `notes` stay allowed.

  Returns `:ok`, or `{:error, problems}` with a sentence for each problem.
  """
  @spec check_symlinks(Filesystem.t(), (String.t(), String.t() -> any()), keyword()) :: :ok | {:error, [String.t()]}
  def check_symlinks(backend, make_link, opts \\ []) when is_function(make_link, 2) do
    paths = paths(Keyword.get(opts, :dir, "/"))

    with :ok <- set_up(backend, make_link, paths) do
      rules = [Permission.new(paths: [paths.secrets <> "/**"], mode: :deny)]
      tools = Map.new(BeamWeaver.Tools.Filesystem.tools(backend, permissions: rules), &{Tool.name(&1), &1})

      problems =
        Enum.flat_map(
          [&resolved/3, &reads/3, &listings/3, &searches/3, &writes/3, &allowed_files/3],
          & &1.(backend, tools, paths)
        )

      if problems == [], do: :ok, else: {:error, problems}
    end
  end

  defp paths(dir) do
    dir = "/" <> String.trim(dir, "/")
    path = &Path.join(dir, &1)

    %{
      dir: dir,
      secrets: path.("secrets"),
      key: path.("secrets/key.txt"),
      secret_new: path.("secrets/new.txt"),
      notes: path.("notes"),
      todo: path.("notes/todo.md"),
      note_new: path.("notes/new.md"),
      key_link: path.("notes/key.txt"),
      vault: path.("notes/vault"),
      vault_key: path.("notes/vault/key.txt"),
      vault_new: path.("notes/vault/new.txt")
    }
  end

  ## Setting up

  defp set_up(backend, make_link, paths) do
    with :ok <- write(backend, paths.key, @secret),
         :ok <- write(backend, paths.todo, @note),
         :ok <- link(make_link, paths.key_link, paths.key),
         :ok <- link(make_link, paths.vault, paths.secrets),
         :ok <- leads_to_secret(backend, paths.key_link, paths.key) do
      leads_to_secret(backend, paths.vault_key, paths.key)
    end
  end

  defp write(backend, path, content) do
    case Filesystem.write(backend, path, content <> "\n") do
      %Filesystem.WriteResult{error: nil} ->
        :ok

      %Filesystem.WriteResult{error: error} ->
        {:error, ["couldn't write #{path} to set up the check: #{inspect(error)}"]}
    end
  end

  defp link(make_link, link, target) do
    make_link.(link, target)
    :ok
  rescue
    error -> {:error, ["make_link couldn't link #{link} to #{target}: #{Exception.message(error)}"]}
  end

  # Without a working link, every check below would pass for nothing.
  defp leads_to_secret(backend, path, target) do
    case Filesystem.read(backend, path) do
      %Filesystem.ReadResult{error: nil, file_data: %Filesystem.FileData{content: content}} when is_binary(content) ->
        if String.contains?(content, @secret),
          do: :ok,
          else: {:error, ["reading #{path} doesn't return #{target}: make_link made no link there"]}

      result ->
        {:error, ["reading #{path} doesn't return #{target}: make_link made no link there (#{inspect(result)})"]}
    end
  end

  ## Checks

  defp resolved(backend, _tools, paths) do
    expected = [
      {paths.key_link, paths.key},
      {paths.vault, paths.secrets},
      {paths.vault_key, paths.key},
      {paths.vault_new, paths.secret_new},
      {paths.todo, paths.todo}
    ]

    results = Filesystem.canonical_paths(backend, Enum.map(expected, &elem(&1, 0)))

    if is_list(results) and length(results) == length(expected) do
      for {{path, file}, result} <- Enum.zip(expected, results), result != {:ok, file} do
        "canonical_paths/3 returned #{inspect(result)} for #{path} instead of #{inspect({:ok, file})}"
      end
    else
      ["canonical_paths/3 returned #{inspect(results)} for #{length(expected)} paths"]
    end
  end

  defp reads(_backend, tools, paths) do
    Enum.flat_map([paths.key_link, paths.vault_key], fn path ->
      List.wrap(denied(tools, "read_file", %{"file_path" => path}, "Error: Permission denied reading #{path}"))
    end)
  end

  defp listings(_backend, tools, paths) do
    listed = listed(run(tools, "ls", %{"path" => paths.notes}))

    leaks =
      for path <- [paths.key_link, paths.vault], path in listed do
        "ls #{paths.notes} listed #{path}, which leads into #{paths.secrets}"
      end

    leaks ++ List.wrap(denied(tools, "ls", %{"path" => paths.vault}, "Error: Permission denied reading #{paths.vault}"))
  end

  defp searches(_backend, tools, paths) do
    globbed = listed(run(tools, "glob", %{"pattern" => "**/*", "path" => paths.dir}))

    denied = [
      {paths.secrets, "a rule denies"},
      {paths.key, "a rule denies"},
      {paths.key_link, "leads into #{paths.secrets}"},
      {paths.vault, "leads into #{paths.secrets}"},
      {paths.vault_key, "leads into #{paths.secrets}"}
    ]

    glob_leaks =
      for {path, why} <- denied, path in globbed do
        "glob **/* in #{paths.dir} returned #{path}, which #{why}"
      end

    grep_leaks =
      Enum.flat_map([paths.dir, paths.notes], fn path ->
        case listed(run(tools, "grep", %{"pattern" => @secret, "path" => path})) do
          [] -> []
          found -> ["grep in #{path} found the text of #{paths.key}, which a rule denies, in #{Enum.join(found, ", ")}"]
        end
      end)

    glob_leaks ++ grep_leaks
  end

  defp writes(backend, tools, paths) do
    written = run(tools, "write_file", %{"file_path" => paths.vault_new, "content" => "changed"})

    edited =
      run(tools, "edit_file", %{"file_path" => paths.key_link, "old_string" => @secret, "new_string" => "changed"})

    write_problem =
      cond do
        match?(%Filesystem.ReadResult{error: nil}, Filesystem.read(backend, paths.secret_new)) ->
          "write_file #{paths.vault_new} wrote #{paths.secret_new}, which a rule denies"

        written != "Error: Permission denied writing #{paths.vault_new}" ->
          "write_file #{paths.vault_new} wasn't denied: #{describe(written)}"

        true ->
          nil
      end

    edit_problem =
      cond do
        not String.contains?(content(backend, paths.key), @secret) ->
          "edit_file #{paths.key_link} changed #{paths.key}, which a rule denies"

        edited != "Error: Permission denied editing #{paths.key_link}" ->
          "edit_file #{paths.key_link} wasn't denied: #{describe(edited)}"

        true ->
          nil
      end

    Enum.reject([write_problem, edit_problem], &is_nil/1)
  end

  # What no rule denies must stay open, so a backend can't pass by denying
  # everything.
  defp allowed_files(_backend, tools, paths) do
    read = run(tools, "read_file", %{"file_path" => paths.todo})
    written = run(tools, "write_file", %{"file_path" => paths.note_new, "content" => "ok"})

    for {problem, true} <- [
          {"read_file #{paths.todo}, which no rule denies, returned #{inspect(read)}",
           not (is_binary(read) and String.contains?(read, @note))},
          {"ls #{paths.notes} left out #{paths.todo}, which no rule denies",
           paths.todo not in listed(run(tools, "ls", %{"path" => paths.notes}))},
          {"glob **/* in #{paths.dir} left out #{paths.todo}, which no rule denies",
           paths.todo not in listed(run(tools, "glob", %{"pattern" => "**/*", "path" => paths.dir}))},
          {"write_file #{paths.note_new}, which no rule denies, returned #{inspect(written)}",
           is_binary(written) and String.starts_with?(written, "Error:")}
        ],
        do: problem
  end

  ## Helpers

  # A problem when the tool call isn't the denial it should be.
  defp denied(tools, name, input, denial) do
    path = input["file_path"] || input["path"]

    case run(tools, name, input) do
      ^denial -> nil
      result -> "#{name} #{path} wasn't denied: #{describe(result)}"
    end
  end

  defp describe(result) when is_binary(result) do
    cond do
      String.contains?(result, @secret) -> "it returned the text of a file a rule denies"
      (listed = listed(result)) != [] -> "it listed #{Enum.join(listed, ", ")}"
      true -> "it returned #{inspect(result)}"
    end
  end

  defp describe(result), do: "it returned #{inspect(result)}"

  defp run(tools, name, input) do
    case Tool.invoke(Map.fetch!(tools, name), input) do
      {:ok, result} -> result
      error -> error
    end
  end

  # The paths in a JSON listing from `ls`, `glob` or `grep`; none for an error.
  defp listed(result) when is_binary(result) do
    case BeamWeaver.JSON.decode(result) do
      {:ok, entries} when is_list(entries) -> for %{"path" => path} <- entries, uniq: true, do: path
      _error -> []
    end
  end

  defp listed(_result), do: []

  defp content(backend, path) do
    case Filesystem.read(backend, path) do
      %Filesystem.ReadResult{error: nil, file_data: %Filesystem.FileData{content: content}} when is_binary(content) ->
        content

      _error ->
        ""
    end
  end
end

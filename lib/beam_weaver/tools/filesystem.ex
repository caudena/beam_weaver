defmodule BeamWeaver.Tools.Filesystem do
  @moduledoc """
  Agent filesystem tools (`ls`, `read_file`, `write_file`, `edit_file`, `glob`,
  `grep`, plus `execute` for executable backends) backed by a
  `BeamWeaver.Filesystem`.

  `ls`, `glob` and `grep` return a JSON list. A list longer than 80,000
  characters keeps the entries that fit and ends with a note that asks the
  model to narrow the search.

  `read_file` returns a file's text as it is. A read that stops short of the
  end of the file, at `limit` lines or 80,000 characters, ends with a note
  that gives the offset to read on from, and an `offset` past the last line is
  an error. An image (PNG, JPEG, GIF, WebP) or a PDF is a tool message whose
  content is a short text notice and an image or file block (see
  `BeamWeaver.Core.ContentBlock`); any other binary file is a short notice.

  `execute` returns the command's output followed by its exit code, such as
  `[Command failed with exit code 1]`, or an error that says the command timed
  out and was stopped. A command that ran is a tool message whose
  `metadata.exit_code` is the exit code as an integer, left out when the
  backend doesn't know it; a non-zero exit code is still a successful call,
  since the model reads the output.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Permission, as: FilesystemPermission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph.Command

  # The size at which other tool results move into a file (about 20,000
  # tokens), and room for the note that says a result was cut.
  @max_result_chars 80_000
  @truncation_note_chars 200
  @read_limit 2_000

  # A pattern written as a regex: `|`, `.*`, `.+` or an escaped metacharacter
  # or class. A bare `.`, `(`, `[`, `?`, `^` or `$` is left out, since literal
  # code searches such as `self.tools` or `arr[0]` have them.
  @regex_signal ~r/\||\.\*|\.\+|\\[.wWdDsSbB(){}\[\]|+*?^$]/

  @regex_note "Note: grep matches literal text, not regex, so characters like `|`, `.*` and `\\.` " <>
                "are searched as they are. Search for the literal text instead; for `|`, " <>
                "run a separate search for each alternative."

  # A search without `path` is checked against /, which the model may not
  # expect when its pattern names the directory it means.
  @pathless_notes %{
    "glob" =>
      "A glob without `path` is checked against /, not the directories in `pattern`. " <>
        "Retry with a `path` inside an allowed directory and a `pattern` relative to it.",
    "grep" => "A grep without `path` is checked against /. Retry with a `path` inside an allowed directory."
  }

  @media_types %{
    ".png" => {:image, "image/png"},
    ".jpg" => {:image, "image/jpeg"},
    ".jpeg" => {:image, "image/jpeg"},
    ".gif" => {:image, "image/gif"},
    ".webp" => {:image, "image/webp"},
    ".pdf" => {:file, "application/pdf"}
  }

  def tools(opts_or_backend, opts \\ [])

  def tools(opts, []) when is_list(opts) do
    opts
    |> Keyword.get(:backend, State.new())
    |> tools(Keyword.delete(opts, :backend))
  end

  def tools(backend, opts) do
    permissions = Keyword.get(opts, :permissions, [])
    state_key = Keyword.get(opts, :state_key, :files)

    [
      ls_tool(backend, permissions),
      read_tool(backend, permissions),
      write_tool(backend, permissions, state_key),
      edit_tool(backend, permissions, state_key),
      glob_tool(backend, permissions),
      grep_tool(backend, permissions)
    ]
    |> maybe_add_execute(backend)
  end

  defp ls_tool(backend, permissions) do
    tool(
      "ls",
      "List files and directories under an absolute virtual path.",
      %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string", "default" => "/"}},
        "required" => ["path"]
      },
      fn input, _opts ->
        path = value(input, :path, "/")
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :read, path, opts) do
          backend
          |> Filesystem.ls(path, opts)
          |> render_allowed(:entries, backend, permissions, opts, "List a more specific path to see the rest.")
        else
          "Error: Permission denied reading #{path}"
        end
      end
    )
  end

  defp read_tool(backend, permissions) do
    tool(
      "read_file",
      "Read a file by absolute virtual path with optional line pagination.",
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "offset" => %{"type" => "integer", "minimum" => 0, "default" => 0},
          "limit" => %{"type" => "integer", "minimum" => 1, "default" => @read_limit}
        },
        "required" => ["file_path"]
      },
      fn input, _opts ->
        path = value(input, :file_path) || value(input, :path)
        offset = value(input, :offset, 0)
        limit = value(input, :limit, @read_limit)
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :read, path, opts) do
          # One line more than the page shows tells whether the file goes on.
          result = Filesystem.read(backend, path, runtime_opts(input, offset: offset, limit: limit + 1))

          case result do
            %Filesystem.ReadResult{
              error: nil,
              file_data: %Filesystem.FileData{encoding: "base64"} = data
            } ->
              data.content |> to_string() |> binary_result(path, value(input, :tool_call_id))

            %Filesystem.ReadResult{error: nil, file_data: %Filesystem.FileData{content: content}}
            when content in [nil, ""] and offset > 0 ->
              past_end_error(backend, path, offset, opts)

            %Filesystem.ReadResult{error: nil, file_data: %Filesystem.FileData{} = data} ->
              {page, rest} = (data.content || "") |> String.split("\n") |> Enum.split(limit)
              render_page(page, offset, file_continues?(rest, backend, path, offset + limit, opts))

            %Filesystem.ReadResult{error: error} ->
              "Error: #{error}"
          end
        else
          "Error: Permission denied reading #{path}"
        end
      end
    )
  end

  # A page past the last line reads as empty, like an empty line or an empty
  # file, so the model would take it for content and stop paging.
  defp past_end_error(backend, path, offset, opts) do
    case file_line_count(backend, path, opts) do
      lines when is_integer(lines) and lines > 0 and offset >= lines ->
        "Error: offset #{offset} is past the end of #{path} (#{lines} #{if lines == 1, do: "line", else: "lines"})"

      _not_past_the_end ->
        ""
    end
  end

  # A blank line after the page may be only the newline that ends the file,
  # which some backends return as a line of its own, so the file decides.
  defp file_continues?([], _backend, _path, _read_lines, _opts), do: false

  defp file_continues?([""], backend, path, read_lines, opts) do
    case file_line_count(backend, path, opts) do
      lines when is_integer(lines) -> lines > read_lines
      nil -> true
    end
  end

  defp file_continues?(_rest, _backend, _path, _read_lines, _opts), do: true

  defp file_line_count(backend, path, opts) do
    case Filesystem.download_files(backend, [path], opts) do
      [%Filesystem.DownloadResult{error: nil, content: content}] when is_binary(content) -> line_count(content)
      _error -> nil
    end
  end

  # The file's text as it is, unless the page stops short of the end of the
  # file: then a note says where to read on, so the model doesn't take the
  # page for the whole file.
  defp render_page(lines, offset, continues?) do
    text = Enum.join(lines, "\n")

    if not continues? and String.length(text) <= @max_result_chars,
      do: text,
      else: cut_page(lines, offset, continues?)
  end

  defp cut_page(lines, offset, continues?) do
    budget = @max_result_chars - @truncation_note_chars

    case fitting_lines(lines, budget) do
      {[], [line | rest]} ->
        read_on = if continues? or rest != [], do: " The file continues: read again with offset #{offset + 1}."

        String.slice(line, 0, budget) <>
          "\n\n[Line #{offset + 1} is longer than 80,000 characters and was cut: " <>
          "read_file can't show the rest of it, but grep can search it.#{read_on}]"

      {shown, rest} ->
        last = offset + length(shown)
        cap = if rest != [], do: ": a read returns at most 80,000 characters"

        Enum.join(shown, "\n") <>
          "\n\n[Showing #{line_range(offset + 1, last)}#{cap}. The file continues: read again with offset #{last}.]"
    end
  end

  defp line_range(line, line), do: "line #{line}"
  defp line_range(first, last), do: "lines #{first}-#{last}"

  # Images and PDFs reach the model as blocks it can look at, after a short
  # notice. The base64 text of any other binary would only fill the context.
  defp binary_result(data, path, tool_call_id) do
    size = "#{base64_size(data)} bytes"

    case Map.get(@media_types, path |> Path.extname() |> String.downcase()) do
      {:image, mime_type} ->
        media_message(
          "File #{path} is an image (#{size}).",
          ContentBlock.image(data: data, mime_type: mime_type),
          tool_call_id
        )

      {:file, mime_type} ->
        media_message(
          "File #{path} is a PDF (#{size}).",
          ContentBlock.file(data: data, mime_type: mime_type, filename: Path.basename(path)),
          tool_call_id
        )

      nil ->
        "File #{path} is binary (#{size}) and can't be shown. " <>
          "read_file shows text files, images (PNG, JPEG, GIF, WebP) and PDFs."
    end
  end

  # A tool message keeps its content blocks, where a list the tool returns
  # would reach the model as JSON text.
  defp media_message(notice, block, tool_call_id) do
    Message.tool([ContentBlock.text(notice), block],
      tool_call_id: tool_call_id,
      name: "read_file",
      metadata: %{status: "success"}
    )
  end

  defp base64_size(data), do: div(byte_size(String.trim_trailing(data, "=")) * 3, 4)

  # The first lines that fit in `budget` characters with their line breaks,
  # and the lines left over.
  defp fitting_lines(lines, budget) do
    {count, _chars} =
      Enum.reduce_while(lines, {0, -1}, fn line, {count, chars} ->
        chars = chars + String.length(line) + 1
        if chars <= budget, do: {:cont, {count + 1, chars}}, else: {:halt, {count, chars}}
      end)

    Enum.split(lines, count)
  end

  # Lines as `read_file` counts them: a final newline ends the last line.
  defp line_count(""), do: 0

  defp line_count(content) do
    lines = content |> String.replace("\r\n", "\n") |> String.replace("\r", "\n") |> String.split("\n")
    if List.last(lines) == "", do: length(lines) - 1, else: length(lines)
  end

  defp write_tool(backend, permissions, state_key) do
    tool(
      "write_file",
      "Create or replace a file at an absolute virtual path. " <>
        "To change part of an existing file, use edit_file.",
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["file_path", "content"]
      },
      fn input, _opts ->
        path = value(input, :file_path) || value(input, :path)
        content = value(input, :content, "")
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :write, path, opts) do
          result = Filesystem.write(backend, path, content, opts)
          write_command("write_file", input, result, state_key, "Wrote #{path}")
        else
          "Error: Permission denied writing #{path}"
        end
      end
    )
  end

  defp edit_tool(backend, permissions, state_key) do
    tool(
      "edit_file",
      "Edit a UTF-8 text file using exact string replacement.",
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "old_string" => %{"type" => "string"},
          "new_string" => %{"type" => "string"},
          "replace_all" => %{"type" => "boolean", "default" => false}
        },
        "required" => ["file_path", "old_string", "new_string"]
      },
      fn input, _opts ->
        path = value(input, :file_path) || value(input, :path)

        if allowed?(backend, permissions, :write, path, runtime_opts(input)) do
          result =
            Filesystem.edit(
              backend,
              path,
              value(input, :old_string, ""),
              value(input, :new_string, ""),
              runtime_opts(input, replace_all: value(input, :replace_all, false))
            )

          write_command("edit_file", input, result, state_key, "Edited #{path}")
        else
          "Error: Permission denied editing #{path}"
        end
      end
    )
  end

  defp glob_tool(backend, permissions) do
    tool(
      "glob",
      "Find files matching a glob pattern.",
      %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" =>
              "A pattern without / matches file names at any depth below path (*.py); " <>
                "one with / matches the path from path (src/**/*.py), and a leading / only directly in path (/*.py). " <>
                "{a,b} matches either (*.{ts,tsx}) and [abc] one character of the class."
          },
          # Without a schema default, the handler can tell a missing `path`
          # from "/".
          "path" => %{"type" => "string", "description" => "The directory to search, / when left out."}
        },
        "required" => ["pattern"]
      },
      fn input, _opts ->
        path = value(input, :path, "/")
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :read, path, opts) do
          backend
          |> Filesystem.glob(value(input, :pattern), Keyword.put(opts, :path, path))
          |> render_allowed(
            :matches,
            backend,
            permissions,
            opts,
            "Narrow the search with a more specific path or pattern."
          )
        else
          denied_search_error("glob", path, value(input, :path))
        end
      end
    )
  end

  # The rules check `path`, so a pattern that names an allowed directory is
  # still denied when the model left `path` out and / is denied.
  defp denied_search_error(tool, path, nil), do: "Error: Permission denied reading #{path}. " <> @pathless_notes[tool]
  defp denied_search_error(_tool, path, _given), do: "Error: Permission denied reading #{path}"

  @doc false
  # The `execute` line is only for a model that is offered `execute`, so the
  # Filesystem middleware picks the description by the tools of each call.
  def grep_description(execute?) do
    "Search files for literal text, not a regex: `|`, `.*` and `\\.` in the pattern match those characters. " <>
      "To match any of several strings, run one grep for each." <>
      if(execute?, do: "\nFor a real regex, use execute with `rg '<regex>'`.", else: "")
  end

  defp grep_tool(backend, permissions) do
    tool(
      "grep",
      grep_description(Executable.executable?(backend)),
      %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          # Without a schema default, the handler can tell a missing `path`
          # from "/".
          "path" => %{"type" => "string", "description" => "The directory to search, / when left out."},
          "glob" => %{
            "type" => "string",
            "description" => "Only search files that match this glob, read as glob's pattern is (*.py, src/**/*.py)."
          }
        },
        "required" => ["pattern"]
      },
      fn input, _opts ->
        path = value(input, :path, "/")
        pattern = value(input, :pattern)
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :read, path, opts) do
          result = Filesystem.grep(backend, pattern, runtime_opts(input, path: path, glob: value(input, :glob)))

          result
          |> render_allowed(
            :matches,
            backend,
            permissions,
            opts,
            "Narrow the search with a more specific path, pattern or glob."
          )
          |> with_regex_note(result, pattern)
        else
          denied_search_error("grep", path, value(input, :path))
        end
      end
    )
  end

  # Only a search that found nothing at all gets the note: when the rules hid
  # every match, the pattern wasn't the problem.
  defp with_regex_note(text, %{error: nil, matches: matches}, pattern) when matches in [nil, []] do
    if regex_like?(pattern), do: text <> "\n\n" <> @regex_note, else: text
  end

  defp with_regex_note(text, _result, _pattern), do: text

  defp regex_like?(pattern) when is_binary(pattern), do: Regex.match?(@regex_signal, pattern)
  defp regex_like?(_pattern), do: false

  defp maybe_add_execute(tools, backend) do
    if Executable.executable?(backend) do
      tools ++
        [
          tool(
            "execute",
            "Execute a shell command inside the configured sandbox backend. " <>
              "Returns the command's output followed by its exit code.",
            %{
              "type" => "object",
              "properties" => %{
                "command" => %{"type" => "string"},
                "timeout" => %{"type" => "integer", "minimum" => 1, "maximum" => 3600}
              },
              "required" => ["command"]
            },
            fn input, _opts ->
              case normalize_timeout(value(input, :timeout)) do
                {:ok, opts} ->
                  backend
                  |> Executable.execute(value(input, :command, ""), opts)
                  |> execute_result(Keyword.get(opts, :timeout), value(input, :tool_call_id))

                {:error, error} ->
                  "Error: #{error}"
              end
            end
          )
        ]
    else
      tools
    end
  end

  # A command that ran answers with a tool message whose metadata has its exit
  # code, so code using the agent can check it without parsing the text. One
  # that didn't run, or timed out, answers with the error alone.
  defp execute_result(result, timeout, tool_call_id) do
    text = render_execute_result(result, timeout)

    if Map.get(result, :error) in [nil, ""] do
      Message.tool(text,
        tool_call_id: tool_call_id,
        name: "execute",
        metadata: execute_metadata(Map.get(result, :exit_code))
      )
    else
      text
    end
  end

  defp execute_metadata(exit_code) when is_integer(exit_code), do: %{status: "success", exit_code: exit_code}
  defp execute_metadata(_unknown), do: %{status: "success"}

  # The model needs the exit code to tell a failed command from one that
  # printed nothing, and a timeout must not look like empty output.
  defp render_execute_result(result, timeout) do
    output = Map.get(result, :output) || ""
    error = Map.get(result, :error)
    exit_code = Map.get(result, :exit_code)

    status =
      cond do
        error in ["timeout", :timeout] ->
          after_seconds =
            case timeout do
              nil -> ""
              1 -> " after 1 second"
              seconds -> " after #{seconds} seconds"
            end

          "Error: the command timed out#{after_seconds} and was stopped. " <>
            "Pass a larger `timeout` (in seconds, at most 3600) or run a shorter command."

        error not in [nil, ""] ->
          "Error: #{error_text(error)}"

        is_integer(exit_code) ->
          outcome = if exit_code == 0, do: "succeeded", else: "failed"
          truncated = if Map.get(result, :truncated) == true, do: "; output truncated", else: ""
          "[Command #{outcome} with exit code #{exit_code}#{truncated}]"

        true ->
          "[Command finished without an exit code]"
      end

    cond do
      output == "" -> status
      String.ends_with?(output, "\n") -> output <> status
      true -> output <> "\n" <> status
    end
  end

  defp error_text(error) when is_binary(error), do: error
  defp error_text(%{message: message}) when is_binary(message), do: message
  defp error_text(error), do: inspect(error)

  defp tool(name, description, schema, handler) do
    Tool.from_function!(
      name: name,
      description: description,
      input_schema: schema,
      injected: %{state: :state, tool_call_id: :tool_call_id, tool_runtime: :tool_runtime},
      handler: handler,
      metadata: %{integration: :deepagents}
    )
  end

  # The entries of a listing or search that the model may read: those whose
  # path, and the file it leads to, the rules allow.
  defp render_allowed(%{error: nil} = result, field, backend, permissions, opts, narrow) do
    entries = Map.get(result, field) || []

    allowed =
      permissions
      |> FilesystemPermission.filter_paths(:read, Enum.map(entries, & &1.path), backend, opts)
      |> MapSet.new()

    entries
    |> Enum.filter(&MapSet.member?(allowed, &1.path))
    |> Enum.map(&(&1 |> json_entry() |> BeamWeaver.JSON.encode!()))
    |> json_list(narrow)
  end

  defp render_allowed(%{error: error}, _field, _backend, _permissions, _opts, _narrow), do: "Error: #{error}"

  defp json_entry(%{__struct__: _struct} = entry), do: Map.from_struct(entry)
  defp json_entry(entry), do: entry

  # These results are never moved into a file, so a search over many files
  # keeps the entries that fit and says how to narrow it.
  defp json_list(encoded, narrow) do
    json = json_array(encoded)

    if String.length(json) <= @max_result_chars do
      json
    else
      shown = fitting_entries(encoded, @max_result_chars - @truncation_note_chars)

      json_array(shown) <>
        "\n\n[Results truncated: showing the first #{length(shown)} of #{length(encoded)} results. #{narrow}]"
    end
  end

  defp json_array(encoded), do: "[" <> Enum.join(encoded, ",") <> "]"

  defp fitting_entries(encoded, budget) do
    encoded
    |> Enum.reduce_while({[], 2}, fn entry, {shown, chars} ->
      chars = chars + String.length(entry) + 1
      if chars <= budget, do: {:cont, {[entry | shown], chars}}, else: {:halt, {shown, chars}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp write_command(
         tool_name,
         input,
         %{error: nil, files_update: files_update} = result,
         state_key,
         success
       ) do
    content =
      case Map.get(result, :occurrences) do
        nil -> success
        occurrences -> "#{success}; replaced #{occurrences} occurrence(s)"
      end

    message = Message.tool(content, tool_call_id: value(input, :tool_call_id), name: tool_name)

    if is_map(files_update) do
      %Command{update: %{state_key => files_update, messages: [message]}}
    else
      message
    end
  end

  defp write_command(_tool_name, _input, %{error: error}, _state_key, _success),
    do: "Error: #{error}"

  defp runtime_opts(input, extra \\ []) do
    base = [
      state: value(input, :state, %{}),
      store: input |> value(:tool_runtime) |> runtime_value(:store),
      runtime: input |> value(:tool_runtime) |> runtime_value(:runtime)
    ]

    Keyword.merge(base, Enum.reject(extra, fn {_key, value} -> is_nil(value) end))
  end

  defp runtime_value(runtime, key) when is_map(runtime), do: Map.get(runtime, key)
  defp runtime_value(_runtime, _key), do: nil

  # The rules must allow the path and the file it leads to on `backend`.
  defp allowed?(backend, permissions, operation, path, opts) when operation in [:read, :write],
    do: FilesystemPermission.allowed?(permissions, operation, path || "/", backend, opts)

  defp value(map, key, default \\ nil), do: BeamWeaver.MapAccess.get(map, key, default)

  defp normalize_timeout(nil), do: {:ok, []}

  defp normalize_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {timeout, ""} -> normalize_timeout(timeout)
      _error -> {:error, "timeout must be an integer between 1 and 3600 seconds"}
    end
  end

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout in 1..3600,
    do: {:ok, [timeout: timeout]}

  defp normalize_timeout(_timeout),
    do: {:error, "timeout must be an integer between 1 and 3600 seconds"}
end

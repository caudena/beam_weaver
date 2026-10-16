defmodule BeamWeaver.Tools.Filesystem do
  @moduledoc """
  Agent filesystem tools (`ls`, `read_file`, `write_file`, `edit_file`, `glob`,
  `grep`, plus `execute` for executable backends) backed by a
  `BeamWeaver.Filesystem`.

  `execute` returns the command's output followed by its exit code, such as
  `[Command failed with exit code 1]`, or an error that says the command timed
  out and was stopped.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Permission, as: FilesystemPermission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph.Command

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
          |> filter_file_info_result(:entries, backend, permissions, opts)
          |> render_entries(:entries)
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
          "offset" => %{"type" => "integer", "default" => 0},
          "limit" => %{"type" => "integer", "default" => 2000}
        },
        "required" => ["file_path"]
      },
      fn input, _opts ->
        path = value(input, :file_path) || value(input, :path)

        if allowed?(backend, permissions, :read, path, runtime_opts(input)) do
          result =
            Filesystem.read(
              backend,
              path,
              runtime_opts(input,
                offset: value(input, :offset, 0),
                limit: value(input, :limit, 2000)
              )
            )

          case result do
            %Filesystem.ReadResult{
              error: nil,
              file_data: %Filesystem.FileData{encoding: "base64"} = data
            } ->
              [
                %{"type" => "text", "text" => "File #{path} is binary and returned as base64."},
                %{"type" => "image", "source" => %{"type" => "base64", "data" => data.content}}
              ]

            %Filesystem.ReadResult{error: nil, file_data: %Filesystem.FileData{} = data} ->
              data.content || ""

            %Filesystem.ReadResult{error: error} ->
              "Error: #{error}"
          end
        else
          "Error: Permission denied reading #{path}"
        end
      end
    )
  end

  defp write_tool(backend, permissions, state_key) do
    tool(
      "write_file",
      "Create a new file at an absolute virtual path.",
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
          "pattern" => %{"type" => "string"},
          "path" => %{"type" => "string", "default" => "/"}
        },
        "required" => ["pattern"]
      },
      fn input, _opts ->
        path = value(input, :path, "/")
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :read, path, opts) do
          backend
          |> Filesystem.glob(value(input, :pattern), Keyword.put(opts, :path, path))
          |> filter_file_info_result(:matches, backend, permissions, opts)
          |> render_entries(:matches)
        else
          "Error: Permission denied reading #{path}"
        end
      end
    )
  end

  defp grep_tool(backend, permissions) do
    tool(
      "grep",
      "Search files for a literal string.",
      %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          "path" => %{"type" => "string", "default" => "/"},
          "glob" => %{"type" => "string"}
        },
        "required" => ["pattern"]
      },
      fn input, _opts ->
        path = value(input, :path, "/")
        opts = runtime_opts(input)

        if allowed?(backend, permissions, :read, path, opts) do
          case Filesystem.grep(
                 backend,
                 value(input, :pattern),
                 runtime_opts(input, path: path, glob: value(input, :glob))
               ) do
            %Filesystem.GrepResult{error: nil, matches: matches} ->
              matches
              |> Kernel.||([])
              |> filter_allowed(backend, permissions, opts)
              |> Enum.map(&json_entry/1)
              |> BeamWeaver.JSON.encode!()

            %Filesystem.GrepResult{error: error} ->
              "Error: #{error}"
          end
        else
          "Error: Permission denied reading #{path}"
        end
      end
    )
  end

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
                  |> render_execute_result(Keyword.get(opts, :timeout))

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

  defp render_entries(%{error: nil} = result, field) do
    result
    |> Map.fetch!(field)
    |> Kernel.||([])
    |> Enum.map(&json_entry/1)
    |> BeamWeaver.JSON.encode!()
  end

  defp render_entries(%{error: error}, _field), do: "Error: #{error}"

  defp json_entry(%{__struct__: _struct} = entry), do: Map.from_struct(entry)
  defp json_entry(entry), do: entry

  defp filter_file_info_result(%{error: nil} = result, field, backend, permissions, opts) do
    entries =
      result
      |> Map.get(field)
      |> Kernel.||([])
      |> filter_allowed(backend, permissions, opts)

    Map.put(result, field, entries)
  end

  defp filter_file_info_result(result, _field, _backend, _permissions, _opts), do: result

  # The entries of a listing or search that the model may read: those whose
  # path, and the file it leads to, the rules allow.
  defp filter_allowed(entries, backend, permissions, opts) do
    allowed =
      permissions
      |> FilesystemPermission.filter_paths(:read, Enum.map(entries, & &1.path), backend, opts)
      |> MapSet.new()

    Enum.filter(entries, &MapSet.member?(allowed, &1.path))
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

  defp runtime_value(nil, _key), do: nil
  defp runtime_value(%{store: store}, :store), do: store
  defp runtime_value(%{runtime: runtime}, :runtime), do: runtime
  defp runtime_value(_runtime, _key), do: nil

  # The rules must allow the path and the file it leads to on `backend`.
  defp allowed?(backend, permissions, operation, path, opts) when operation in [:read, :write],
    do: FilesystemPermission.allowed?(permissions, operation, path || "/", backend, opts)

  defp value(map, key, default \\ nil)
  defp value(nil, _key, default), do: default
  defp value(map, key, default), do: BeamWeaver.MapAccess.get(map, key, default)

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

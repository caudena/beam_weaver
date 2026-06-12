defmodule BeamWeaver.Tools.Filesystem do
  @moduledoc """
  DeepAgents filesystem tools backed by a `BeamWeaver.Filesystem`.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Permission, as: FilesystemPermission
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph.Command

  @read_ops ~w(ls read_file glob grep)
  @write_ops ~w(write_file edit_file)

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

        if allowed?(permissions, :read, path) do
          backend
          |> Filesystem.ls(path, runtime_opts(input))
          |> filter_file_info_result(:entries, permissions)
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

        if allowed?(permissions, :read, path) do
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

        if allowed?(permissions, :write, path) do
          result = Filesystem.write(backend, path, content, runtime_opts(input))
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

        if allowed?(permissions, :write, path) do
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

        if allowed?(permissions, :read, path) do
          backend
          |> Filesystem.glob(value(input, :pattern), runtime_opts(input, path: path))
          |> filter_file_info_result(:matches, permissions)
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

        if allowed?(permissions, :read, path) do
          case Filesystem.grep(
                 backend,
                 value(input, :pattern),
                 runtime_opts(input, path: path, glob: value(input, :glob))
               ) do
            %Filesystem.GrepResult{error: nil, matches: matches} ->
              matches =
                matches
                |> Kernel.||([])
                |> Enum.filter(&allowed?(permissions, :read, &1.path))
                |> Enum.map(&json_entry/1)

              BeamWeaver.JSON.encode!(matches)

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
            "Execute a shell command inside the configured sandbox backend.",
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
                  result = Executable.execute(backend, value(input, :command, ""), opts)
                  result.output || result.error || ""

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

  defp filter_file_info_result(%{error: nil} = result, field, permissions) do
    entries =
      result
      |> Map.get(field)
      |> Kernel.||([])
      |> Enum.filter(&allowed?(permissions, :read, &1.path))

    Map.put(result, field, entries)
  end

  defp filter_file_info_result(result, _field, _permissions), do: result

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

  defp allowed?(permissions, operation, path) when operation in [:read, :write],
    do: FilesystemPermission.allowed?(permissions, operation, path || "/")

  defp value(map, key, default \\ nil)
  defp value(nil, _key, default), do: default
  defp value(map, key, default), do: BeamWeaver.MapAccess.get(map, key, default)

  def read_operation?(name), do: name in @read_ops
  def write_operation?(name), do: name in @write_ops

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

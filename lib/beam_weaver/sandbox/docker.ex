defmodule BeamWeaver.Sandbox.Docker do
  @moduledoc """
  Docker-compatible sandbox adapter.

  This adapter keeps the BeamWeaver runtime outside the sandbox and executes
  filesystem/command operations inside a container. Plain Docker is suitable for
  local development; production deployments should select a hardened runtime
  such as gVisor (`runsc`) or Kata through the `:runtime` option.
  """

  use BeamWeaver.Sandbox

  alias BeamWeaver.Sandbox

  defstruct [
    :container,
    :image,
    :runtime,
    root: "/workspace",
    max_output_bytes: 100_000,
    remove?: true
  ]

  def new(opts \\ []) do
    %__MODULE__{
      container: Keyword.get(opts, :container),
      image: Keyword.get(opts, :image, "docker.io/library/python:3.11-slim"),
      runtime: Keyword.get(opts, :runtime),
      root: Keyword.get(opts, :root, "/workspace"),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 100_000),
      remove?: Keyword.get(opts, :remove, true)
    }
  end

  def start!(%__MODULE__{container: nil} = sandbox) do
    name = "beam-weaver-sandbox-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    args =
      ["run", "-d", "--name", name, "--network", "none", "--workdir", sandbox.root]
      |> maybe_runtime(sandbox.runtime)
      |> Kernel.++([
        "--cpus",
        "1",
        "--memory",
        "1g",
        "--pids-limit",
        "256",
        sandbox.image,
        "sleep",
        "infinity"
      ])

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_output, 0} -> %{sandbox | container: name}
      {output, status} -> raise "docker sandbox failed to start (#{status}): #{output}"
    end
  end

  def start!(%__MODULE__{} = sandbox), do: sandbox

  @impl true
  def write(%__MODULE__{} = sandbox, path, content, _opts) do
    sandbox = start!(sandbox)
    container_path = container_path!(sandbox, path)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_docker_upload_#{System.unique_integer([:positive])}"
      )

    File.write!(tmp, IO.iodata_to_binary(content))

    try do
      mkdir =
        execute(
          sandbox,
          "mkdir -p #{shell_quote(Path.dirname(container_path))} && test ! -e #{shell_quote(container_path)}",
          []
        )

      if mkdir.exit_code == 0 do
        case System.cmd("docker", ["cp", tmp, "#{sandbox.container}:#{container_path}"], stderr_to_stdout: true) do
          {_output, 0} -> %Sandbox.WriteResult{path: path}
          {output, _status} -> %Sandbox.WriteResult{path: path, error: String.trim(output)}
        end
      else
        %Sandbox.WriteResult{path: path, error: mkdir.output}
      end
    after
      File.rm(tmp)
    end
  end

  @impl true
  def read(%__MODULE__{} = sandbox, path, opts) do
    sandbox = start!(sandbox)
    container_path = container_path!(sandbox, path)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 2_000)

    cmd = """
    python3 - <<'PY'
    import base64, json, os, sys
    path = #{BeamWeaver.JSON.encode!(container_path)}
    offset = #{offset}
    limit = #{limit}
    try:
      raw = open(path, 'rb').read()
      if not raw:
        print(json.dumps({"encoding":"utf-8","content":"System reminder: File exists but has empty contents"}))
      else:
        try:
          text = raw.decode('utf-8').replace('\\r\\n','\\n').replace('\\r','\\n')
          lines = text.split('\\n')
          if lines and lines[-1] == '': lines.pop()
          print(json.dumps({"encoding":"utf-8","content":"\\n".join(lines[offset:offset+limit])}))
        except UnicodeDecodeError:
          print(json.dumps({"encoding":"base64","content":base64.b64encode(raw).decode('ascii')}))
    except FileNotFoundError:
      print(json.dumps({"error":"file_not_found"}))
    except PermissionError:
      print(json.dumps({"error":"permission_denied"}))
    PY
    """

    case execute(sandbox, cmd, []) do
      %Sandbox.ExecuteResult{exit_code: 0, output: output} ->
        case BeamWeaver.JSON.decode(String.trim(output)) do
          {:ok, %{"error" => error}} -> %Sandbox.ReadResult{error: error}
          {:ok, data} -> %Sandbox.ReadResult{file_data: data}
          _error -> %Sandbox.ReadResult{error: "invalid_sandbox_response"}
        end

      %Sandbox.ExecuteResult{output: output} ->
        %Sandbox.ReadResult{error: output}
    end
  end

  @impl true
  def execute(%__MODULE__{} = sandbox, command, opts) do
    case opts |> Keyword.get(:timeout, 120) |> timeout_ms() do
      {:ok, timeout} ->
        sandbox = start!(sandbox)

        args = ["exec", "--workdir", sandbox.root, sandbox.container, "sh", "-lc", command]

        task =
          Task.async(fn ->
            {output, exit_code} = System.cmd("docker", args, stderr_to_stdout: true)
            {output, truncated?} = truncate(output, sandbox.max_output_bytes)
            {output, exit_code, truncated?}
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, exit_code, truncated?}} ->
            %Sandbox.ExecuteResult{exit_code: exit_code, output: output, truncated: truncated?}

          nil ->
            %Sandbox.ExecuteResult{exit_code: 124, output: "", error: "timeout", truncated: false}
        end

      {:error, error} ->
        %Sandbox.ExecuteResult{exit_code: nil, output: "", error: error, truncated: false}
    end
  rescue
    exception ->
      %Sandbox.ExecuteResult{
        exit_code: 1,
        output: "",
        error: Exception.message(exception),
        truncated: false
      }
  end

  @impl true
  def edit(%__MODULE__{} = sandbox, path, old, new, opts) do
    container_path = container_path!(sandbox, path)

    case read(sandbox, path, []) do
      %Sandbox.ReadResult{file_data: %{"encoding" => "utf-8", "content" => content}} ->
        occurrences = length(:binary.matches(content, old))

        cond do
          occurrences == 0 ->
            %Sandbox.EditResult{path: path, occurrences: 0, error: "string not found"}

          occurrences > 1 and not Keyword.get(opts, :replace_all, false) ->
            %Sandbox.EditResult{
              path: path,
              occurrences: occurrences,
              error: "multiple occurrences"
            }

          true ->
            updated =
              if Keyword.get(opts, :replace_all, false),
                do: String.replace(content, old, new),
                else: String.replace(content, old, new, global: false)

            tmp_path = path <> ".beam_weaver_tmp"
            tmp_container_path = container_path!(sandbox, tmp_path)

            %Sandbox.WriteResult{} =
              write(%{sandbox | container: sandbox.container}, tmp_path, updated, [])

            execute(
              sandbox,
              "mv #{shell_quote(tmp_container_path)} #{shell_quote(container_path)}",
              []
            )

            %Sandbox.EditResult{
              path: path,
              occurrences: if(Keyword.get(opts, :replace_all, false), do: occurrences, else: 1)
            }
        end

      %Sandbox.ReadResult{error: error} ->
        %Sandbox.EditResult{path: path, error: error}
    end
  end

  @impl true
  def ls(%__MODULE__{} = sandbox, path, _opts) do
    container_path = container_path!(sandbox, path)
    cmd = "find #{shell_quote(container_path)} -maxdepth 1 -mindepth 1 -printf '%p|%y\\n'"

    case execute(sandbox, cmd, []) do
      %Sandbox.ExecuteResult{exit_code: 0, output: output} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [entry_path, type] = String.split(line, "|", parts: 2)
            %{"path" => virtual_path(sandbox, entry_path), "is_dir" => type == "d"}
          end)

        %Sandbox.ListResult{entries: entries}

      %Sandbox.ExecuteResult{output: output} ->
        %Sandbox.ListResult{error: output}
    end
  end

  @impl true
  def glob(%__MODULE__{} = sandbox, pattern, opts) do
    path = Keyword.get(opts, :path, "/")
    container_path = container_path!(sandbox, path)
    quoted_pattern = shell_quote("./" <> pattern)
    cmd = "cd #{shell_quote(container_path)} && find . -path #{quoted_pattern} -printf '%P|%y\\n'"

    case execute(sandbox, cmd, []) do
      %Sandbox.ExecuteResult{exit_code: 0, output: output} ->
        matches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [entry_path, type] = String.split(line, "|", parts: 2)
            %{"path" => join_virtual(path, entry_path), "is_dir" => type == "d"}
          end)

        %Sandbox.GlobResult{matches: matches}

      %Sandbox.ExecuteResult{output: output} ->
        %Sandbox.GlobResult{error: output}
    end
  end

  @impl true
  def grep(%__MODULE__{} = sandbox, pattern, opts) do
    path = Keyword.get(opts, :path, "/")
    container_path = container_path!(sandbox, path)
    glob = Keyword.get(opts, :glob, "*")

    cmd =
      "grep -rHnF --include=#{shell_quote(glob)} -e #{shell_quote(pattern)} #{shell_quote(container_path)} 2>/dev/null || true"

    matches =
      execute(sandbox, cmd, []).output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, line_number, text] ->
            [
              %{
                "path" => virtual_path(sandbox, file),
                "line" => String.to_integer(line_number),
                "text" => text
              }
            ]

          _other ->
            []
        end
      end)

    %Sandbox.GrepResult{matches: matches}
  end

  @impl true
  def upload_files(%__MODULE__{} = sandbox, files, _opts) do
    Enum.map(files, fn {path, content} ->
      result = write(sandbox, path, content, [])
      %Sandbox.UploadResult{path: result.path, error: result.error}
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = sandbox, paths, _opts) do
    sandbox = start!(sandbox)

    Enum.map(paths, fn path ->
      container_path = container_path!(sandbox, path)

      tmp =
        Path.join(
          System.tmp_dir!(),
          "beam_weaver_docker_download_#{System.unique_integer([:positive])}"
        )

      try do
        case System.cmd("docker", ["cp", "#{sandbox.container}:#{container_path}", tmp], stderr_to_stdout: true) do
          {_output, 0} ->
            %Sandbox.DownloadResult{path: path, content: File.read!(tmp)}

          {output, _status} ->
            %Sandbox.DownloadResult{path: path, error: String.trim(output)}
        end
      after
        File.rm(tmp)
      end
    end)
  end

  defp maybe_runtime(args, nil), do: args
  defp maybe_runtime(args, runtime), do: args ++ ["--runtime", to_string(runtime)]

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"

  defp container_path!(%__MODULE__{} = sandbox, path) do
    cond do
      not is_binary(path) or not String.starts_with?(path, "/") ->
        raise ArgumentError, "sandbox paths must be absolute virtual paths"

      String.contains?(path, ["\0", "~"]) or Enum.member?(Path.split(path), "..") ->
        raise ArgumentError, "invalid sandbox path"

      path == sandbox.root or String.starts_with?(path, sandbox.root <> "/") ->
        path

      true ->
        Path.join(sandbox.root, String.trim_leading(path, "/"))
    end
  end

  defp virtual_path(%__MODULE__{} = sandbox, container_path) do
    cond do
      container_path == sandbox.root ->
        "/"

      String.starts_with?(container_path, sandbox.root <> "/") ->
        "/" <> Path.relative_to(container_path, sandbox.root)

      true ->
        container_path
    end
  end

  defp join_virtual("/", ""), do: "/"
  defp join_virtual("/", relative), do: "/" <> String.trim_leading(relative, "/")
  defp join_virtual(base, ""), do: base

  defp join_virtual(base, relative) do
    String.trim_trailing(base, "/") <> "/" <> String.trim_leading(relative, "/")
  end

  defp truncate(output, :unlimited), do: {output, false}

  defp truncate(output, max_bytes) when is_integer(max_bytes) and byte_size(output) > max_bytes do
    {binary_part(output, 0, max_bytes) <> "\n\n... Output truncated at #{max_bytes} bytes.", true}
  end

  defp truncate(output, _max_bytes), do: {output, false}

  defp timeout_ms(timeout) when is_integer(timeout) and timeout in 1..3600,
    do: {:ok, timeout * 1_000}

  defp timeout_ms(_timeout),
    do: {:error, "timeout must be an integer between 1 and 3600 seconds"}
end

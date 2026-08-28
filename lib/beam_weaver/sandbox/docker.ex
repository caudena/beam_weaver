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
    :name,
    mounts: [],
    labels: %{},
    cpus: 1,
    memory: "1g",
    pids_limit: 256,
    network: "none",
    read_only?: false,
    cap_drop: [],
    security_opts: [],
    tmpfs: [],
    root: "/workspace",
    max_output_bytes: 100_000,
    remove?: true
  ]

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    %__MODULE__{
      container: Keyword.get(opts, :container),
      image: Keyword.get(opts, :image, "docker.io/library/python:3.11-slim"),
      runtime: Keyword.get(opts, :runtime),
      name: Keyword.get(opts, :name),
      mounts: Keyword.get(opts, :mounts, []),
      labels: Keyword.get(opts, :labels, %{}),
      cpus: Keyword.get(opts, :cpus, 1),
      memory: Keyword.get(opts, :memory, "1g"),
      pids_limit: Keyword.get(opts, :pids_limit, 256),
      network: Keyword.get(opts, :network, "none"),
      read_only?: Keyword.get(opts, :read_only, false),
      cap_drop: Keyword.get(opts, :cap_drop, []),
      security_opts: Keyword.get(opts, :security_opts, []),
      tmpfs: Keyword.get(opts, :tmpfs, []),
      root: Keyword.get(opts, :root, "/workspace"),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 100_000),
      remove?: Keyword.get(opts, :remove, true)
    }
  end

  def start!(%__MODULE__{container: nil} = sandbox) do
    name =
      sandbox.name ||
        "beam-weaver-sandbox-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    args =
      ["run", "-d", "--name", name, "--network", sandbox.network, "--workdir", sandbox.root]
      |> maybe_runtime(sandbox.runtime)
      |> maybe_option("--cpus", sandbox.cpus)
      |> maybe_option("--memory", sandbox.memory)
      |> maybe_option("--pids-limit", sandbox.pids_limit)
      |> maybe_flag("--read-only", sandbox.read_only?)
      |> append_options("--cap-drop", sandbox.cap_drop)
      |> append_options("--security-opt", sandbox.security_opts)
      |> append_options("--tmpfs", sandbox.tmpfs)
      |> append_labels(sandbox.labels)
      |> append_mounts(sandbox.mounts)
      |> Kernel.++([
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

  @spec stop(t()) :: :ok | {:error, binary()}
  def stop(%__MODULE__{container: nil}), do: :ok

  def stop(%__MODULE__{container: container}) do
    case System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  @doc "Returns bounded immutable identity and label evidence for a live container."
  @spec inspect_container(t()) :: {:ok, map()} | {:error, binary()}
  def inspect_container(%__MODULE__{container: nil}), do: {:error, "container_not_started"}

  def inspect_container(%__MODULE__{container: container}) do
    format = "{{json .}}"

    case System.cmd("docker", ["inspect", "--format", format, container], stderr_to_stdout: true) do
      {output, 0} ->
        with {:ok, value} <- BeamWeaver.JSON.decode(String.trim(output)) do
          {:ok,
           %{
             "id" => value["Id"],
             "name" => String.trim_leading(value["Name"] || "", "/"),
             "image" => get_in(value, ["Image"]),
             "labels" => get_in(value, ["Config", "Labels"]) || %{},
             "running" => get_in(value, ["State", "Running"]) == true
           }}
        else
          _error -> {:error, "invalid_docker_inspect_response"}
        end

      {output, _status} ->
        {:error, String.trim(output)}
    end
  end

  @doc "Removes a container only when all expected immutable labels still match."
  @spec stop_owned(t(), map()) :: :ok | {:error, binary()}
  def stop_owned(%__MODULE__{} = sandbox, expected_labels) when is_map(expected_labels) do
    with :ok <- validate_expected_labels(expected_labels),
         {:ok, evidence} <- inspect_container(sandbox),
         true <- labels_match?(evidence["labels"], expected_labels) do
      stop(sandbox)
    else
      false -> {:error, "docker_container_identity_mismatch"}
      {:error, _reason} = error -> error
    end
  end

  @doc "Starts one durable, inspectable command inside an already-started container."
  @spec start_exec(t(), binary(), keyword()) :: {:ok, map()} | {:error, binary()}
  def start_exec(sandbox, command, opts \\ [])

  def start_exec(%__MODULE__{container: nil}, _command, _opts),
    do: {:error, "container_not_started"}

  def start_exec(%__MODULE__{} = sandbox, command, opts)
      when is_binary(command) and byte_size(command) in 1..16_384 do
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    directory = "/tmp/beam_weaver_execs/#{id}"
    workdir = Keyword.get(opts, :workdir, sandbox.root)

    wrapper =
      "mkdir -p #{shell_quote(directory)} && " <>
        "(printf '%s' \"$$\" > #{shell_quote(directory <> "/wrapper_pid")}; " <>
        "sh -lc #{shell_quote(command)} > #{shell_quote(directory <> "/output")} 2>&1 & child=$!; " <>
        "printf '%s' \"$child\" > #{shell_quote(directory <> "/pid")}; " <>
        "trap 'kill -TERM \"$child\" 2>/dev/null || true; wait \"$child\"; " <>
        "code=$?; printf \"%s\" \"$code\" > #{shell_quote(directory <> "/status")}; exit 0' TERM INT; " <>
        "wait \"$child\"; code=$?; printf '%s' \"$code\" > #{shell_quote(directory <> "/status")})"

    args = ["exec", "-d", "--workdir", workdir, sandbox.container, "sh", "-lc", wrapper]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok,
         %{
           id: id,
           container: sandbox.container,
           directory: directory,
           workdir: workdir
         }}

      {output, _status} ->
        {:error, String.trim(output)}
    end
  end

  def start_exec(%__MODULE__{}, _command, _opts), do: {:error, "invalid_docker_command"}

  @doc "Reads a bounded output window and terminal status for a durable exec handle."
  @spec read_exec(t(), map(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, binary()}
  def read_exec(%__MODULE__{} = sandbox, handle, offset, limit)
      when is_map(handle) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit in 1..524_288 do
    with :ok <- validate_exec_handle(sandbox, handle) do
      directory = handle.directory

      script = """
      size=$(wc -c < #{shell_quote(directory <> "/output")} 2>/dev/null || printf 0)
      status=$(cat #{shell_quote(directory <> "/status")} 2>/dev/null || true)
      printf '%s\n%s\n' "$size" "$status"
      dd if=#{shell_quote(directory <> "/output")} bs=1 skip=#{offset} count=#{limit} 2>/dev/null || true
      """

      case System.cmd(
             "docker",
             ["exec", sandbox.container, "sh", "-lc", script],
             stderr_to_stdout: true
           ) do
        {output, 0} -> decode_exec_window(output, offset)
        {output, _status} -> {:error, String.trim(output)}
      end
    end
  end

  def read_exec(%__MODULE__{}, _handle, _offset, _limit),
    do: {:error, "invalid_docker_exec_window"}

  @doc "Requests TERM then KILL and returns only after terminal status is observable."
  @spec stop_exec(t(), map(), non_neg_integer()) :: :ok | {:error, binary()}
  def stop_exec(%__MODULE__{} = sandbox, handle, grace_ms \\ 2_000)
      when is_map(handle) and is_integer(grace_ms) and grace_ms in 0..10_000 do
    with :ok <- validate_exec_handle(sandbox, handle) do
      directory = handle.directory

      script = """
      pid=$(cat #{shell_quote(directory <> "/wrapper_pid")} 2>/dev/null || true)
      test -n "$pid" || exit 3
      kill -TERM "$pid" 2>/dev/null || true
      """

      case System.cmd(
             "docker",
             ["exec", sandbox.container, "sh", "-lc", script],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> wait_exec_stop(sandbox, handle, grace_ms)
        {output, _status} -> {:error, String.trim(output)}
      end
    end
  end

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

        workdir = Keyword.get(opts, :workdir, sandbox.root)
        args = ["exec", "--workdir", workdir, sandbox.container, "sh", "-lc", command]

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
    sandbox = start!(sandbox)
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

            %Sandbox.WriteResult{} = write(sandbox, tmp_path, updated, [])

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
    cmd = "find #{shell_quote(container_path)} -maxdepth 1 -mindepth 1 -printf '%y|%p\\n'"

    case execute(sandbox, cmd, []) do
      %Sandbox.ExecuteResult{exit_code: 0, output: output} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [type, entry_path] = String.split(line, "|", parts: 2)
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
    cmd = "cd #{shell_quote(container_path)} && find . -path #{quoted_pattern} -printf '%y|%P\\n'"

    case execute(sandbox, cmd, []) do
      %Sandbox.ExecuteResult{exit_code: 0, output: output} ->
        matches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [type, entry_path] = String.split(line, "|", parts: 2)
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

  defp maybe_option(args, _name, nil), do: args
  defp maybe_option(args, name, value), do: args ++ [name, to_string(value)]

  defp maybe_flag(args, _name, false), do: args
  defp maybe_flag(args, name, true), do: args ++ [name]

  defp append_options(args, name, values) when is_list(values) do
    args ++ Enum.flat_map(values, &[name, to_string(&1)])
  end

  defp append_labels(args, labels) when is_map(labels) do
    labels
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(args, fn {key, value}, current ->
      unless valid_label?(key) and valid_label?(value) do
        raise ArgumentError, "Docker labels must be bounded printable strings"
      end

      current ++ ["--label", "#{key}=#{value}"]
    end)
  end

  defp append_mounts(args, mounts) when is_list(mounts) do
    options =
      Enum.flat_map(mounts, fn mount ->
        source = Map.fetch!(mount, :source)
        target = Map.fetch!(mount, :target)
        read_only? = Map.get(mount, :read_only, false)

        unless Path.type(source) == :absolute and Path.expand(source) == source and
                 is_binary(target) and Path.type(target) == :absolute and
                 Path.expand(target) == target and not String.contains?(source, [",", <<0>>]) and
                 not String.contains?(target, [",", <<0>>]) do
          raise ArgumentError, "Docker bind mounts require canonical host and absolute container paths"
        end

        value =
          "type=bind,source=#{source},target=#{target}" <>
            if(read_only?, do: ",readonly", else: "")

        ["--mount", value]
      end)

    args ++ options
  end

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
    prefix = binary_part(output, 0, max_bytes)

    prefix =
      case :unicode.characters_to_binary(prefix) do
        {:incomplete, valid, _rest} -> valid
        _other -> prefix
      end

    {prefix <> "\n\n... Output truncated at #{max_bytes} bytes.", true}
  end

  defp truncate(output, _max_bytes), do: {output, false}

  defp labels_match?(actual, expected) do
    Enum.all?(expected, fn {key, value} -> actual[to_string(key)] == to_string(value) end)
  end

  defp valid_label?(value) do
    case label_string(value) do
      {:ok, string} ->
        byte_size(string) in 1..200 and not String.contains?(string, [<<0>>, "\n", "\r"])

      :error ->
        false
    end
  end

  defp validate_expected_labels(labels) when map_size(labels) > 0 do
    if Enum.all?(labels, fn {key, value} -> valid_label?(key) and valid_label?(value) end),
      do: :ok,
      else: {:error, "invalid_docker_container_identity"}
  end

  defp validate_expected_labels(_labels), do: {:error, "invalid_docker_container_identity"}

  defp label_string(value) when is_binary(value), do: {:ok, value}
  defp label_string(value) when is_atom(value) or is_integer(value), do: {:ok, to_string(value)}
  defp label_string(_value), do: :error

  defp validate_exec_handle(%__MODULE__{container: container}, %{
         container: container,
         id: id,
         directory: directory
       })
       when is_binary(id) and byte_size(id) == 24 and
              directory == "/tmp/beam_weaver_execs/" <> id,
       do: :ok

  defp validate_exec_handle(_sandbox, _handle), do: {:error, "docker_exec_identity_mismatch"}

  defp decode_exec_window(output, offset) do
    with {:ok, size, status, bytes} <- split_exec_response(output),
         {observed, ""} <- Integer.parse(size),
         {:ok, parsed_status} <- parse_optional_status(status) do
      {:ok,
       %{
         output: bytes,
         offset: offset,
         observed_bytes: observed,
         next_offset: offset + byte_size(bytes),
         status: parsed_status,
         running: is_nil(parsed_status)
       }}
    else
      _error -> {:error, "invalid_docker_exec_response"}
    end
  end

  defp split_exec_response(output) do
    with {first, 1} <- :binary.match(output, "\n"),
         rest_offset = first + 1,
         rest_size = byte_size(output) - rest_offset,
         rest = binary_part(output, rest_offset, rest_size),
         {second, 1} <- :binary.match(rest, "\n") do
      {:ok, binary_part(output, 0, first), binary_part(rest, 0, second),
       binary_part(rest, second + 1, byte_size(rest) - second - 1)}
    else
      :nomatch -> {:error, "invalid_docker_exec_response"}
    end
  end

  defp parse_optional_status(""), do: {:ok, nil}

  defp parse_optional_status(value) do
    case Integer.parse(value) do
      {status, ""} -> {:ok, status}
      _error -> {:error, "invalid_docker_exec_status"}
    end
  end

  defp wait_exec_stop(sandbox, handle, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_wait_exec_stop(sandbox, handle, deadline)
  end

  defp do_wait_exec_stop(sandbox, handle, deadline) do
    case read_exec(sandbox, handle, 0, 1) do
      {:ok, %{running: false}} ->
        :ok

      {:ok, %{running: true}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          directory = handle.directory

          case System.cmd(
                 "docker",
                 [
                   "exec",
                   sandbox.container,
                   "sh",
                   "-lc",
                   "wrapper=$(cat #{shell_quote(directory <> "/wrapper_pid")} 2>/dev/null || true); " <>
                     "child=$(cat #{shell_quote(directory <> "/pid")} 2>/dev/null || true); " <>
                     "test -n \"$wrapper\" || exit 3; " <>
                     "test -z \"$child\" || kill -KILL \"$child\" 2>/dev/null || true; " <>
                     "kill -KILL \"$wrapper\" 2>/dev/null || true; " <>
                     "alive() { test -n \"$1\" && kill -0 \"$1\" 2>/dev/null; }; " <>
                     "i=0; while test $i -lt 20 && (alive \"$child\" || alive \"$wrapper\"); " <>
                     "do sleep 0.05; i=$((i+1)); done; " <>
                     "(alive \"$child\" || alive \"$wrapper\") && exit 4; " <>
                     "printf 137 > #{shell_quote(directory <> "/status")}"
                 ],
                 stderr_to_stdout: true
               ) do
            {_output, 0} -> confirm_killed_exec(sandbox, handle)
            {output, _status} -> {:error, String.trim(output)}
          end
        else
          Process.sleep(50)
          do_wait_exec_stop(sandbox, handle, deadline)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp confirm_killed_exec(sandbox, handle) do
    Process.sleep(50)

    case read_exec(sandbox, handle, 0, 1) do
      {:ok, %{running: false}} -> :ok
      {:ok, %{running: true}} -> {:error, "docker_exec_termination_unproven"}
      {:error, _reason} = error -> error
    end
  end

  defp timeout_ms(timeout) when is_integer(timeout) and timeout in 1..3600,
    do: {:ok, timeout * 1_000}

  defp timeout_ms(_timeout),
    do: {:error, "timeout must be an integer between 1 and 3600 seconds"}
end

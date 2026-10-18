defmodule BeamWeaver.Sandbox.Docker do
  @moduledoc """
  Docker-compatible sandbox adapter.

  This adapter keeps the BeamWeaver runtime outside the sandbox and executes
  filesystem/command operations inside a container. Plain Docker is suitable for
  local development; production deployments should select a hardened runtime
  such as gVisor (`runsc`) or Kata through the `:runtime` option.

  `new/1` only describes the container. `start!/1` starts it and returns the
  sandbox that every operation then uses; operations on a sandbox that isn't
  started return the error `"container_not_started"` and start nothing. Pass
  `container: name` instead to use a container you started yourself.

  The process that calls `start!/1` owns the container. With `remove: true`
  (the default) the container is removed when that process exits, and Docker
  removes it if it stops; with `remove: false` it keeps running until you call
  `stop/1`. `stop/1` always removes it.
  """

  use BeamWeaver.Sandbox

  alias BeamWeaver.Filesystem.Edit
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Path, as: FilesystemPath
  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.CommandRunner
  alias BeamWeaver.Sandbox.OutputBuffer

  @not_started "container_not_started"

  defstruct [
    :container,
    :image,
    :runtime,
    :name,
    :reaper,
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

  @doc """
  Starts the sandbox's container and returns the started sandbox.

  Use the returned sandbox for every operation. The calling process owns the
  container: with `remove: true` (the default) it is removed when this process
  exits. A sandbox that is already started is returned as it is. Raises when
  Docker can't start the container.
  """
  @spec start!(t()) :: t()
  def start!(%__MODULE__{container: nil} = sandbox) do
    name =
      sandbox.name ||
        "beam-weaver-sandbox-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    # `--init` runs an init as PID 1 that reaps orphaned processes, such as the
    # children of a command stopped after a timeout; `sleep` alone never would.
    args =
      ["run", "-d", "--init", "--name", name, "--network", sandbox.network, "--workdir", sandbox.root]
      |> maybe_flag("--rm", sandbox.remove?)
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
      {output, 0} ->
        reaper = if sandbox.remove?, do: remove_on_exit(self(), container_id(output) || name)
        %{sandbox | container: name, reaper: reaper}

      {output, status} ->
        raise "docker sandbox failed to start (#{status}): #{output}"
    end
  end

  def start!(%__MODULE__{} = sandbox), do: sandbox

  @doc "Removes the sandbox's container, running or not."
  @spec stop(t()) :: :ok | {:error, binary()}
  def stop(%__MODULE__{container: nil}), do: :ok

  def stop(%__MODULE__{container: container, reaper: reaper}) do
    if is_pid(reaper), do: Process.exit(reaper, :kill)

    case System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  @doc "Returns bounded immutable identity and label evidence for a live container."
  @spec inspect_container(t()) :: {:ok, map()} | {:error, binary()}
  def inspect_container(%__MODULE__{container: nil}), do: {:error, @not_started}

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
    do: {:error, @not_started}

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
  def write(%__MODULE__{container: nil}, path, _content, _opts),
    do: %Sandbox.WriteResult{path: path, error: @not_started}

  def write(%__MODULE__{} = sandbox, path, content, _opts) do
    with {:ok, container_path} <- container_path(sandbox, path),
         :ok <- make_room(sandbox, container_path),
         :ok <- copy_in(sandbox, container_path, content) do
      %Sandbox.WriteResult{path: path}
    else
      {:error, error} -> %Sandbox.WriteResult{path: path, error: error}
    end
  end

  @impl true
  def read(%__MODULE__{container: nil}, _path, _opts), do: %Sandbox.ReadResult{error: @not_started}

  def read(%__MODULE__{} = sandbox, path, opts) do
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

    case command(sandbox, cmd) do
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
  def execute(%__MODULE__{container: nil}, _command, _opts),
    do: %Sandbox.ExecuteResult{exit_code: nil, output: "", error: @not_started, truncated: false}

  def execute(%__MODULE__{} = sandbox, command, opts),
    do: run_command(sandbox, command, opts, sandbox.max_output_bytes)

  # Runs one of this module's own commands, such as a file operation's. Its
  # whole output is kept: cut, it couldn't be read.
  defp command(sandbox, script), do: run_command(sandbox, script, [], :unlimited)

  defp run_command(sandbox, command, opts, max_output_bytes) do
    case opts |> Keyword.get(:timeout, 120) |> CommandRunner.timeout_ms() do
      {:ok, timeout} ->
        workdir = Keyword.get(opts, :workdir, sandbox.root)
        pid_file = "/tmp/beam_weaver_execute_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}.pid"

        # The exec'd shell leads its own process group inside the container and
        # records its pid while the command runs, so a timeout can stop the
        # command and everything it started.
        wrapper =
          "printf '%s' \"$$\" > #{shell_quote(pid_file)}; sh -lc #{shell_quote(command)}; " <>
            "status=$?; rm -f #{shell_quote(pid_file)}; exit $status"

        args = ["exec", "--workdir", workdir, sandbox.container, "sh", "-c", wrapper]

        task =
          Task.async(fn ->
            buffer = %OutputBuffer{max_bytes: max_output_bytes}
            {{output, truncated?}, exit_code} = System.cmd("docker", args, stderr_to_stdout: true, into: buffer)
            {output, exit_code, truncated?}
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, exit_code, truncated?}} ->
            %Sandbox.ExecuteResult{exit_code: exit_code, output: output, truncated: truncated?}

          nil ->
            stop_timed_out_command(sandbox, pid_file)
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
  def edit(%__MODULE__{container: nil}, path, _old, _new, _opts),
    do: %Sandbox.EditResult{path: path, error: @not_started}

  def edit(%__MODULE__{} = sandbox, path, old, new, opts) do
    with {:ok, container_path} <- container_path(sandbox, path),
         {:ok, content} <- copy_out(sandbox, container_path) do
      case Edit.replacement(content, old, new, Keyword.get(opts, :replace_all, false)) do
        {:ok, occurrences, updated} ->
          case replace_file(sandbox, container_path, updated) do
            :ok -> %Sandbox.EditResult{path: path, occurrences: occurrences}
            {:error, error} -> %Sandbox.EditResult{path: path, error: error}
          end

        {:error, :not_found} ->
          %Sandbox.EditResult{path: path, occurrences: 0, error: "string not found"}

        {:error, "multiple occurrences" = error} ->
          %Sandbox.EditResult{path: path, occurrences: length(:binary.matches(content, old)), error: error}

        {:error, error} ->
          %Sandbox.EditResult{path: path, error: FileDataUtils.error_string(error)}
      end
    else
      {:error, error} -> %Sandbox.EditResult{path: path, error: error}
    end
  end

  @impl true
  def ls(%__MODULE__{container: nil}, _path, _opts), do: %Sandbox.ListResult{error: @not_started}

  # A path that doesn't exist is the error `file_not_found`, as on the other
  # backends, not `find`'s message.
  def ls(%__MODULE__{} = sandbox, path, _opts) do
    dir = sandbox |> container_path!(path) |> shell_quote()

    cmd =
      "if test -e #{dir}; then find #{dir} -maxdepth 1 -mindepth 1 -printf '%y|%p\\n'; " <>
        "else printf '%s\\n' file_not_found; exit 2; fi"

    case command(sandbox, cmd) do
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
        %Sandbox.ListResult{error: String.trim(output)}
    end
  end

  @impl true
  def glob(%__MODULE__{container: nil}, _pattern, _opts), do: %Sandbox.GlobResult{error: @not_started}

  def glob(%__MODULE__{} = sandbox, pattern, opts) do
    path = Keyword.get(opts, :path, "/")

    with {:ok, container_path} <- container_path(sandbox, path),
         {:ok, regex} <- find_regex(FilesystemPath.search_pattern(pattern)) do
      find = "find . -regextype posix-extended -regex #{shell_quote(regex)} -printf '%y|%P\\n'"

      case command(sandbox, at_path(container_path, find, "true")) do
        %Sandbox.ExecuteResult{exit_code: 0, error: nil, output: output} ->
          matches =
            for <<type::binary-size(1), "|", entry::binary>> <- String.split(output, "\n", trim: true),
                do: %{"path" => FilesystemPath.join_virtual(path, entry), "is_dir" => type == "d"}

          %Sandbox.GlobResult{matches: Enum.sort_by(matches, & &1["path"])}

        %Sandbox.ExecuteResult{error: nil, output: output} ->
          %Sandbox.GlobResult{error: String.trim(output)}

        %Sandbox.ExecuteResult{error: error} ->
          %Sandbox.GlobResult{error: error}
      end
    else
      {:error, error} -> %Sandbox.GlobResult{error: error}
    end
  end

  @impl true
  def grep(%__MODULE__{container: nil}, _pattern, _opts), do: %Sandbox.GrepResult{error: @not_started}

  # Searches the files that `find` picks by the glob rule, leaving out `.git`
  # folders below the path, as the other backends do; `grep -I` leaves out
  # binary files. `-Z` ends each file name with a NUL, so a line without one
  # is an error message, which fails the search rather than leaving matches
  # out unseen.
  def grep(%__MODULE__{} = sandbox, pattern, opts) do
    with {:ok, container_path} <- container_path(sandbox, Keyword.get(opts, :path, "/")),
         {:ok, filter} <- grep_filter(Keyword.get(opts, :glob)),
         script = grep_script(container_path, pattern, filter),
         %Sandbox.ExecuteResult{error: nil, output: output} <- command(sandbox, script),
         {found, []} <- output |> String.split("\n", trim: true) |> Enum.split_with(&String.contains?(&1, <<0>>)) do
      matches = Enum.map(found, &grep_match(sandbox, container_path, &1))
      %Sandbox.GrepResult{matches: Enum.sort_by(matches, &{&1["path"], &1["line"]})}
    else
      {:error, error} -> %Sandbox.GrepResult{error: error}
      %Sandbox.ExecuteResult{error: error} -> %Sandbox.GrepResult{error: error}
      {_found, errors} -> %Sandbox.GrepResult{error: Enum.join(errors, "\n")}
    end
  end

  defp grep_script(container_path, pattern, filter) do
    grep = "grep -HnFIZ -e #{shell_quote(pattern)} --"
    find = "find . -regextype posix-extended -name .git -prune -o -type f#{filter} -exec #{grep} {} +"
    at_path(container_path, find, "#{grep} #{shell_quote(container_path)}")
  end

  defp grep_filter(glob) do
    case FilesystemPath.grep_pattern(glob) do
      nil -> {:ok, ""}
      pattern -> with {:ok, regex} <- find_regex(pattern), do: {:ok, " -regex #{shell_quote(regex)}"}
    end
  end

  # One `file NUL line:text` line of grep's output. A file below a directory
  # searched comes as `./path`.
  defp grep_match(sandbox, container_path, line) do
    [file, rest] = String.split(line, <<0>>, parts: 2)
    [line_number, text] = String.split(rest, ":", parts: 2)
    file = if String.starts_with?(file, "./"), do: Path.join(container_path, file), else: file
    %{"path" => virtual_path(sandbox, Path.expand(file)), "line" => String.to_integer(line_number), "text" => text}
  end

  # A script that runs `in_dir` in the directory `container_path`, or
  # `on_file` when it is a file. A path that doesn't exist is the error
  # `file_not_found`.
  defp at_path(container_path, in_dir, on_file) do
    dir = shell_quote(container_path)

    "if test -d #{dir}; then cd #{dir} && #{in_dir}; elif test -e #{dir}; then #{on_file}; " <>
      "else printf '%s\\n' file_not_found; exit 2; fi"
  end

  # `pattern`, a glob for a path below the directory searched, as the POSIX
  # extended regex that `find -regex` matches against `./path`, by the glob
  # rule of every backend.
  defp find_regex(pattern) do
    with {:ok, regex} <- FilesystemPath.glob_regex(pattern), do: {:ok, "\\./" <> regex}
  end

  @impl true
  def upload_files(%__MODULE__{container: nil}, files, _opts),
    do: Enum.map(files, fn {path, _content} -> %Sandbox.UploadResult{path: path, error: @not_started} end)

  def upload_files(%__MODULE__{} = sandbox, files, _opts) do
    Enum.map(files, fn {path, content} ->
      with {:ok, container_path} <- container_path(sandbox, path),
           :ok <- make_room(sandbox, container_path),
           :ok <- copy_in(sandbox, container_path, content) do
        %Sandbox.UploadResult{path: path}
      else
        {:error, error} -> %Sandbox.UploadResult{path: path, error: error}
      end
    end)
  end

  @impl true
  def download_files(%__MODULE__{container: nil}, paths, _opts),
    do: Enum.map(paths, &%Sandbox.DownloadResult{path: &1, error: @not_started})

  def download_files(%__MODULE__{} = sandbox, paths, _opts) do
    Enum.map(paths, fn path ->
      with {:ok, container_path} <- container_path(sandbox, path),
           {:ok, content} <- copy_out(sandbox, container_path) do
        %Sandbox.DownloadResult{path: path, content: content}
      else
        {:error, error} -> %Sandbox.DownloadResult{path: path, error: error}
      end
    end)
  end

  # Makes the directory of the file at `container_path`, which mustn't be a
  # directory: `docker cp` would copy the file into it.
  defp make_room(sandbox, container_path) do
    path = shell_quote(container_path)

    run(
      sandbox,
      "if test -d #{path}; then printf is_directory; exit 3; fi; mkdir -p #{shell_quote(Path.dirname(container_path))}"
    )
  end

  # Copies `content` to the file at `container_path`, replacing it.
  defp copy_in(sandbox, container_path, content) do
    tmp = Path.join(System.tmp_dir!(), "beam_weaver_docker_upload_#{System.unique_integer([:positive])}")
    File.write!(tmp, IO.iodata_to_binary(content))

    try do
      case System.cmd("docker", ["cp", tmp, "#{sandbox.container}:#{container_path}"], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, String.trim(output)}
      end
    after
      File.rm(tmp)
    end
  end

  # The bytes of the file at `container_path`. `-L` copies the file a symlink
  # in the container leads to, inside the container. Without it, Docker copies
  # the symlink itself, and reading that copy would read whatever it names on
  # this host.
  defp copy_out(sandbox, container_path) do
    tmp = Path.join(System.tmp_dir!(), "beam_weaver_docker_download_#{System.unique_integer([:positive])}")

    try do
      with {_output, 0} <-
             System.cmd("docker", ["cp", "-L", "#{sandbox.container}:#{container_path}", tmp], stderr_to_stdout: true),
           {:ok, %File.Stat{type: :regular}} <- File.lstat(tmp),
           {:ok, content} <- File.read(tmp) do
        {:ok, content}
      else
        {:ok, %File.Stat{type: :directory}} -> {:error, "is_directory"}
        {:ok, %File.Stat{}} -> {:error, "invalid_path"}
        {:error, reason} -> {:error, List.to_string(:file.format_error(reason))}
        {output, _status} -> {:error, copy_error(output)}
      end
    after
      File.rm_rf(tmp)
    end
  end

  # `docker cp` reports a missing file in a sentence; the other backends call
  # it file_not_found.
  defp copy_error(output) do
    if output =~ ~r/Could not find the file|No such container:path/,
      do: "file_not_found",
      else: String.trim(output)
  end

  # Writes the edited file next to the original, then renames it over the
  # original, so the file is never half written.
  defp replace_file(sandbox, container_path, content) do
    tmp = container_path <> ".beam_weaver_tmp"

    with :ok <- copy_in(sandbox, tmp, content),
         do: run(sandbox, "mv #{shell_quote(tmp)} #{shell_quote(container_path)}")
  end

  # Runs `script` in the container for its exit status: `:ok`, or its output
  # as the error.
  defp run(sandbox, script) do
    case command(sandbox, script) do
      %Sandbox.ExecuteResult{exit_code: 0} -> :ok
      %Sandbox.ExecuteResult{error: nil, output: output} -> {:error, String.trim(output)}
      %Sandbox.ExecuteResult{error: error} -> {:error, error}
    end
  end

  # The path the container's `realpath` takes each path to, as a sandbox
  # path. A path whose file is outside the root has none.
  @impl true
  def canonical_paths(%__MODULE__{container: nil}, paths, _opts),
    do: Enum.map(paths, fn _path -> {:error, @not_started} end)

  def canonical_paths(%__MODULE__{} = sandbox, paths, _opts) do
    located =
      Enum.map(paths, fn path ->
        if is_binary(path) and String.valid?(path), do: container_path(sandbox, path), else: {:error, "invalid_path"}
      end)

    container_paths = for {:ok, path} <- located, uniq: true, do: path

    case realpaths(sandbox, container_paths) do
      {:ok, resolved} ->
        Enum.map(located, fn
          {:ok, path} -> if is_binary(resolved[path]), do: {:ok, resolved[path]}, else: {:error, "invalid_path"}
          {:error, _reason} -> {:error, "invalid_path"}
        end)

      {:error, error} ->
        Enum.map(paths, fn _path -> {:error, error} end)
    end
  end

  # The sandbox path of each container path's real path, from one `python3`
  # call in the container: `nil` when the real path is outside the root.
  defp realpaths(_sandbox, []), do: {:ok, %{}}

  defp realpaths(sandbox, container_paths) do
    request = %{"root" => sandbox.root, "paths" => container_paths} |> BeamWeaver.JSON.encode!() |> Base.encode64()

    cmd = """
    python3 - <<'PY'
    import base64, json, os
    request = json.loads(base64.b64decode("#{request}"))
    root = os.path.realpath(request["root"])
    base = root.rstrip("/")
    def virtual(path):
      real = os.path.realpath(path)
      if real == root:
        return "/"
      if real.startswith(base + "/"):
        return real[len(base):]
      return None
    print(json.dumps([virtual(path) for path in request["paths"]]))
    PY
    """

    with %Sandbox.ExecuteResult{exit_code: 0, output: output} <- command(sandbox, cmd),
         {:ok, resolved} when is_list(resolved) and length(resolved) == length(container_paths) <-
           BeamWeaver.JSON.decode(String.trim(output)) do
      {:ok, Map.new(Enum.zip(container_paths, resolved))}
    else
      %Sandbox.ExecuteResult{error: error} when is_binary(error) -> {:error, error}
      %Sandbox.ExecuteResult{output: output} when output not in [nil, ""] -> {:error, String.trim(output)}
      _invalid -> {:error, "invalid_sandbox_response"}
    end
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

  # Removes the container once `owner` exits. It runs unlinked, so it outlives
  # an owner that crashes; `stop/1` kills it.
  defp remove_on_exit(owner, container) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _owner, _reason} ->
          System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
      end
    end)
  end

  # `docker run -d` prints the new container's id last, after any image pull
  # progress.
  defp container_id(output) do
    id = output |> String.split("\n", trim: true) |> List.last("") |> String.trim()
    if id =~ ~r/\A[0-9a-f]{64}\z/, do: id
  end

  # Runs inside the container once `execute/3` times out: waits briefly for the
  # command's pid file (in case it is still starting), SIGTERMs its process
  # group, gives it a second to exit, then SIGKILLs whatever is left.
  defp stop_timed_out_command(%__MODULE__{} = sandbox, pid_file) do
    file = shell_quote(pid_file)

    script = """
    i=0; while ! test -s #{file} && test $i -lt 40; do sleep 0.05; i=$((i+1)); done
    pid=$(cat #{file} 2>/dev/null) || exit 0
    kill -TERM "-$pid" 2>/dev/null
    i=0; while kill -0 "-$pid" 2>/dev/null && test $i -lt 20; do sleep 0.05; i=$((i+1)); done
    kill -KILL "-$pid" 2>/dev/null
    rm -f #{file}
    """

    System.cmd("docker", ["exec", sandbox.container, "sh", "-c", script], stderr_to_stdout: true)
    :ok
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"

  defp container_path!(%__MODULE__{} = sandbox, path) do
    case container_path(sandbox, path) do
      {:ok, container_path} -> container_path
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp container_path(%__MODULE__{} = sandbox, path) do
    cond do
      not is_binary(path) or not String.starts_with?(path, "/") ->
        {:error, "sandbox paths must be absolute virtual paths"}

      String.contains?(path, ["\0", "~"]) or Enum.member?(Path.split(path), "..") ->
        {:error, "invalid sandbox path"}

      path == sandbox.root or String.starts_with?(path, sandbox.root <> "/") ->
        {:ok, path}

      true ->
        {:ok, Path.join(sandbox.root, String.trim_leading(path, "/"))}
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
end

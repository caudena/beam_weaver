defmodule BeamWeaver.Sandbox do
  @moduledoc """
  Sandbox backend behaviour and facade.

  The default local adapter is for development and conformance tests. It gives
  BeamWeaver a native boundary for file operations and command execution without
  claiming to be a hardened remote sandbox.
  """

  import BeamWeaver.MapShape, only: [compact: 2, put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Telemetry
  alias BeamWeaver.Tracing.Redactor

  defmodule WriteResult do
    @moduledoc "Result returned by sandbox write calls."

    defstruct [:path, :error]
    @type t :: %__MODULE__{path: String.t() | nil, error: String.t() | nil}
  end

  defmodule ReadResult do
    @moduledoc "Result returned by sandbox read calls."

    defstruct [:file_data, :error]
    @type t :: %__MODULE__{file_data: binary() | nil, error: String.t() | nil}
  end

  defmodule ExecuteResult do
    @moduledoc "Result returned by sandbox command execution calls."

    defstruct [:exit_code, output: "", error: nil, truncated: false, metadata: %{}]

    @type t :: %__MODULE__{
            exit_code: integer() | nil,
            output: String.t(),
            error: String.t() | nil,
            truncated: boolean(),
            metadata: map()
          }
  end

  defmodule EditResult do
    @moduledoc "Result returned by sandbox edit calls."

    defstruct [:path, occurrences: 0, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            occurrences: non_neg_integer(),
            error: String.t() | nil
          }
  end

  defmodule ListResult do
    @moduledoc "Result returned by sandbox directory listing calls."

    defstruct entries: nil, error: nil
    @type t :: %__MODULE__{entries: [map()] | nil, error: String.t() | nil}
  end

  defmodule GlobResult do
    @moduledoc "Result returned by sandbox glob calls."

    defstruct matches: nil, error: nil
    @type t :: %__MODULE__{matches: [String.t()] | nil, error: String.t() | nil}
  end

  defmodule GrepResult do
    @moduledoc "Result returned by sandbox grep calls."

    defstruct matches: nil, error: nil
    @type t :: %__MODULE__{matches: [map()] | nil, error: String.t() | nil}
  end

  defmodule UploadResult do
    @moduledoc "Result returned for one uploaded sandbox file."

    defstruct [:path, :error]
    @type t :: %__MODULE__{path: String.t() | nil, error: String.t() | nil}
  end

  defmodule DownloadResult do
    @moduledoc "Result returned for one downloaded sandbox file."

    defstruct [:path, :content, :error]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            content: binary() | nil,
            error: String.t() | nil
          }
  end

  @callback write(term(), String.t(), iodata(), keyword()) :: WriteResult.t()
  @callback read(term(), String.t(), keyword()) :: ReadResult.t()
  @callback execute(term(), String.t(), keyword()) :: ExecuteResult.t()
  @callback edit(term(), String.t(), String.t(), String.t(), keyword()) :: EditResult.t()
  @callback ls(term(), String.t(), keyword()) :: ListResult.t()
  @callback glob(term(), String.t(), keyword()) :: GlobResult.t()
  @callback grep(term(), String.t(), keyword()) :: GrepResult.t()
  @callback upload_files(term(), [{String.t(), iodata()}], keyword()) :: [UploadResult.t()]
  @callback download_files(term(), [String.t()], keyword()) :: [DownloadResult.t()]
  @callback canonical_paths(term(), [String.t()], keyword()) :: [{:ok, String.t()} | {:error, String.t()}]

  @optional_callbacks canonical_paths: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Sandbox
    end
  end

  def local(opts \\ []), do: BeamWeaver.Sandbox.Local.new(opts)

  # Each function calls the sandbox struct's module.
  def write(%module{} = sandbox, path, content, opts \\ []), do: module.write(sandbox, path, content, opts)
  def read(%module{} = sandbox, path, opts \\ []), do: module.read(sandbox, path, opts)

  def execute(%module{} = sandbox, command, opts \\ []) do
    start = System.monotonic_time()
    metadata = execute_metadata(sandbox, command, opts)

    Telemetry.emit(
      [:beam_weaver, :sandbox, :execute, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result =
        sandbox
        |> module.execute(command, opts)
        |> put_execute_metadata(metadata)

      event = if timeout_result?(result), do: :timeout, else: :stop

      Telemetry.emit(
        [:beam_weaver, :sandbox, :execute, event],
        %{duration: System.monotonic_time() - start},
        Map.merge(metadata, result_metadata(result))
      )

      result
    rescue
      exception ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :execute, :exception],
          %{duration: System.monotonic_time() - start},
          Map.merge(metadata, %{error: Exception.message(exception)})
        )

        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :execute, :exception],
          %{duration: System.monotonic_time() - start},
          Map.merge(metadata, %{kind: kind, reason: inspect(reason)})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def edit(%module{} = sandbox, path, old, new, opts \\ []), do: module.edit(sandbox, path, old, new, opts)
  def ls(%module{} = sandbox, path, opts \\ []), do: module.ls(sandbox, path, opts)
  def glob(%module{} = sandbox, pattern, opts \\ []), do: module.glob(sandbox, pattern, opts)
  def grep(%module{} = sandbox, pattern, opts \\ []), do: module.grep(sandbox, pattern, opts)
  def upload_files(%module{} = sandbox, files, opts \\ []), do: module.upload_files(sandbox, files, opts)
  def download_files(%module{} = sandbox, paths, opts \\ []), do: module.download_files(sandbox, paths, opts)

  @doc """
  The path of the file `sandbox` reaches for each of `paths`, in order, with
  every symlink on the way followed; see `BeamWeaver.Filesystem.canonical_paths/3`,
  which calls this for a `BeamWeaver.Filesystem.Sandbox`.

  The callback is optional: a sandbox without it is treated as having no
  links, and its paths come back cleaned. An adapter that wraps another
  sandbox should pass the call to it.
  """
  @spec canonical_paths(term(), [String.t()], keyword()) :: [{:ok, String.t()} | {:error, String.t()}]
  def canonical_paths(%module{} = sandbox, paths, opts \\ []) when is_list(paths) do
    if BeamWeaver.Behaviour.exported?(module, :canonical_paths, 3),
      do: module.canonical_paths(sandbox, paths, opts),
      else: Enum.map(paths, &BeamWeaver.Filesystem.Path.clean_path/1)
  end

  @doc "Whether `sandbox` is a struct whose module implements this behaviour."
  @spec sandbox?(term()) :: boolean()
  def sandbox?(%module{}), do: BeamWeaver.Behaviour.implemented_by?(module, __MODULE__)
  def sandbox?(_other), do: false

  def error(type, message, details \\ %{}), do: Error.new(type, message, details)

  defp execute_metadata(sandbox, command, opts) do
    %{
      sandbox: BeamWeaver.Telemetry.AdapterHelpers.adapter_name(sandbox),
      command: command,
      command_id: Keyword.get_lazy(opts, :command_id, fn -> ID.uuidv7() end),
      timeout_ms: timeout_option_ms(Keyword.get(opts, :timeout))
    }
    |> clean_metadata()
    |> Map.merge(Keyword.get(opts, :metadata, %{}) || %{})
    |> Redactor.redact()
  end

  defp put_execute_metadata(%ExecuteResult{} = result, metadata) do
    result_metadata =
      metadata
      |> Map.merge(result.metadata || %{})
      |> put_present(:exit_code, result.exit_code)
      |> put_present(:truncated, result.truncated)
      |> put_present(:error, result.error)
      |> clean_metadata()
      |> Redactor.redact()

    %{result | metadata: result_metadata}
  end

  defp put_execute_metadata(other, _metadata), do: other

  defp result_metadata(%ExecuteResult{} = result) do
    %{
      result: if(result.error in [nil, ""], do: :ok, else: :error),
      exit_code: result.exit_code,
      truncated: result.truncated,
      error: result.error,
      metadata: result.metadata || %{}
    }
    |> clean_metadata()
    |> Redactor.redact()
  end

  defp result_metadata(result), do: Redactor.redact(%{result: :invalid, value: inspect(result)})

  defp timeout_result?(%ExecuteResult{error: "timeout"}), do: true
  defp timeout_result?(%ExecuteResult{exit_code: 124, error: error}), do: error in ["timeout", :timeout]
  defp timeout_result?(_result), do: false

  defp timeout_option_ms(nil), do: nil
  defp timeout_option_ms(:infinity), do: :infinity
  defp timeout_option_ms(timeout) when is_integer(timeout) and timeout > 3_600, do: timeout
  defp timeout_option_ms(timeout) when is_integer(timeout), do: timeout * 1_000
  defp timeout_option_ms(timeout), do: timeout

  defp clean_metadata(map), do: compact(map, [nil, :empty_string, :empty_map])
end

defmodule BeamWeaver.Sandbox.OutputBuffer do
  @moduledoc false

  # Collects a command's output, up to `max_bytes` (or `:unlimited`). Longer
  # output keeps its first and its last half, with a line between them that
  # says how many bytes were cut, so the end of a build or test log survives
  # too. Neither half ends in part of a UTF-8 character. The tail is a list of
  # chunks, newest first, cut back to the last half only once it holds twice
  # as much, so output that arrives in many small chunks isn't copied over
  # and over.
  defstruct head: [], head_bytes: 0, tail: [], tail_bytes: 0, bytes: 0, max_bytes: :unlimited

  def collect(%__MODULE__{} = buffer, chunk) do
    chunk = IO.iodata_to_binary(chunk)
    buffer = %{buffer | bytes: buffer.bytes + byte_size(chunk)}

    case buffer.max_bytes do
      :unlimited ->
        %{buffer | head: [chunk | buffer.head]}

      max_bytes ->
        {head, tail} = split(chunk, div(max_bytes, 2) - buffer.head_bytes)

        buffer
        |> add_head(head)
        |> add_tail(tail, max_bytes - div(max_bytes, 2))
    end
  end

  def finish(%__MODULE__{} = buffer) do
    head = buffer.head |> Enum.reverse() |> IO.iodata_to_binary()
    tail = buffer.tail |> Enum.reverse() |> IO.iodata_to_binary()

    if buffer.max_bytes == :unlimited or buffer.bytes <= buffer.max_bytes do
      {head <> tail, false}
    else
      head = drop_partial_end(head)
      tail = tail |> last_bytes(buffer.max_bytes - div(buffer.max_bytes, 2)) |> drop_partial_start(0)
      cut = buffer.bytes - byte_size(head) - byte_size(tail)
      {head <> "\n... [#{cut} bytes cut] ...\n" <> tail, true}
    end
  end

  defp split(chunk, room) when byte_size(chunk) <= room, do: {chunk, ""}
  defp split(chunk, room) when room <= 0, do: {"", chunk}
  defp split(chunk, room), do: {binary_part(chunk, 0, room), binary_part(chunk, room, byte_size(chunk) - room)}

  defp add_head(buffer, ""), do: buffer

  defp add_head(buffer, chunk),
    do: %{buffer | head: [chunk | buffer.head], head_bytes: buffer.head_bytes + byte_size(chunk)}

  defp add_tail(buffer, "", _tail_max), do: buffer

  defp add_tail(buffer, chunk, tail_max) do
    tail = [chunk | buffer.tail]
    tail_bytes = buffer.tail_bytes + byte_size(chunk)

    if tail_bytes > 2 * tail_max do
      kept = tail |> Enum.reverse() |> IO.iodata_to_binary() |> last_bytes(tail_max)
      %{buffer | tail: [kept], tail_bytes: byte_size(kept)}
    else
      %{buffer | tail: tail, tail_bytes: tail_bytes}
    end
  end

  defp last_bytes(bytes, count) when byte_size(bytes) <= count, do: bytes
  defp last_bytes(bytes, count), do: binary_part(bytes, byte_size(bytes) - count, count)

  # Drops a character that the cut left unfinished at the end: the last lead
  # byte within the last four bytes says how long its character is.
  defp drop_partial_end(bytes) do
    size = byte_size(bytes)

    Enum.find_value(1..min(size, 4)//1, bytes, fn back ->
      <<byte>> = binary_part(bytes, size - back, 1)

      cond do
        byte in 0x80..0xBF -> nil
        back < utf8_length(byte) -> binary_part(bytes, 0, size - back)
        true -> bytes
      end
    end)
  end

  # Drops the rest of a character the cut began in the middle of.
  defp drop_partial_start(<<byte, rest::binary>>, dropped) when byte in 0x80..0xBF and dropped < 3,
    do: drop_partial_start(rest, dropped + 1)

  defp drop_partial_start(bytes, _dropped), do: bytes

  defp utf8_length(byte) when byte in 0xC0..0xDF, do: 2
  defp utf8_length(byte) when byte in 0xE0..0xEF, do: 3
  defp utf8_length(byte) when byte in 0xF0..0xF7, do: 4
  defp utf8_length(_byte), do: 1
end

defimpl Collectable, for: BeamWeaver.Sandbox.OutputBuffer do
  def into(%BeamWeaver.Sandbox.OutputBuffer{} = buffer) do
    collector = fn
      buffer, {:cont, chunk} -> BeamWeaver.Sandbox.OutputBuffer.collect(buffer, chunk)
      buffer, :done -> BeamWeaver.Sandbox.OutputBuffer.finish(buffer)
      _buffer, :halt -> :ok
    end

    {buffer, collector}
  end
end

defmodule BeamWeaver.Sandbox.Local do
  @moduledoc """
  Local filesystem sandbox adapter.

  Files live in the `:root` directory and commands run there with `sh`, on the
  host, as the user that runs your application. Commands start from a minimal
  environment: `PATH`, `HOME`, `LANG`, the `LC_*` variables, `TMPDIR`, `USER`
  and `SHELL`, plus the variables in `:env`. Pass `inherit_env: true` to give
  them your application's whole environment instead.
  """

  use BeamWeaver.Sandbox

  alias BeamWeaver.Filesystem.Edit
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Path, as: FilesystemPath
  alias BeamWeaver.Sandbox
  alias BeamWeaver.Sandbox.CommandRunner

  @default_max_output_bytes 512_000

  # `env` can carry credentials meant only for the commands.
  @derive {Inspect, except: [:env]}
  defstruct root: nil,
            env: %{},
            inherit_env: false,
            max_binary_preview: 512_000,
            max_output_bytes: @default_max_output_bytes

  def new(opts \\ []) do
    root =
      opts
      |> Keyword.get(:root, Path.join(System.tmp_dir!(), "beam_weaver_sandbox"))
      |> Path.expand()

    File.mkdir_p!(root)

    %__MODULE__{
      root: root,
      env: opts |> Keyword.get(:env, %{}) |> Map.new(fn {key, value} -> {to_string(key), value} end),
      inherit_env: Keyword.get(opts, :inherit_env, false),
      max_binary_preview: Keyword.get(opts, :max_binary_preview, 512_000),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    }
  end

  @impl true
  def write(%__MODULE__{} = sandbox, path, content, _opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         :ok <- File.mkdir_p(Path.dirname(resolved)),
         :ok <- File.write(resolved, IO.iodata_to_binary(content)) do
      %Sandbox.WriteResult{path: path, error: nil}
    else
      {:error, reason} -> %Sandbox.WriteResult{path: path, error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def read(%__MODULE__{} = sandbox, path, opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         {:ok, bytes} <- File.read(resolved) do
      read_bytes(path, bytes, sandbox, opts)
    else
      {:error, reason} -> %Sandbox.ReadResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def execute(%__MODULE__{} = sandbox, command, opts) do
    with {:ok, timeout} <- opts |> Keyword.get(:timeout, 120) |> CommandRunner.timeout_ms() do
      case CommandRunner.run(command,
             shell: CommandRunner.shell(),
             cd: sandbox.root,
             env: sandbox.env,
             inherit_env: sandbox.inherit_env,
             timeout: timeout,
             into: %BeamWeaver.Sandbox.OutputBuffer{max_bytes: sandbox.max_output_bytes}
           ) do
        {:ok, {output, truncated?}, exit_code} ->
          %Sandbox.ExecuteResult{exit_code: exit_code, output: output, truncated: truncated?}

        {:timeout, _kill_attempted?} ->
          %Sandbox.ExecuteResult{exit_code: 124, output: "", error: "timeout", truncated: false}

        {:error, reason} ->
          %Sandbox.ExecuteResult{exit_code: 1, output: "", error: CommandRunner.error_message(reason)}
      end
    else
      {:error, error} ->
        %Sandbox.ExecuteResult{exit_code: nil, output: "", error: error, truncated: false}
    end
  end

  @impl true
  def edit(%__MODULE__{} = sandbox, path, old, new, opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         {:ok, content} <- File.read(resolved) do
      case Edit.replacement(content, old, new, Keyword.get(opts, :replace_all, false)) do
        {:ok, occurrences, updated} ->
          :ok = File.write!(resolved, updated)
          %Sandbox.EditResult{path: path, occurrences: occurrences, error: nil}

        {:error, :not_found} ->
          %Sandbox.EditResult{path: path, occurrences: 0, error: "string not found"}

        {:error, "multiple occurrences" = error} ->
          %Sandbox.EditResult{path: path, occurrences: count_occurrences(content, old), error: error}

        {:error, error} ->
          %Sandbox.EditResult{path: path, occurrences: 0, error: FileDataUtils.error_string(error)}
      end
    else
      {:error, reason} ->
        %Sandbox.EditResult{path: path, occurrences: 0, error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def ls(%__MODULE__{} = sandbox, path, _opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         {:ok, names} <- File.ls(resolved) do
      entries =
        names
        |> Enum.sort()
        |> Enum.map(fn name -> {name, Path.join(resolved, name)} end)
        |> Enum.filter(fn {_name, full} -> safe_resolved_path?(sandbox, full) end)
        |> Enum.map(fn {name, full} ->
          entry_path =
            if host_path?(sandbox, path),
              do: Path.join(path, name),
              else: FilesystemPath.join_virtual(path, name)

          %{
            "path" => entry_path,
            "is_dir" => File.dir?(full),
            "type" => if(File.dir?(full), do: "directory", else: "file"),
            "size" => if(File.regular?(full), do: File.stat!(full).size)
          }
        end)

      %Sandbox.ListResult{entries: entries}
    else
      {:error, reason} -> %Sandbox.ListResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def glob(%__MODULE__{} = sandbox, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    with {:ok, resolved} <- resolve(sandbox, base),
         :ok <- exists(resolved),
         {:ok, paths} <- search(resolved, FilesystemPath.search_pattern(pattern)) do
      matches =
        paths
        |> Enum.filter(&safe_resolved_path?(sandbox, &1))
        |> Enum.sort()
        |> Enum.map(fn path ->
          %{"path" => glob_path(sandbox, base, path, resolved), "is_dir" => File.dir?(path)}
          |> maybe_put_size(sandbox, base, path)
        end)

      %Sandbox.GlobResult{matches: matches}
    else
      {:error, reason} -> %Sandbox.GlobResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def grep(%__MODULE__{} = sandbox, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    include = FilesystemPath.grep_pattern(Keyword.get(opts, :glob, Keyword.get(opts, :include))) || "**/*"

    with {:ok, resolved} <- resolve(sandbox, base),
         :ok <- exists(resolved),
         {:ok, matches} <- grep_files(sandbox, resolved, base, include, pattern) do
      %Sandbox.GrepResult{matches: matches}
    else
      {:error, reason} -> %Sandbox.GrepResult{error: FileDataUtils.error_string(reason)}
    end
  end

  defp exists(resolved), do: if(File.exists?(resolved), do: :ok, else: {:error, :enoent})

  # Grep searches the file `base` names, or the files below the folder that
  # `include` picks.
  defp grep_files(sandbox, resolved, base, include, pattern) do
    if File.regular?(resolved) do
      {:ok, grep_file(resolved, pattern, Path.dirname(resolved), Path.dirname(base), host_path?(sandbox, base))}
    else
      with {:ok, paths} <- search(resolved, include) do
        {:ok,
         paths
         |> Enum.filter(&safe_resolved_path?(sandbox, &1))
         |> Enum.reject(&(File.dir?(&1) or git_path?(&1, resolved)))
         |> Enum.flat_map(&grep_file(&1, pattern, resolved, base, host_path?(sandbox, base)))}
      end
    end
  end

  # The paths under `resolved` that `pattern` matches: the walk finds every
  # path the pattern can match, and the glob rule keeps the ones it does.
  defp search(resolved, pattern) do
    with {:ok, match?} <- FilesystemPath.glob_matcher(pattern),
         {:ok, paths} <- safe_wildcard(resolved, FilesystemPath.walk_pattern(pattern)),
         do: {:ok, Enum.filter(paths, &match?.(Path.relative_to(&1, resolved)))}
  end

  # `Path.wildcard/2` raises on a malformed pattern; return an error result
  # instead of crashing the tool call.
  defp safe_wildcard(resolved, pattern) do
    {:ok, resolved |> Path.join(pattern) |> Path.wildcard(match_dot: true)}
  rescue
    _exception -> {:error, "invalid_pattern"}
  end

  @impl true
  def upload_files(%__MODULE__{} = sandbox, files, _opts) do
    Enum.map(files, fn {path, content} ->
      with {:ok, resolved} <- resolve(sandbox, path),
           :ok <- File.mkdir_p(Path.dirname(resolved)),
           :ok <- File.write(resolved, IO.iodata_to_binary(content)) do
        %Sandbox.UploadResult{path: path, error: nil}
      else
        {:error, reason} -> %Sandbox.UploadResult{path: path, error: FileDataUtils.error_string(reason)}
      end
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = sandbox, paths, _opts) do
    Enum.map(paths, fn path ->
      with {:ok, resolved} <- resolve(sandbox, path),
           {:directory, false} <- {:directory, File.dir?(resolved)},
           {:ok, content} <- File.read(resolved) do
        %Sandbox.DownloadResult{path: path, content: content, error: nil}
      else
        {:directory, true} ->
          %Sandbox.DownloadResult{path: path, content: nil, error: "is_directory"}

        {:error, reason} ->
          %Sandbox.DownloadResult{path: path, content: nil, error: FileDataUtils.error_string(reason)}
      end
    end)
  end

  # The file a path reaches is the real path `resolve/2` checks it against,
  # relative to the root.
  @impl true
  def canonical_paths(%__MODULE__{root: root}, paths, _opts) do
    real_root = FilesystemPath.real_root(root)
    Enum.map(paths, &FilesystemPath.canonical_path(real_root, &1))
  end

  # A path is always a sandbox path: an absolute path rooted at `root`, so
  # `/secrets/key.txt` is `root`'s `secrets/key.txt`. A host path that happens
  # to point inside `root` (`<root>/secrets/key.txt`) is taken literally as the
  # sandbox path `/<root>/secrets/...`, which resolves under `root` and does
  # not exist, rather than being reinterpreted as `/secrets/...`. That keeps
  # the path the sandbox reads identical to the one a `Filesystem.Permission`
  # rule checks, so a host path can't slip past a deny rule.
  #
  # `virtual_to_real/2` validates containment and refuses a symlink that
  # escapes the root; the returned candidate is the plain `root`-relative join
  # (not the realpath), so it stays comparable to `root` for the containment
  # filter the listing calls apply.
  defp resolve(%__MODULE__{root: root}, path) when is_binary(path) do
    with {:ok, virtual_path} <- FilesystemPath.clean_path(path),
         {:ok, _resolved, _virtual} <- FilesystemPath.virtual_to_real(root, virtual_path) do
      relative = String.trim_leading(virtual_path, "/")
      {:ok, Path.expand(Path.join(root, relative))}
    end
  end

  defp resolve(_sandbox, _path), do: {:error, "invalid_path"}

  defp safe_resolved_path?(%__MODULE__{root: root}, path) do
    with {:ok, virtual_path, _candidate} <- sandbox_path(root, path),
         {:ok, _resolved, _virtual} <- FilesystemPath.virtual_to_real(root, virtual_path) do
      true
    else
      _error -> false
    end
  end

  defp sandbox_path(root, path) when is_binary(path) do
    with {:ok, clean_path} <- FilesystemPath.clean_path(path) do
      root = Path.expand(root)
      expanded = Path.expand(clean_path)

      if expanded == root or String.starts_with?(expanded, root <> "/") do
        relative = Path.relative_to(expanded, root)

        {:ok, if(relative == ".", do: "/", else: "/" <> relative), expanded}
      else
        relative = String.trim_leading(clean_path, "/")
        {:ok, clean_path, Path.expand(Path.join(root, relative))}
      end
    end
  end

  defp read_bytes(path, bytes, sandbox, opts) do
    cond do
      bytes == "" ->
        %Sandbox.ReadResult{
          file_data: %{"content" => FileDataUtils.empty_content_warning(), "encoding" => "utf-8"}
        }

      FileDataUtils.binary_content?(bytes) and byte_size(bytes) > sandbox.max_binary_preview ->
        %Sandbox.ReadResult{
          error: "File '#{path}': Binary file exceeds maximum preview size of #{sandbox.max_binary_preview} bytes"
        }

      FileDataUtils.binary_content?(bytes) ->
        %Sandbox.ReadResult{
          file_data: %{"content" => Base.encode64(bytes), "encoding" => "base64"}
        }

      true ->
        %Sandbox.ReadResult{
          file_data: %{"content" => FileDataUtils.slice_lines(bytes, opts), "encoding" => "utf-8"}
        }
    end
  end

  # Grep searches text: version control internals and binary files are left
  # out, as text search tools leave them out.
  defp git_path?(path, resolved_base), do: ".git" in Path.split(Path.relative_to(path, resolved_base))

  defp grep_file(path, pattern, resolved_base, requested_base, host_path?) do
    with {:ok, content} <- File.read(path),
         false <- FileDataUtils.binary_content?(content) do
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        if String.contains?(line, pattern),
          do: [
            %{
              "path" => grep_path(path, requested_base, resolved_base, host_path?),
              "relative_path" => Path.relative_to(path, resolved_base),
              "line" => line_number,
              "text" => line
            }
          ],
          else: []
      end)
    else
      _binary_or_error -> []
    end
  end

  defp count_occurrences(content, needle), do: content |> :binary.matches(needle) |> length()

  defp host_path?(%__MODULE__{root: root}, path) when is_binary(path) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp glob_path(sandbox, base, path, resolved_base) do
    if host_path?(sandbox, base),
      do: Path.relative_to(path, resolved_base),
      else: FilesystemPath.join_virtual(base, Path.relative_to(path, resolved_base))
  end

  defp grep_path(path, _requested_base, _resolved_base, true), do: path

  defp grep_path(path, requested_base, resolved_base, false),
    do: FilesystemPath.join_virtual(requested_base, Path.relative_to(path, resolved_base))

  defp maybe_put_size(entry, sandbox, base, path) do
    if host_path?(sandbox, base) do
      entry
    else
      Map.put(entry, "size", if(File.regular?(path), do: File.stat!(path).size))
    end
  end
end

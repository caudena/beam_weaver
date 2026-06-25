defprotocol BeamWeaver.Sandbox.Backend do
  @moduledoc """
  Protocol dispatch for sandbox backends.

  Custom sandboxes must implement this protocol, usually by using
  `BeamWeaver.Sandbox`.
  """

  def write(sandbox, path, content, opts)
  def read(sandbox, path, opts)
  def execute(sandbox, command, opts)
  def edit(sandbox, path, old, new, opts)
  def ls(sandbox, path, opts)
  def glob(sandbox, pattern, opts)
  def grep(sandbox, pattern, opts)
  def upload_files(sandbox, files, opts)
  def download_files(sandbox, paths, opts)
end

defmodule BeamWeaver.Sandbox do
  @moduledoc """
  Sandbox backend behaviour and facade.

  The default local adapter is for development and conformance tests. It gives
  BeamWeaver a native boundary for file operations and command execution without
  claiming to be a hardened remote sandbox.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Sandbox.Backend, as: SandboxBackend
  alias BeamWeaver.Telemetry
  alias BeamWeaver.Tracing.Redactor

  defmodule WriteResult do
    @moduledoc false
    defstruct [:path, :error]
    @type t :: %__MODULE__{path: String.t() | nil, error: String.t() | nil}
  end

  defmodule ReadResult do
    @moduledoc false
    defstruct [:file_data, :error]
    @type t :: %__MODULE__{file_data: binary() | nil, error: String.t() | nil}
  end

  defmodule ExecuteResult do
    @moduledoc false
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
    @moduledoc false
    defstruct [:path, occurrences: 0, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            occurrences: non_neg_integer(),
            error: String.t() | nil
          }
  end

  defmodule ListResult do
    @moduledoc false
    defstruct entries: nil, error: nil
    @type t :: %__MODULE__{entries: [map()] | nil, error: String.t() | nil}
  end

  defmodule GlobResult do
    @moduledoc false
    defstruct matches: nil, error: nil
    @type t :: %__MODULE__{matches: [String.t()] | nil, error: String.t() | nil}
  end

  defmodule GrepResult do
    @moduledoc false
    defstruct matches: nil, error: nil
    @type t :: %__MODULE__{matches: [map()] | nil, error: String.t() | nil}
  end

  defmodule UploadResult do
    @moduledoc false
    defstruct [:path, :error]
    @type t :: %__MODULE__{path: String.t() | nil, error: String.t() | nil}
  end

  defmodule DownloadResult do
    @moduledoc false
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

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Sandbox

      defimpl BeamWeaver.Sandbox.Backend, for: __MODULE__ do
        def write(sandbox, path, content, opts), do: @for.write(sandbox, path, content, opts)
        def read(sandbox, path, opts), do: @for.read(sandbox, path, opts)
        def execute(sandbox, command, opts), do: @for.execute(sandbox, command, opts)
        def edit(sandbox, path, old, new, opts), do: @for.edit(sandbox, path, old, new, opts)
        def ls(sandbox, path, opts), do: @for.ls(sandbox, path, opts)
        def glob(sandbox, pattern, opts), do: @for.glob(sandbox, pattern, opts)
        def grep(sandbox, pattern, opts), do: @for.grep(sandbox, pattern, opts)
        def upload_files(sandbox, files, opts), do: @for.upload_files(sandbox, files, opts)
        def download_files(sandbox, paths, opts), do: @for.download_files(sandbox, paths, opts)
      end
    end
  end

  def local(opts \\ []), do: BeamWeaver.Sandbox.Local.new(opts)

  def write(sandbox, path, content, opts \\ []),
    do: SandboxBackend.write(sandbox, path, content, opts)

  def read(sandbox, path, opts \\ []), do: SandboxBackend.read(sandbox, path, opts)

  def execute(sandbox, command, opts \\ []) do
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
        |> SandboxBackend.execute(command, opts)
        |> put_execute_metadata(metadata, opts)

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

  def edit(sandbox, path, old, new, opts \\ []),
    do: SandboxBackend.edit(sandbox, path, old, new, opts)

  def ls(sandbox, path, opts \\ []), do: SandboxBackend.ls(sandbox, path, opts)
  def glob(sandbox, pattern, opts \\ []), do: SandboxBackend.glob(sandbox, pattern, opts)
  def grep(sandbox, pattern, opts \\ []), do: SandboxBackend.grep(sandbox, pattern, opts)

  def upload_files(sandbox, files, opts \\ []),
    do: SandboxBackend.upload_files(sandbox, files, opts)

  def download_files(sandbox, paths, opts \\ []),
    do: SandboxBackend.download_files(sandbox, paths, opts)

  def async_read(sandbox, path, opts \\ []), do: Async.run_call(opts, &read(sandbox, path, &1))

  def async_write(sandbox, path, content, opts \\ []),
    do: Async.run_call(opts, &write(sandbox, path, content, &1))

  def async_execute(sandbox, command, opts \\ []),
    do: Async.run_call(opts, &execute(sandbox, command, &1))

  def async_upload_files(sandbox, files, opts \\ []),
    do: Async.run_call(opts, &upload_files(sandbox, files, &1))

  def async_download_files(sandbox, paths, opts \\ []),
    do: Async.run_call(opts, &download_files(sandbox, paths, &1))

  def error(type, message, details \\ %{}), do: Error.new(type, message, details)

  defp execute_metadata(sandbox, command, opts) do
    base =
      %{
        sandbox: sandbox_module(sandbox),
        command: command,
        command_id: Keyword.get_lazy(opts, :command_id, fn -> ID.uuidv7() end),
        timeout_ms: timeout_option_ms(Keyword.get(opts, :timeout))
      }
      |> clean_metadata()

    base
    |> Map.merge(Keyword.get(opts, :metadata, %{}) || %{})
    |> Redactor.redact()
  end

  defp put_execute_metadata(%ExecuteResult{} = result, metadata, _opts) do
    result_metadata =
      metadata
      |> Map.merge(result.metadata || %{})
      |> maybe_put(:exit_code, result.exit_code)
      |> maybe_put(:truncated, result.truncated)
      |> maybe_put(:error, result.error)
      |> clean_metadata()
      |> Redactor.redact()

    %{result | metadata: result_metadata}
  end

  defp put_execute_metadata(other, _metadata, _opts), do: other

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

  defp result_metadata(result) do
    %{result: :invalid, value: inspect(result)}
    |> clean_metadata()
    |> Redactor.redact()
  end

  defp timeout_result?(%ExecuteResult{error: "timeout"}), do: true
  defp timeout_result?(%ExecuteResult{exit_code: 124, error: error}), do: error in ["timeout", :timeout]
  defp timeout_result?(_result), do: false

  defp sandbox_module(%{__struct__: module}), do: module
  defp sandbox_module(other), do: inspect(other)

  defp timeout_option_ms(nil), do: nil
  defp timeout_option_ms(:infinity), do: :infinity
  defp timeout_option_ms(timeout) when is_integer(timeout) and timeout > 3_600, do: timeout
  defp timeout_option_ms(timeout) when is_integer(timeout), do: timeout * 1_000
  defp timeout_option_ms(timeout), do: timeout

  defp clean_metadata(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule BeamWeaver.Sandbox.Local do
  @moduledoc """
  Local filesystem sandbox adapter.
  """

  use BeamWeaver.Sandbox

  alias BeamWeaver.Sandbox

  defstruct root: nil, max_binary_preview: 512_000

  def new(opts \\ []) do
    root =
      opts
      |> Keyword.get(:root, Path.join(System.tmp_dir!(), "beam_weaver_sandbox"))
      |> Path.expand()

    File.mkdir_p!(root)
    %__MODULE__{root: root, max_binary_preview: Keyword.get(opts, :max_binary_preview, 512_000)}
  end

  @impl true
  def write(%__MODULE__{} = sandbox, path, content, _opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         {:exists, false} <- {:exists, File.exists?(resolved)},
         :ok <- File.mkdir_p(Path.dirname(resolved)),
         :ok <- File.write(resolved, IO.iodata_to_binary(content)) do
      %Sandbox.WriteResult{path: path, error: nil}
    else
      {:exists, true} -> %Sandbox.WriteResult{path: path, error: "file already exists"}
      {:error, reason} -> %Sandbox.WriteResult{path: path, error: error_string(reason)}
    end
  end

  @impl true
  def read(%__MODULE__{} = sandbox, path, opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         {:ok, bytes} <- File.read(resolved) do
      read_bytes(path, bytes, sandbox, opts)
    else
      {:error, reason} -> %Sandbox.ReadResult{error: error_string(reason)}
    end
  end

  @impl true
  def execute(%__MODULE__{} = sandbox, command, opts) do
    case opts |> Keyword.get(:timeout, 120) |> timeout_ms() do
      {:ok, timeout} ->
        task =
          Task.async(fn ->
            System.cmd("sh", ["-c", command],
              cd: sandbox.root,
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, exit_code}} ->
            %Sandbox.ExecuteResult{exit_code: exit_code, output: output, truncated: false}

          nil ->
            %Sandbox.ExecuteResult{exit_code: 124, output: "", error: "timeout", truncated: false}
        end

      {:error, error} ->
        %Sandbox.ExecuteResult{exit_code: nil, output: "", error: error, truncated: false}
    end
  rescue
    exception ->
      %Sandbox.ExecuteResult{exit_code: 1, output: "", error: Exception.message(exception)}
  end

  @impl true
  def edit(%__MODULE__{} = sandbox, path, old, new, opts) do
    replace_all? = Keyword.get(opts, :replace_all, false)

    with {:ok, resolved} <- resolve(sandbox, path),
         {:ok, content} <- File.read(resolved) do
      occurrences = count_occurrences(content, old)

      cond do
        occurrences == 0 ->
          %Sandbox.EditResult{path: path, occurrences: 0, error: "string not found"}

        occurrences > 1 and not replace_all? ->
          %Sandbox.EditResult{path: path, occurrences: occurrences, error: "multiple occurrences"}

        true ->
          updated =
            if replace_all?,
              do: String.replace(content, old, new),
              else: String.replace(content, old, new, global: false)

          :ok = File.write!(resolved, updated)

          %Sandbox.EditResult{
            path: path,
            occurrences: if(replace_all?, do: occurrences, else: 1),
            error: nil
          }
      end
    else
      {:error, reason} ->
        %Sandbox.EditResult{path: path, occurrences: 0, error: error_string(reason)}
    end
  end

  @impl true
  def ls(%__MODULE__{} = sandbox, path, _opts) do
    with {:ok, resolved} <- resolve(sandbox, path),
         {:ok, names} <- File.ls(resolved) do
      entries =
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = Path.join(resolved, name)

          entry_path =
            if host_path?(sandbox, path),
              do: Path.join(path, name),
              else: join_virtual(path, name)

          %{
            "path" => entry_path,
            "is_dir" => File.dir?(full),
            "type" => if(File.dir?(full), do: "directory", else: "file"),
            "size" => if(File.regular?(full), do: File.stat!(full).size)
          }
        end)

      %Sandbox.ListResult{entries: entries}
    else
      {:error, reason} -> %Sandbox.ListResult{error: error_string(reason)}
    end
  end

  @impl true
  def glob(%__MODULE__{} = sandbox, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    case resolve(sandbox, base) do
      {:ok, resolved} ->
        matches =
          resolved
          |> Path.join(pattern)
          |> Path.wildcard(match_dot: true)
          |> Enum.sort()
          |> Enum.map(fn path ->
            %{"path" => glob_path(sandbox, base, path, resolved), "is_dir" => File.dir?(path)}
            |> maybe_put_size(sandbox, base, path)
          end)

        %Sandbox.GlobResult{matches: matches}

      {:error, reason} ->
        %Sandbox.GlobResult{error: error_string(reason)}
    end
  end

  @impl true
  def grep(%__MODULE__{} = sandbox, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    include =
      opts |> Keyword.get(:glob, Keyword.get(opts, :include, "**/*")) |> normalize_grep_glob()

    case resolve(sandbox, base) do
      {:ok, resolved} ->
        matches =
          resolved
          |> Path.join(include)
          |> Path.wildcard(match_dot: true)
          |> Enum.reject(&File.dir?/1)
          |> Enum.flat_map(&grep_file(&1, pattern, resolved, base, host_path?(sandbox, base)))

        %Sandbox.GrepResult{matches: matches}

      {:error, reason} ->
        %Sandbox.GrepResult{error: error_string(reason)}
    end
  end

  @impl true
  def upload_files(%__MODULE__{} = sandbox, files, _opts) do
    Enum.map(files, fn {path, content} ->
      with {:ok, resolved} <- resolve(sandbox, path),
           :ok <- File.mkdir_p(Path.dirname(resolved)),
           :ok <- File.write(resolved, IO.iodata_to_binary(content)) do
        %Sandbox.UploadResult{path: path, error: nil}
      else
        {:error, reason} -> %Sandbox.UploadResult{path: path, error: error_string(reason)}
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
          %Sandbox.DownloadResult{path: path, content: nil, error: error_string(reason)}
      end
    end)
  end

  defp resolve(%__MODULE__{root: root}, path) when is_binary(path) do
    cond do
      Path.type(path) != :absolute ->
        {:error, "invalid_path"}

      String.contains?(path, ["\0", "~"]) ->
        {:error, "invalid_path"}

      Enum.member?(Path.split(path), "..") ->
        {:error, "invalid_path"}

      true ->
        expanded_input = Path.expand(path)

        expanded =
          if expanded_input == root or String.starts_with?(expanded_input, root <> "/") do
            expanded_input
          else
            path |> String.trim_leading("/") |> then(&Path.expand(Path.join(root, &1)))
          end

        if expanded == root or String.starts_with?(expanded, root <> "/"),
          do: {:ok, expanded},
          else: {:error, "invalid_path"}
    end
  end

  defp read_bytes(path, bytes, sandbox, opts) do
    cond do
      bytes == "" ->
        %Sandbox.ReadResult{
          file_data: %{
            "content" => "System reminder: File exists but has empty contents",
            "encoding" => "utf-8"
          }
        }

      binary_content?(bytes) and byte_size(bytes) > sandbox.max_binary_preview ->
        %Sandbox.ReadResult{
          error: "File '#{path}': Binary file exceeds maximum preview size of #{sandbox.max_binary_preview} bytes"
        }

      binary_content?(bytes) ->
        offset = Keyword.get(opts, :offset, 0)
        limit = Keyword.get(opts, :limit)
        bytes = slice_bytes(bytes, offset, limit)

        %Sandbox.ReadResult{
          file_data: %{"content" => Base.encode64(bytes), "encoding" => "base64"}
        }

      true ->
        %Sandbox.ReadResult{
          file_data: %{"content" => slice_lines(bytes, opts), "encoding" => "utf-8"}
        }
    end
  end

  defp slice_bytes(bytes, offset, nil),
    do: binary_part(bytes, min(offset, byte_size(bytes)), max(byte_size(bytes) - offset, 0))

  defp slice_bytes(bytes, offset, limit),
    do:
      binary_part(
        bytes,
        min(offset, byte_size(bytes)),
        min(limit, max(byte_size(bytes) - offset, 0))
      )

  defp slice_lines(bytes, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)

    bytes
    |> String.split("\n")
    |> Enum.drop(offset)
    |> maybe_take(limit)
    |> Enum.join("\n")
  end

  defp maybe_take(lines, nil), do: lines
  defp maybe_take(lines, limit), do: Enum.take(lines, limit)

  defp binary_content?(bytes),
    do: not String.valid?(bytes) or :binary.match(bytes, <<0>>) != :nomatch

  defp grep_file(path, pattern, resolved_base, requested_base, host_path?) do
    case File.read(path) do
      {:ok, content} ->
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

      _error ->
        []
    end
  end

  defp normalize_grep_glob(pattern) do
    cond do
      pattern in [nil, ""] -> "**/*"
      String.starts_with?(pattern, "**/") -> pattern
      String.contains?(pattern, "/") -> pattern
      true -> Path.join("**", pattern)
    end
  end

  defp count_occurrences(content, ""), do: if(content == "", do: 1, else: 0)

  defp count_occurrences(content, needle) do
    content
    |> :binary.matches(needle)
    |> length()
  end

  defp error_string(:enoent), do: "file_not_found"
  defp error_string(:eacces), do: "permission_denied"
  defp error_string(reason) when is_binary(reason), do: reason
  defp error_string(reason), do: inspect(reason)

  defp timeout_ms(timeout) when is_integer(timeout) and timeout in 1..3600,
    do: {:ok, timeout * 1_000}

  defp timeout_ms(_timeout),
    do: {:error, "timeout must be an integer between 1 and 3600 seconds"}

  defp host_path?(%__MODULE__{root: root}, path) when is_binary(path) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp glob_path(sandbox, base, path, resolved_base) do
    if host_path?(sandbox, base),
      do: Path.relative_to(path, resolved_base),
      else: join_virtual(base, Path.relative_to(path, resolved_base))
  end

  defp grep_path(path, _requested_base, _resolved_base, true), do: path

  defp grep_path(path, requested_base, resolved_base, false),
    do: join_virtual(requested_base, Path.relative_to(path, resolved_base))

  defp maybe_put_size(entry, sandbox, base, path) do
    if host_path?(sandbox, base) do
      entry
    else
      Map.put(entry, "size", if(File.regular?(path), do: File.stat!(path).size))
    end
  end

  defp join_virtual("/", ""), do: "/"
  defp join_virtual("/", relative), do: "/" <> String.trim_leading(relative, "/")
  defp join_virtual(base, ""), do: base

  defp join_virtual(base, relative) do
    String.trim_trailing(base, "/") <> "/" <> String.trim_leading(relative, "/")
  end
end

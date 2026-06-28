defprotocol BeamWeaver.Filesystem.Backend do
  @moduledoc """
  Protocol dispatch for BeamWeaver filesystem backends.

  Custom backends must implement this protocol, usually by using
  `BeamWeaver.Filesystem`.
  """

  def ls(backend, path, opts)
  def read(backend, path, opts)
  def write(backend, path, content, opts)
  def edit(backend, path, old, new, opts)
  def glob(backend, pattern, opts)
  def grep(backend, pattern, opts)
  def upload_files(backend, files, opts)
  def download_files(backend, paths, opts)
end

defprotocol BeamWeaver.Filesystem.ExecutableBackend do
  @moduledoc """
  Protocol dispatch for filesystem backends that can execute commands.
  """

  def id(backend)
  def execute(backend, command, opts)
end

defmodule BeamWeaver.Filesystem do
  @moduledoc """
  Filesystem backend behaviour used by agent filesystem capabilities.

  Backends expose a virtual, POSIX-style filesystem to agent tools. Paths are
  always absolute from the agent perspective, even when the backing storage is
  graph state, a BeamWeaver memory store, local disk, Docker, or a remote
  sandbox service.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Filesystem.Backend, as: FilesystemBackend

  defmodule FileInfo do
    @moduledoc "Metadata for one virtual filesystem entry."
    defstruct [:path, :is_dir, :size, :modified_at]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            is_dir: boolean() | nil,
            size: non_neg_integer() | nil,
            modified_at: String.t() | nil
          }
  end

  defmodule GrepMatch do
    @moduledoc "One literal grep match."
    defstruct [:path, :line, :text]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            line: pos_integer() | nil,
            text: String.t() | nil
          }
  end

  defmodule FileData do
    @moduledoc "File content in DeepAgents v2 shape."
    defstruct [:content, encoding: "utf-8", created_at: nil, modified_at: nil]

    @type t :: %__MODULE__{
            content: binary() | nil,
            encoding: String.t(),
            created_at: String.t() | nil,
            modified_at: String.t() | nil
          }
  end

  defmodule LsResult do
    @moduledoc "Result returned by filesystem directory listing calls."

    defstruct entries: nil, error: nil

    @type t :: %__MODULE__{
            entries: [FileInfo.t()] | nil,
            error: term()
          }
  end

  defmodule ReadResult do
    @moduledoc "Result returned by filesystem read calls."

    defstruct file_data: nil, error: nil

    @type t :: %__MODULE__{
            file_data: FileData.t() | nil,
            error: term()
          }
  end

  defmodule WriteResult do
    @moduledoc "Result returned by filesystem write calls."

    defstruct [:path, :files_update, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            files_update: map() | nil,
            error: term()
          }
  end

  defmodule EditResult do
    @moduledoc "Result returned by filesystem edit calls."

    defstruct [:path, :files_update, occurrences: nil, error: nil]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            files_update: map() | nil,
            occurrences: non_neg_integer() | nil,
            error: term()
          }
  end

  defmodule GlobResult do
    @moduledoc "Result returned by filesystem glob calls."

    defstruct matches: nil, error: nil

    @type t :: %__MODULE__{
            matches: [String.t()] | nil,
            error: term()
          }
  end

  defmodule GrepResult do
    @moduledoc "Result returned by filesystem grep calls."

    defstruct matches: nil, error: nil

    @type t :: %__MODULE__{
            matches: [GrepMatch.t()] | nil,
            error: term()
          }
  end

  defmodule UploadResult do
    @moduledoc "Result returned for one uploaded file."

    defstruct [:path, :error]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            error: term()
          }
  end

  defmodule DownloadResult do
    @moduledoc "Result returned for one downloaded file."

    defstruct [:path, :content, :error]

    @type t :: %__MODULE__{
            path: String.t() | nil,
            content: binary() | nil,
            error: term()
          }
  end

  @type t :: struct()

  @file_not_found "file_not_found"
  @invalid_path "invalid_path"
  @is_directory "is_directory"
  @permission_denied "permission_denied"

  def file_not_found, do: @file_not_found
  def invalid_path, do: @invalid_path
  def directory_error, do: @is_directory

  @deprecated "Use directory_error/0 instead"
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_directory, do: directory_error()

  def permission_denied, do: @permission_denied

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Filesystem

      defimpl BeamWeaver.Filesystem.Backend, for: __MODULE__ do
        def ls(backend, path, opts), do: @for.ls(backend, path, opts)
        def read(backend, path, opts), do: @for.read(backend, path, opts)
        def write(backend, path, content, opts), do: @for.write(backend, path, content, opts)
        def edit(backend, path, old, new, opts), do: @for.edit(backend, path, old, new, opts)
        def glob(backend, pattern, opts), do: @for.glob(backend, pattern, opts)
        def grep(backend, pattern, opts), do: @for.grep(backend, pattern, opts)
        def upload_files(backend, files, opts), do: @for.upload_files(backend, files, opts)
        def download_files(backend, paths, opts), do: @for.download_files(backend, paths, opts)
      end
    end
  end

  @callback ls(term(), String.t(), keyword()) :: LsResult.t()
  @callback read(term(), String.t(), keyword()) :: ReadResult.t()
  @callback write(term(), String.t(), iodata(), keyword()) :: WriteResult.t()
  @callback edit(term(), String.t(), String.t(), String.t(), keyword()) :: EditResult.t()
  @callback glob(term(), String.t(), keyword()) :: GlobResult.t()
  @callback grep(term(), String.t(), keyword()) :: GrepResult.t()
  @callback upload_files(term(), [{String.t(), iodata()}], keyword()) :: [UploadResult.t()]
  @callback download_files(term(), [String.t()], keyword()) :: [DownloadResult.t()]

  def ls(backend, path, opts \\ []), do: FilesystemBackend.ls(backend, path, opts)
  def read(backend, path, opts \\ []), do: FilesystemBackend.read(backend, path, opts)

  def write(backend, path, content, opts \\ []),
    do: FilesystemBackend.write(backend, path, content, opts)

  def edit(backend, path, old, new, opts \\ []),
    do: FilesystemBackend.edit(backend, path, old, new, opts)

  def glob(backend, pattern, opts \\ []), do: FilesystemBackend.glob(backend, pattern, opts)
  def grep(backend, pattern, opts \\ []), do: FilesystemBackend.grep(backend, pattern, opts)

  def upload_files(backend, files, opts \\ []),
    do: FilesystemBackend.upload_files(backend, files, opts)

  def download_files(backend, paths, opts \\ []),
    do: FilesystemBackend.download_files(backend, paths, opts)

  def ls_info(backend, path, opts \\ []), do: ls(backend, path, opts)
  def glob_info(backend, pattern, opts \\ []), do: glob(backend, pattern, opts)

  def grep_raw(backend, pattern, opts \\ []) do
    case grep(backend, pattern, opts) do
      %GrepResult{error: nil, matches: matches} ->
        matches
        |> List.wrap()
        |> Enum.map_join("\n", fn %GrepMatch{} = match -> "#{match.path}:#{match.line}:#{match.text}" end)

      %GrepResult{error: error} ->
        "Error: #{error}"
    end
  end

  def async_ls(backend, path, opts \\ []), do: Async.run_call(opts, &ls(backend, path, &1))
  def async_read(backend, path, opts \\ []), do: Async.run_call(opts, &read(backend, path, &1))

  def async_write(backend, path, content, opts \\ []),
    do: Async.run_call(opts, &write(backend, path, content, &1))

  def async_edit(backend, path, old, new, opts \\ []),
    do: Async.run_call(opts, &edit(backend, path, old, new, &1))

  def async_glob(backend, pattern, opts \\ []),
    do: Async.run_call(opts, &glob(backend, pattern, &1))

  def async_grep(backend, pattern, opts \\ []),
    do: Async.run_call(opts, &grep(backend, pattern, &1))

  def async_upload_files(backend, files, opts \\ []),
    do: Async.run_call(opts, &upload_files(backend, files, &1))

  def async_download_files(backend, paths, opts \\ []),
    do: Async.run_call(opts, &download_files(backend, paths, &1))
end

defmodule BeamWeaver.Filesystem.Executable do
  @moduledoc """
  Extension behaviour for DeepAgents backends that can execute shell commands.

  This behaviour does not imply security. Local shell adapters are explicitly
  unsafe; real isolation must be provided by Docker/gVisor/Kata, Firecracker, or
  a managed sandbox service.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Filesystem.ExecutableBackend

  defmodule ExecuteResult do
    @moduledoc "Result returned by executable filesystem backends."

    defstruct [:exit_code, output: "", error: nil, truncated: false, metadata: %{}]

    @type t :: %__MODULE__{
            exit_code: non_neg_integer() | nil,
            output: String.t(),
            error: term(),
            truncated: boolean(),
            metadata: map()
          }
  end

  @callback id(term()) :: String.t()
  @callback execute(term(), String.t(), keyword()) :: ExecuteResult.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Filesystem.Executable

      defimpl BeamWeaver.Filesystem.ExecutableBackend, for: __MODULE__ do
        def id(backend), do: @for.id(backend)
        def execute(backend, command, opts), do: @for.execute(backend, command, opts)
      end
    end
  end

  def id(backend), do: ExecutableBackend.id(backend)

  def execute(backend, command, opts \\ []),
    do: ExecutableBackend.execute(backend, command, opts)

  def async_execute(backend, command, opts \\ []),
    do: Async.run_call(opts, &execute(backend, command, &1))

  def execute_accepts_timeout?(backend) when is_struct(backend) do
    executable?(backend)
  end

  def execute_accepts_timeout?(_backend), do: false

  def executable?(backend) when is_struct(backend) do
    case ExecutableBackend.impl_for(backend) do
      nil -> false
      _impl -> executable_enabled?(backend)
    end
  end

  def executable?(_backend), do: false

  defp executable_enabled?(%{__struct__: module} = backend) do
    if function_exported?(module, :executable?, 1) do
      module.executable?(backend) == true
    else
      true
    end
  end
end
